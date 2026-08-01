defmodule AllbertAssist.FirstRun.Enablement do
  @moduledoc """
  Detection-to-enablement projection for zero-click first run.

  It projects the existing six model states, preserves raw explicit consent,
  selects local before hosted, and delegates the only write to Settings Store's
  atomic absent-subset primitive. Detection never provisions or probes hosted
  providers.
  """

  alias AllbertAssist.FirstRun.Disclosure
  alias AllbertAssist.FirstRun.UsableModel
  alias AllbertAssist.Settings
  alias AllbertAssist.Settings.Schema
  alias AllbertAssist.Settings.Store

  @model_states [
    :local_ready,
    :runtime_missing,
    :runtime_unhealthy,
    :model_missing,
    :below_hardware_floor,
    :byok_ready
  ]

  @unavailable_states %{
    local_ready: :enabled_unavailable,
    runtime_missing: :nothing_detected,
    runtime_unhealthy: :needs_model,
    model_missing: :needs_model,
    below_hardware_floor: :below_floor,
    byok_ready: :enabled_unavailable
  }

  @spec reconcile(atom(), keyword()) :: {:ok, map()} | {:error, term()}
  def reconcile(model_state, opts \\ [])

  def reconcile(model_state, opts) when model_state in @model_states do
    with {:ok, settings, user_settings} <- resolved_settings(opts) do
      reconcile_settings(model_state, settings, user_settings, opts)
    end
  end

  def reconcile(model_state, _opts), do: {:error, {:unknown_first_model_state, model_state}}

  @doc "Project the current enablement presentation without writing settings or disclosure state."
  @spec preview(atom(), keyword()) :: {:ok, map()} | {:error, term()}
  def preview(model_state, opts \\ [])

  def preview(model_state, opts) when model_state in @model_states do
    with {:ok, settings, user_settings} <- resolved_settings(opts) do
      preview_settings(model_state, settings, user_settings, opts)
    end
  end

  def preview(model_state, _opts), do: {:error, {:unknown_first_model_state, model_state}}

  @doc "Run boot reconciliation only when Req's supervised transport is available."
  @spec reconcile_on_boot(atom(), keyword()) ::
          {:ok, map()} | {:error, term()} | {:deferred, :req_not_started}
  def reconcile_on_boot(model_state, opts \\ []) do
    if req_started?(opts) do
      reconcile(model_state, opts)
    else
      {:deferred, :req_not_started}
    end
  rescue
    _exception -> {:deferred, :req_not_started}
  catch
    :exit, _reason -> {:deferred, :req_not_started}
  end

  defp reconcile_settings(model_state, settings, user_settings, opts) do
    case Schema.get_dotted(user_settings, "intent.direct_answer_model_enabled") do
      false -> result(:sticky_disabled, model_state, nil)
      true -> reconcile_explicit_enabled(model_state, settings, user_settings, opts)
      nil -> reconcile_absent(model_state, settings, user_settings, opts)
    end
  end

  defp preview_settings(model_state, settings, user_settings, opts) do
    case Schema.get_dotted(user_settings, "intent.direct_answer_model_enabled") do
      false -> preview_sticky_disabled(model_state, settings, user_settings, opts)
      true -> reconcile_enabled(model_state, settings, user_settings, opts)
      nil -> preview_absent(model_state, settings, user_settings, opts)
    end
  end

  defp preview_sticky_disabled(model_state, settings, user_settings, opts) do
    case selection_for(model_state, settings, user_settings, opts) do
      {:ok, selection} -> result(:sticky_disabled, model_state, selection)
      {:error, :no_usable_model} -> result(:sticky_disabled, model_state, nil)
    end
  end

  defp reconcile_enabled(model_state, settings, user_settings, opts) do
    case selection_for(model_state, settings, user_settings, opts) do
      {:ok, selection} ->
        result(:auto_enabled, model_state, selection)

      {:error, :no_usable_model} ->
        result(:enabled_unavailable, model_state, nil)
    end
  end

  defp reconcile_explicit_enabled(model_state, settings, user_settings, opts) do
    case selection_for(model_state, settings, user_settings, opts) do
      {:ok, selection} ->
        with :ok <- reconcile_current_disclosure(selection) do
          result(:auto_enabled, model_state, selection)
        end

      {:error, :no_usable_model} ->
        result(:enabled_unavailable, model_state, nil)
    end
  end

  defp reconcile_absent(model_state, settings, user_settings, opts) do
    case selection_for(model_state, settings, user_settings, opts) do
      {:ok, selection} ->
        enable(model_state, selection, settings, user_settings, opts)

      {:error, :no_usable_model} ->
        result(unavailable_or_repair_state(model_state), model_state, nil)
    end
  end

  defp preview_absent(model_state, settings, user_settings, opts) do
    case selection_for(model_state, settings, user_settings, opts) do
      {:ok, selection} ->
        result(:auto_enabled, model_state, selection)

      {:error, :no_usable_model} ->
        result(unavailable_or_repair_state(model_state), model_state, nil)
    end
  end

  defp selection_for(_model_state, settings, user_settings, opts) do
    case local_selection(settings, opts) do
      {:ok, selection} -> {:ok, selection}
      {:error, :no_usable_model} -> hosted_selection(settings, user_settings, opts)
    end
  end

  defp local_selection(settings, opts) do
    case Keyword.fetch(opts, :local_selection) do
      {:ok, selection} -> normalize_task_selection(selection, settings)
      :error -> UsableModel.select_local_for_task("direct_answer", settings, opts)
    end
  end

  defp hosted_selection(settings, user_settings, opts) do
    case Keyword.fetch(opts, :hosted_selection) do
      {:ok, selection} -> normalize_task_selection(selection, settings)
      :error -> UsableModel.select_hosted_for_task("direct_answer", settings, user_settings)
    end
  end

  defp normalize_selection(nil), do: {:error, :no_usable_model}
  defp normalize_selection({:ok, selection}), do: {:ok, selection}
  defp normalize_selection({:error, :no_usable_model} = error), do: error
  defp normalize_selection(selection) when is_map(selection), do: {:ok, selection}

  # Injected detections use the same purpose boundary as live selection. This
  # prevents a stale probe result from enabling one profile while the atomic
  # Settings write binds and discloses a different DirectAnswer task head.
  defp normalize_task_selection(selection, settings) do
    with {:ok, normalized} <- normalize_selection(selection),
         selected when is_binary(selected) <- Map.get(normalized, :profile),
         ^selected <- direct_answer_task_chain(settings) |> List.first() do
      {:ok, normalized}
    else
      _mismatch_or_missing -> {:error, :no_usable_model}
    end
  end

  defp enable(model_state, selection, settings, user_settings, opts) do
    task_chain = direct_answer_task_chain_for_write(settings, user_settings)

    values = %{
      "intent.direct_answer_model_enabled" => true,
      "intent.model_assist_enabled" => true,
      "model_preferences.tasks.direct_answer" => task_chain
    }

    context =
      opts
      |> Keyword.get(:context, %{})
      |> Map.merge(%{
        actor: "first-run",
        enabled_by: :detection,
        profile: selection.profile,
        provider: selection.provider,
        provider_class: selection.provider_class
      })

    # Pending-before-enable is the fail-closed order for hosted egress. A
    # crash here may repeat a disclosure, but can never enable transport with
    # no durable disclosure record.
    :ok = Disclosure.mark_pending(selection)
    run_before_write_hook(opts)

    case Store.put_user_settings_if_absent(values, context) do
      {:ok, %{disposition: :explicitly_disabled} = provenance} ->
        Disclosure.cancel_pending()
        result_with_provenance(:sticky_disabled, model_state, nil, provenance)

      {:ok, %{disposition: :selection_changed} = provenance} ->
        Disclosure.cancel_pending()
        result_with_provenance(:enabled_unavailable, model_state, nil, provenance)

      {:ok, provenance} ->
        with :ok <- reconcile_current_disclosure(selection) do
          result_with_provenance(:auto_enabled, model_state, selection, provenance)
        end

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp result(state, model_state, selection) do
    {:ok,
     %{
       state: state,
       model_state: model_state,
       selection: selection,
       availability: availability(selection),
       provenance: nil
     }}
  end

  defp result_with_provenance(state, model_state, selection, provenance) do
    {:ok,
     %{
       state: state,
       model_state: model_state,
       selection: selection,
       availability: availability(selection),
       provenance: provenance
     }}
  end

  defp availability(%{}), do: :available
  defp availability(nil), do: :unavailable

  defp reconcile_current_disclosure(selection) do
    case Settings.get("intent.direct_answer_model_enabled") do
      {:ok, true} ->
        case Disclosure.reconcile_current_direct_answer_route(selection) do
          :ok -> :ok
          {:error, _reason} -> Disclosure.reconcile(selection)
        end

      _disabled_or_unavailable ->
        Disclosure.reconcile(selection)
    end
  end

  defp run_before_write_hook(opts) do
    opts
    |> Keyword.get(:before_write, fn -> :ok end)
    |> then(fn hook -> hook.() end)
  end

  defp unavailable_or_repair_state(model_state),
    do: Map.fetch!(@unavailable_states, model_state)

  defp direct_answer_task_chain(settings) do
    case Schema.get_dotted(settings, "model_preferences.tasks.direct_answer") do
      profiles when is_list(profiles) and profiles != [] ->
        profiles

      _empty ->
        [Schema.get_dotted(settings, "model_preferences.primary")]
    end
    |> Enum.filter(&(is_binary(&1) and &1 != ""))
  end

  defp direct_answer_task_chain_for_write(settings, user_settings) do
    case Schema.get_dotted(user_settings, "model_preferences.tasks.direct_answer") do
      profiles when is_list(profiles) -> profiles
      _raw_absent -> direct_answer_task_chain(settings)
    end
  end

  defp resolved_settings(opts) do
    case {Keyword.fetch(opts, :settings), Keyword.fetch(opts, :user_settings)} do
      {{:ok, settings}, {:ok, user_settings}} -> {:ok, settings, user_settings}
      _other -> Store.resolved_settings()
    end
  end

  defp req_started?(opts) do
    ready? = Keyword.get(opts, :req_started?, &default_req_started?/0)
    ready?.()
  end

  defp default_req_started? do
    Enum.any?(Application.started_applications(), fn {app, _description, _version} ->
      app == :req
    end)
  end
end
