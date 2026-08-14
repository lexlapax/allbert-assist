defmodule AllbertAssist.Objectives.Fanout.ReportComposer do
  @moduledoc """
  Recoverable single-owner process for durable fan-out report composition.

  A plain GenServer is the pragmatic substrate: the durable state machine and
  compare-and-set authority live in Objectives/SQLite, while this process only
  serializes one bounded phase-separated synthesis protocol per claimed report
  and wakes durable work after boot or terminal reduction. Inside that durable
  claim it invokes one temporary Jido synthesis lifecycle; the Jido/critic
  state is discarded before this GenServer persists the selected report and
  never becomes queue or authority state.
  """

  use GenServer

  alias AllbertAssist.Database.TransientError
  alias AllbertAssist.FirstRun.Disclosure
  alias AllbertAssist.Objectives.Fanout
  alias AllbertAssist.Objectives.Fanout.Budget
  alias AllbertAssist.Objectives.Fanout.Report
  alias AllbertAssist.Objectives.Fanout.ReportComposer.SynthesisAgent
  alias AllbertAssist.Pack.EffectGuard
  alias AllbertAssist.Settings
  alias AllbertAssist.Settings.Models

  @default_model_client __MODULE__.ReqLLMImplementation
  @default_max_retry_attempts 4
  @default_retry_base_ms 50
  @default_retry_max_ms 1_000
  @default_reconcile_interval_ms 30_000

  @type state :: %{
          enabled?: boolean(),
          store: module() | {module(), term()},
          models: module(),
          disclosure: module(),
          model_client: module(),
          effect_guard: module() | {module(), term()},
          model_enabled?: boolean() | nil,
          model_context: map(),
          phase:
            :disabled | :recovering | :ready | :retrying_claim | :retrying_select | :degraded,
          drain_requested?: boolean(),
          reconcile_requested?: boolean(),
          retry_attempts: %{
            recover: non_neg_integer(),
            claim: non_neg_integer(),
            select: non_neg_integer()
          },
          max_retry_attempts: pos_integer(),
          retry_base_ms: non_neg_integer(),
          retry_max_ms: non_neg_integer(),
          reconcile_interval_ms: pos_integer()
        }

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: Keyword.get(opts, :name, __MODULE__))
  end

  @doc "Wake the durable queue after a parent commits composition-ready state."
  @spec enqueue(String.t(), GenServer.server()) :: :ok
  def enqueue(parent_id, server \\ __MODULE__) when is_binary(parent_id) do
    GenServer.cast(server, {:enqueue, parent_id})
  end

  @doc "Wake durable recovery for composing or legacy selected-report state."
  @spec reconcile(String.t(), GenServer.server()) :: :ok
  def reconcile(parent_id, server \\ __MODULE__) when is_binary(parent_id) do
    GenServer.cast(server, {:reconcile, parent_id})
  end

  @impl true
  def init(opts) do
    state = %{
      enabled?: Keyword.get(opts, :enabled?, true),
      store: Keyword.get(opts, :store, Fanout),
      models: Keyword.get(opts, :models, Models),
      disclosure: Keyword.get(opts, :disclosure, Disclosure),
      model_client: Keyword.get(opts, :model_client, @default_model_client),
      effect_guard: Keyword.get(opts, :effect_guard, EffectGuard),
      model_enabled?: Keyword.get(opts, :model_enabled?),
      model_context: Keyword.get(opts, :model_context, %{}),
      phase: if(Keyword.get(opts, :enabled?, true), do: :recovering, else: :disabled),
      drain_requested?: Keyword.get(opts, :enabled?, true),
      reconcile_requested?: false,
      retry_attempts: %{recover: 0, claim: 0, select: 0},
      max_retry_attempts:
        positive_integer_option(opts, :max_retry_attempts, @default_max_retry_attempts),
      retry_base_ms: non_negative_integer_option(opts, :retry_base_ms, @default_retry_base_ms),
      retry_max_ms: non_negative_integer_option(opts, :retry_max_ms, @default_retry_max_ms),
      reconcile_interval_ms:
        positive_integer_option(opts, :reconcile_interval_ms, @default_reconcile_interval_ms)
    }

    if state.enabled? do
      send(self(), :recover)
      schedule_reconcile(state)
    end

    {:ok, state}
  end

  @impl true
  def handle_cast({:enqueue, _parent_id}, %{enabled?: true} = state) do
    state = %{state | drain_requested?: true}

    case state.phase do
      :ready ->
        send(self(), :drain)
        {:noreply, state}

      :degraded ->
        send(self(), :recover)
        {:noreply, state |> reset_retry(:recover) |> Map.put(:phase, :recovering)}

      _recovering_or_retrying ->
        {:noreply, state}
    end
  end

  def handle_cast({:enqueue, _parent_id}, state), do: {:noreply, state}

  def handle_cast({:reconcile, _parent_id}, %{enabled?: true} = state),
    do: {:noreply, request_reconcile(state)}

  def handle_cast({:reconcile, _parent_id}, state), do: {:noreply, state}

  @impl true
  def handle_info(:recover, %{enabled?: true} = state) do
    case admit_ready_epoch(state) do
      {:ok, epoch} -> recover_with_epoch(epoch, state)
      {:error, :product_not_ready} -> {:noreply, retry_ready_recovery(state)}
    end
  end

  @impl true
  def handle_info(:drain, %{phase: :ready} = state) do
    case admit_ready_epoch(state) do
      {:ok, epoch} -> drain_with_epoch(epoch, state)
      {:error, :product_not_ready} -> {:noreply, retry_ready_drain(state)}
    end
  end

  def handle_info(:drain, state), do: {:noreply, %{state | drain_requested?: true}}

  def handle_info({:retry, :recover, nil}, state) do
    send(self(), :recover)
    {:noreply, %{state | phase: :recovering}}
  end

  def handle_info({:retry, :claim, nil}, state) do
    send(self(), :drain)
    {:noreply, %{state | phase: :ready}}
  end

  def handle_info({:retry, :select, {claim, selection}}, state) do
    state = %{state | phase: :retrying_select}

    case admit_ready_epoch(state) do
      {:ok, epoch} ->
        {:noreply, persist_selection(claim, selection, state, epoch)}

      {:error, :product_not_ready} ->
        {:noreply, retry_ready_selection(claim, selection, state)}

      {:error, :stale_epoch} ->
        {:noreply, state}
    end
  end

  def handle_info(:reconcile, %{enabled?: true} = state) do
    schedule_reconcile(state)
    {:noreply, request_reconcile(state)}
  end

  def handle_info(:reconcile, state), do: {:noreply, state}

  defp recover_with_epoch(epoch, state) do
    case validate_epoch(epoch, state) do
      :ok -> recover_composition(epoch, state)
      {:error, :product_not_ready} -> {:noreply, retry_ready_recovery(state)}
      {:error, :stale_epoch} -> {:noreply, state}
    end
  end

  defp recover_composition(epoch, state) do
    case store_call(state.store, :recover_composition, [effect_options(epoch, state)]) do
      {:ok, _count} -> {:noreply, recovery_succeeded(state)}
      {:error, reason} -> {:noreply, retry_or_degrade(:recover, nil, reason, state)}
    end
  end

  defp drain_with_epoch(epoch, state) do
    case validate_epoch(epoch, state) do
      :ok -> claim_next_composition(epoch, state)
      {:error, :product_not_ready} -> {:noreply, retry_ready_drain(state)}
      {:error, :stale_epoch} -> {:noreply, state}
    end
  end

  defp claim_next_composition(epoch, state) do
    case store_call(state.store, :claim_next_composition, [effect_options(epoch, state)]) do
      :none ->
        {:noreply, claim_queue_drained(state)}

      {:ok, claim} ->
        claim = Map.put_new(claim, :effect_context, effect_context(epoch, state))
        {:noreply, select_composition(claim, state, epoch)}

      {:error, reason} ->
        {:noreply, retry_or_degrade(:claim, nil, reason, state)}
    end
  end

  defp select_composition(claim, state, epoch) do
    with {:ok, selection} <- selected_body(claim, state, epoch) do
      persist_selection(claim, selection, state, epoch)
    else
      {:error, _reason} -> state
    end
  end

  defp persist_selection(claim, selection, state, epoch) do
    case validate_claim_epoch(claim, epoch, state) do
      :ok ->
        args = [
          claim,
          selection.source,
          selection.body,
          selection.provenance,
          effect_options(epoch, state)
        ]

        case store_call(state.store, :select_composition, args) do
          {:ok, _parent} -> selection_persisted(state)
          {:error, :stale_composition_claim} -> selection_persisted(state)
          {:error, reason} -> retry_or_degrade(:select, {claim, selection}, reason, state)
        end

      {:error, _reason} ->
        state
    end
  end

  defp selection_persisted(state) do
    state = reset_retry(state, :select)

    if state.reconcile_requested? do
      send(self(), :recover)
      %{state | phase: :recovering, reconcile_requested?: false, drain_requested?: true}
    else
      send(self(), :drain)
      %{state | phase: :ready}
    end
  end

  defp selected_body(%{frozen: frozen} = claim, state, epoch) do
    case Budget.composer_compatibility(claim.budget) do
      :ok ->
        select_synthesis_eligible_body(claim, state, epoch)

      {:error, :fanout_budget_version_retired} ->
        {:ok, fallback_selection(frozen, :fanout_budget_version_retired, :not_run)}

      {:error, :invalid_fanout_budget_snapshot} ->
        {:ok, fallback_selection(frozen, :invalid_budget_snapshot, :not_run)}
    end
  end

  defp select_synthesis_eligible_body(%{frozen: frozen} = claim, state, epoch) do
    case Report.synthesis_eligibility(frozen.snapshot) do
      :ok ->
        case model_enabled(state) do
          :ok -> select_budgeted_model_body(claim, state, epoch)
          {:error, _reason} -> {:ok, fallback_selection(frozen, :model_disabled, :not_run)}
        end

      {:error, :legacy_unreviewed_children} ->
        {:ok, fallback_selection(frozen, :legacy_unreviewed_children, :not_run)}

      {:error, :no_completed_children} ->
        {:ok, fallback_selection(frozen, :no_completed_children, :not_run)}

      {:error, _reason} ->
        {:ok, fallback_selection(frozen, :invalid_model_output, :unresolved)}
    end
  end

  defp select_budgeted_model_body(%{frozen: frozen} = claim, state, epoch) do
    case Budget.authorize_composer(claim.budget, claim.deadline_unix_ms) do
      {:ok, limits} ->
        select_resolved_model_body(claim, limits, state, epoch)

      {:error, :invalid_fanout_budget_snapshot} ->
        {:ok, fallback_selection(frozen, :invalid_budget_snapshot, :not_run)}

      {:error, :fanout_plan_deadline_exhausted} ->
        {:ok, fallback_selection(frozen, :deadline_exhausted, :not_run)}
    end
  end

  defp select_resolved_model_body(%{frozen: frozen} = claim, limits, state, epoch) do
    case state.models.for(:fanout_synthesis, claim.context) do
      {:ok, %{profile: profile}} ->
        select_disclosed_model_body(claim, profile, limits, state, epoch)

      {:error, _reason} ->
        {:ok, fallback_selection(frozen, :profile_unavailable, :not_run)}
    end
  end

  defp select_disclosed_model_body(%{frozen: frozen} = claim, profile, limits, state, epoch) do
    case state.disclosure.authorize_transport(profile, claim.context) do
      :ok -> compose_model_body(claim, profile, limits, state, epoch)
      {:error, _reason} -> {:ok, fallback_selection(frozen, :transport_denied, :not_run)}
    end
  end

  defp compose_model_body(
         %{frozen: frozen, deadline_unix_ms: deadline_unix_ms, context: claim_context},
         profile,
         limits,
         state,
         epoch
       ) do
    context =
      state.model_context
      |> Map.merge(claim_context)
      |> Map.put(:models, state.models)
      |> Map.put(:disclosure, state.disclosure)
      |> Map.merge(%{
        timeout_ms: limits.timeout_ms,
        max_output_tokens: limits.max_output_tokens,
        fanout_deadline_unix_ms: deadline_unix_ms
      })

    case validate_epoch(epoch, state) do
      :ok ->
        case SynthesisAgent.run(
               frozen.snapshot,
               profile,
               context,
               state.model_client,
               limits.timeout_ms
             ) do
          {:ok, prepared} ->
            {:ok, model_selection(prepared, profile)}

          {:error, reason} ->
            {category, outcome} = model_failure_category(reason)
            {:ok, fallback_selection(frozen, category, outcome)}
        end

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp model_selection(%{body: body, layout: layout} = prepared, profile) do
    %{
      source: "model",
      body: body,
      provenance: %{
        model_profile: to_string(Map.fetch!(profile, :name)),
        provider: to_string(Map.fetch!(profile, :provider)),
        model: to_string(Map.fetch!(profile, :model)),
        layout_version: Map.fetch!(layout, :layout_version),
        sections: Map.fetch!(layout, :sections),
        synthesis_contract_version: Map.fetch!(prepared, :synthesis_contract_version),
        validation_outcome: Map.fetch!(prepared, :validation_outcome),
        covered_queue_positions: Map.fetch!(prepared, :covered_queue_positions),
        synthesis_sha256: Map.fetch!(prepared, :synthesis_sha256),
        generation_call_count: Map.fetch!(prepared, :generation_call_count),
        provider_call_count: Map.fetch!(prepared, :provider_call_count)
      }
    }
  end

  defp fallback_selection(frozen, category, outcome) do
    {:ok, provenance} = Report.fallback_provenance(frozen.snapshot, category)

    if Map.has_key?(provenance, :synthesis_outcome) do
      true = provenance.synthesis_outcome == to_string(outcome)
    end

    %{
      source: "deterministic_fallback",
      body: frozen.fallback_body,
      provenance: provenance
    }
  end

  defp model_failure_category({:invalid_model_output, _reason}),
    do: {:invalid_model_output, :unresolved}

  defp model_failure_category({:provider_failed, _reason}),
    do: {:provider_failed, :unresolved}

  defp model_failure_category({:fanout_synthesis_provider_attempt_mismatch, _counts}),
    do: {:provider_failed, :unresolved}

  defp model_failure_category({:profile_unavailable, _reason}),
    do: {:profile_unavailable, :not_run}

  defp model_failure_category(:fanout_composition_input_too_large),
    do: {:composition_input_too_large, :not_run}

  defp model_failure_category(:fanout_synthesis_timeout),
    do: {:synthesis_timeout, :unresolved}

  defp model_failure_category(:review_deadline_exhausted),
    do: {:deadline_exhausted, :not_run}

  defp model_failure_category({:phase_review_unresolved, _reason}),
    do: {:phase_review_unresolved, :unresolved}

  defp model_failure_category(reason),
    do: exit({:unexpected_fanout_synthesis_error, reason})

  defp model_enabled(%{model_enabled?: enabled?}) when is_boolean(enabled?) do
    if enabled?, do: :ok, else: {:error, :direct_answer_model_disabled}
  end

  defp model_enabled(_state) do
    case Settings.get("intent.direct_answer_model_enabled") do
      {:ok, true} -> :ok
      {:ok, false} -> {:error, :direct_answer_model_disabled}
      {:error, reason} -> {:error, {:settings_unavailable, reason}}
    end
  end

  defp retry_or_degrade(operation, payload, reason, state) do
    attempt = Map.fetch!(state.retry_attempts, operation)

    if transient_result?(reason) and attempt < state.max_retry_attempts do
      Process.send_after(self(), {:retry, operation, payload}, retry_delay(state, attempt))

      state
      |> put_in([:retry_attempts, operation], attempt + 1)
      |> Map.put(:phase, retry_phase(operation))
      |> Map.put(:drain_requested?, true)
    else
      %{state | phase: :degraded, drain_requested?: true}
    end
  end

  defp retry_delay(state, attempt) do
    min(state.retry_base_ms * Integer.pow(2, attempt), state.retry_max_ms)
  end

  defp retry_phase(:recover), do: :recovering
  defp retry_phase(:claim), do: :retrying_claim
  defp retry_phase(:select), do: :retrying_select

  defp reset_retry(state, operation),
    do: put_in(state, [:retry_attempts, operation], 0)

  defp transient_result?({:transient_database, summary}) when is_binary(summary), do: true
  defp transient_result?(_reason), do: false

  defp reset_all_retries(state),
    do: %{state | retry_attempts: %{recover: 0, claim: 0, select: 0}}

  defp recovery_succeeded(state) do
    state = reset_all_retries(state)

    if state.reconcile_requested? do
      send(self(), :recover)
      %{state | phase: :recovering, reconcile_requested?: false, drain_requested?: true}
    else
      send(self(), :drain)
      %{state | phase: :ready, drain_requested?: false}
    end
  end

  defp claim_queue_drained(state) do
    state = reset_retry(state, :claim)

    if state.reconcile_requested? do
      send(self(), :recover)
      %{state | phase: :recovering, reconcile_requested?: false, drain_requested?: true}
    else
      %{state | drain_requested?: false}
    end
  end

  defp request_reconcile(state) do
    state = %{state | drain_requested?: true}

    if state.phase in [:ready, :degraded] do
      send(self(), :recover)

      state
      |> reset_retry(:recover)
      |> Map.put(:phase, :recovering)
      |> Map.put(:reconcile_requested?, false)
    else
      %{state | reconcile_requested?: true}
    end
  end

  defp positive_integer_option(opts, key, default) do
    case Keyword.get(opts, key, default) do
      value when is_integer(value) and value > 0 -> value
      _invalid -> default
    end
  end

  defp non_negative_integer_option(opts, key, default) do
    case Keyword.get(opts, key, default) do
      value when is_integer(value) and value >= 0 -> value
      _invalid -> default
    end
  end

  defp schedule_reconcile(state) do
    Process.send_after(self(), :reconcile, state.reconcile_interval_ms)
  end

  defp retry_ready_recovery(state) do
    Process.send_after(self(), :recover, state.retry_base_ms)
    state
  end

  defp retry_ready_drain(state) do
    Process.send_after(self(), :drain, state.retry_base_ms)
    state
  end

  defp retry_ready_selection(claim, selection, state) do
    Process.send_after(self(), {:retry, :select, {claim, selection}}, state.retry_base_ms)
    state
  end

  defp admit_ready_epoch(state), do: effect_guard_call(state.effect_guard, :admit_ready, [])

  defp validate_epoch(epoch, state), do: effect_guard_call(state.effect_guard, :validate, [epoch])

  defp validate_claim_epoch(%{effect_context: %{allbert_pack_epoch: epoch}}, epoch, state),
    do: validate_epoch(epoch, state)

  defp validate_claim_epoch(_claim, _epoch, _state), do: {:error, :stale_epoch}

  defp effect_options(epoch, _state), do: [allbert_pack_epoch: epoch]

  defp effect_context(epoch, _state), do: %{allbert_pack_epoch: epoch}

  defp effect_guard_call({EffectGuard, server}, function, args),
    do: apply(EffectGuard, function, args ++ [[server: server]])

  defp effect_guard_call({module, owner}, function, args),
    do: apply(module, function, [owner | args])

  defp effect_guard_call(module, function, args), do: apply(module, function, args)

  defp store_call({module, owner}, function, args),
    do: safe_store_apply(module, function, [owner | args])

  defp store_call(module, function, args), do: safe_store_apply(module, function, args)

  defp safe_store_apply(module, function, args) do
    module
    |> apply(function, args)
    |> normalize_store_result()
  rescue
    exception ->
      if TransientError.transient?(exception),
        do: transient_store_error(exception),
        else: reraise(exception, __STACKTRACE__)
  catch
    :exit, reason ->
      if TransientError.transient?(reason), do: transient_store_error(reason), else: exit(reason)

    kind, reason ->
      :erlang.raise(kind, reason, __STACKTRACE__)
  end

  defp normalize_store_result({:error, {:transient_database, summary}} = error)
       when is_binary(summary),
       do: error

  defp normalize_store_result({:error, reason} = error) do
    if TransientError.transient?(reason), do: transient_store_error(reason), else: error
  end

  defp normalize_store_result(result), do: result

  defp transient_store_error(reason),
    do: {:error, {:transient_database, TransientError.summary(reason)}}
end
