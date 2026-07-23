defmodule AllbertAssist.Signals do
  @moduledoc """
  Helpers for Allbert's runtime signal vocabulary.

  v0.04 keeps signal handling log-oriented. These helpers centralize signal
  construction and secret-safe action lifecycle summaries.
  """

  require Logger

  alias AllbertAssist.Runtime.Redactor
  alias Jido.Signal
  alias Jido.Signal.Bus

  @action_requested "allbert.action.requested"
  @action_completed "allbert.action.completed"
  @runtime_turn_started "allbert.runtime.turn.started"
  @runtime_turn_completed "allbert.runtime.turn.completed"
  @first_model_pull_progress "allbert.workspace.first_model.pull.progress"

  @registration_signal_types %{
    app_registered: "allbert.app.registered",
    app_unregistered: "allbert.app.unregistered",
    app_registry_cleared: "allbert.app.registry_cleared",
    plugin_registered: "allbert.plugin.registered",
    plugin_registry_cleared: "allbert.plugin.registry_cleared",
    action_registry_changed: "allbert.action.registry_changed"
  }

  @sandbox_signal_types %{
    backend_resolved: "allbert.sandbox.backend_resolved",
    command_started: "allbert.sandbox.command.started",
    command_completed: "allbert.sandbox.command.completed",
    command_denied: "allbert.sandbox.command.denied",
    gate_started: "allbert.sandbox.gate.started",
    gate_completed: "allbert.sandbox.gate.completed",
    cleanup: "allbert.sandbox.cleanup"
  }

  @dynamic_codegen_signal_types %{
    draft_requested: "allbert.dynamic_codegen.draft_requested",
    template_draft_created: "allbert.dynamic_codegen.template_draft_created",
    sandbox_report_recorded: "allbert.dynamic_codegen.sandbox_report_recorded",
    tier_transition: "allbert.dynamic_codegen.tier_transition",
    discarded: "allbert.dynamic_codegen.discarded",
    integration_attempted: "allbert.dynamic_codegen.integration_attempted",
    trusted_validation_passed: "allbert.dynamic_codegen.trusted_validation_passed",
    compiled: "allbert.dynamic_codegen.compiled",
    registered: "allbert.dynamic_codegen.registered",
    integrated: "allbert.dynamic_codegen.integrated",
    integration_denied: "allbert.dynamic_codegen.integration_denied",
    rollback_requested: "allbert.dynamic_codegen.rollback_requested",
    rolled_back: "allbert.dynamic_codegen.rolled_back",
    rollback_denied: "allbert.dynamic_codegen.rollback_denied",
    live_loader_disabled: "allbert.dynamic_codegen.live_loader_disabled",
    reconcile_completed: "allbert.dynamic_codegen.reconcile_completed",
    reconcile_denied: "allbert.dynamic_codegen.reconcile_denied"
  }

  @objective_signal_types %{
    created: "allbert.objective.created",
    updated: "allbert.objective.updated",
    step_proposed: "allbert.objective.step.proposed",
    step_selected: "allbert.objective.step.selected",
    step_completed: "allbert.objective.step.completed",
    step_failed: "allbert.objective.step.failed",
    observed: "allbert.objective.observed",
    blocked: "allbert.objective.blocked",
    completed: "allbert.objective.completed",
    cancelled: "allbert.objective.cancelled",
    impasse: "allbert.objective.impasse"
  }

  @fanout_signal_types %{
    fanout_started: "allbert.objectives.fanout.started",
    fanout_joined: "allbert.objectives.fanout.joined",
    run_started: "allbert.objectives.run.started",
    run_progress: "allbert.objectives.run.progress",
    run_blocked: "allbert.objectives.run.blocked",
    run_completed: "allbert.objectives.run.completed",
    run_failed: "allbert.objectives.run.failed",
    run_cancelled: "allbert.objectives.run.cancelled",
    run_steered: "allbert.objectives.run.steered"
  }

  @channel_signal_types %{
    update_received: "allbert.channel.update_received",
    message_rejected: "allbert.channel.message_rejected",
    runtime_submitted: "allbert.channel.runtime_submitted",
    response_sent: "allbert.channel.response_sent",
    delivery_failed: "allbert.channel.delivery_failed",
    callback_received: "allbert.channel.callback_received",
    notify_delivered: "allbert.channels.notify.delivered",
    notify_suppressed: "allbert.channels.notify.suppressed",
    notify_failed: "allbert.channels.notify.failed",
    notify_uncertain: "allbert.channels.notify.uncertain"
  }

  @doc "Return action lifecycle signal names."
  @spec action_signal_types() :: %{requested: String.t(), completed: String.t()}
  def action_signal_types do
    %{requested: @action_requested, completed: @action_completed}
  end

  @doc "Return canonical runtime turn signal names."
  @spec runtime_turn_signal_types() :: %{started: String.t(), completed: String.t()}
  def runtime_turn_signal_types do
    %{started: @runtime_turn_started, completed: @runtime_turn_completed}
  end

  @doc "Return registration lifecycle signal names."
  @spec registration_signal_types() :: %{atom() => String.t()}
  def registration_signal_types, do: @registration_signal_types

  @doc "Return channel lifecycle signal names."
  @spec channel_signal_types() :: %{atom() => String.t()}
  def channel_signal_types, do: @channel_signal_types

  @doc "Publish one redaction-safe autonomous-notification decision signal."
  def emit_channel_notify(event, metadata) when is_atom(event) and is_map(metadata) do
    key = String.to_existing_atom("notify_#{event}")

    case Map.fetch(@channel_signal_types, key) do
      {:ok, type} ->
        case Signal.new(type, Redactor.redact(metadata),
               source: "/allbert/channels/notify/#{event}",
               subject: Map.get(metadata, :fanout_id)
             ) do
          {:ok, signal} -> log(signal)
          {:error, reason} -> Logger.debug("notify signal skipped reason=#{inspect(reason)}")
        end

      :error ->
        Logger.debug("notify signal skipped unknown_event=#{inspect(event)}")
    end
  end

  @doc "Return objective lifecycle signal names."
  @spec objective_signal_types() :: %{atom() => String.t()}
  def objective_signal_types, do: @objective_signal_types

  @doc "Return v1.1 fan-out/run lifecycle signal names."
  @spec fanout_signal_types() :: %{atom() => String.t()}
  def fanout_signal_types, do: @fanout_signal_types

  @doc "Publish a redaction-safe v1.1 fan-out/run lifecycle signal."
  @spec emit_fanout(atom(), map()) :: :ok
  def emit_fanout(kind, metadata) when is_atom(kind) and is_map(metadata) do
    case Map.fetch(@fanout_signal_types, kind) do
      {:ok, type} ->
        case Signal.new(type, Redactor.redact(metadata),
               source: "/allbert/objectives/fanout/#{kind}",
               subject: Map.get(metadata, :child_id) || Map.get(metadata, :parent_id)
             ) do
          {:ok, signal} -> log(signal)
          {:error, reason} -> Logger.debug("fanout signal skipped reason=#{inspect(reason)}")
        end

      :error ->
        Logger.debug("fanout signal skipped unknown_kind=#{inspect(kind)}")
    end
  end

  @doc "Return sandbox lifecycle signal names."
  @spec sandbox_signal_types() :: %{atom() => String.t()}
  def sandbox_signal_types, do: @sandbox_signal_types

  @doc "Return dynamic codegen lifecycle signal names."
  @spec dynamic_codegen_signal_types() :: %{atom() => String.t()}
  def dynamic_codegen_signal_types, do: @dynamic_codegen_signal_types

  @doc "Create a sandbox lifecycle signal."
  @spec sandbox_lifecycle(atom(), map()) :: {:ok, Signal.t()} | {:error, term()}
  def sandbox_lifecycle(kind, metadata) when is_atom(kind) and is_map(metadata) do
    with {:ok, type} <- Map.fetch(@sandbox_signal_types, kind) do
      Signal.new(
        type,
        Redactor.redact(metadata),
        source: "/allbert/sandbox/#{kind}",
        subject: Map.get(metadata, :operator_id) || Map.get(metadata, "operator_id")
      )
    else
      :error -> {:error, {:unknown_sandbox_signal, kind}}
    end
  end

  @doc "Create a dynamic codegen lifecycle signal."
  @spec dynamic_codegen_lifecycle(atom(), map()) :: {:ok, Signal.t()} | {:error, term()}
  def dynamic_codegen_lifecycle(kind, metadata) when is_atom(kind) and is_map(metadata) do
    with {:ok, type} <- Map.fetch(@dynamic_codegen_signal_types, kind) do
      Signal.new(
        type,
        Redactor.redact(metadata),
        source: "/allbert/dynamic_codegen/#{kind}",
        subject: Map.get(metadata, :operator_id) || Map.get(metadata, "operator_id")
      )
    else
      :error -> {:error, {:unknown_dynamic_codegen_signal, kind}}
    end
  end

  @doc "Create a registration lifecycle signal."
  @spec registration_lifecycle(atom(), map()) :: {:ok, Signal.t()} | {:error, term()}
  def registration_lifecycle(kind, metadata) when is_atom(kind) and is_map(metadata) do
    with {:ok, type} <- Map.fetch(@registration_signal_types, kind) do
      Signal.new(
        type,
        Redactor.redact(metadata),
        source: "/allbert/registration/#{kind}",
        subject:
          Map.get(metadata, :app_id) ||
            Map.get(metadata, "app_id") ||
            Map.get(metadata, :plugin_id) ||
            Map.get(metadata, "plugin_id")
      )
    else
      :error -> {:error, {:unknown_registration_signal, kind}}
    end
  end

  @doc "Publish a registration lifecycle signal, logging and swallowing bus failures."
  @spec emit_registration(atom(), map()) :: :ok
  def emit_registration(kind, metadata) when is_atom(kind) and is_map(metadata) do
    case registration_lifecycle(kind, metadata) do
      {:ok, signal} -> log(signal)
      {:error, reason} -> Logger.debug("registration signal skipped reason=#{inspect(reason)}")
    end
  end

  @doc "Create a channel lifecycle signal."
  @spec channel_lifecycle(atom(), map()) :: {:ok, Signal.t()} | {:error, term()}
  def channel_lifecycle(kind, metadata) when is_atom(kind) and is_map(metadata) do
    with {:ok, type} <- Map.fetch(@channel_signal_types, kind) do
      Signal.new(
        type,
        Redactor.redact(metadata),
        source: "/allbert/channels/#{Map.get(metadata, :channel, "unknown")}",
        subject: Map.get(metadata, :user_id) || Map.get(metadata, "user_id")
      )
    else
      :error -> {:error, {:unknown_channel_signal, kind}}
    end
  end

  @doc "Create a canonical runtime turn-started signal."
  @spec runtime_turn_started(map()) :: {:ok, Signal.t()} | {:error, term()}
  def runtime_turn_started(metadata) when is_map(metadata) do
    runtime_turn_signal(@runtime_turn_started, metadata)
  end

  @doc "Create a canonical runtime turn-completed signal."
  @spec runtime_turn_completed(map()) :: {:ok, Signal.t()} | {:error, term()}
  def runtime_turn_completed(metadata) when is_map(metadata) do
    runtime_turn_signal(@runtime_turn_completed, metadata)
  end

  @doc "Create a workspace-routed first-model pull progress signal."
  @spec first_model_pull_progress(map()) :: {:ok, Signal.t()} | {:error, term()}
  def first_model_pull_progress(metadata) when is_map(metadata) do
    Signal.new(
      @first_model_pull_progress,
      Redactor.redact(metadata),
      source: "/allbert/first_model/pull",
      subject: Map.get(metadata, :user_id) || Map.get(metadata, "user_id")
    )
  end

  @doc "Publish first-model pull progress, best-effort."
  @spec emit_first_model_pull_progress(map()) :: :ok
  def emit_first_model_pull_progress(metadata) when is_map(metadata) do
    case first_model_pull_progress(metadata) do
      {:ok, signal} ->
        log(signal)

      {:error, reason} ->
        Logger.debug("first-model pull progress skipped reason=#{inspect(reason)}")
    end
  end

  @doc "Create an objective lifecycle signal."
  @spec objective_lifecycle(atom(), map()) :: {:ok, Signal.t()} | {:error, term()}
  def objective_lifecycle(kind, metadata) when is_atom(kind) and is_map(metadata) do
    with {:ok, type} <- Map.fetch(@objective_signal_types, kind) do
      Signal.new(
        type,
        metadata |> bound_objective_payload() |> Redactor.redact(),
        source: "/allbert/objectives/#{Map.get(metadata, :objective_id, "unknown")}",
        subject: Map.get(metadata, :user_id) || Map.get(metadata, "user_id")
      )
    else
      :error -> {:error, {:unknown_objective_signal, kind}}
    end
  end

  @doc "Create an action-requested signal."
  @spec action_requested(String.t(), module() | nil, map(), map()) ::
          {:ok, Signal.t()} | {:error, term()}
  def action_requested(action_name, action_module, params, context \\ %{}) do
    Signal.new(
      @action_requested,
      %{
        action_name: action_name,
        action_module: module_name(action_module),
        params: Redactor.redact(params),
        source_signal_id: source_signal_id(context),
        channel: request_value(context, :channel),
        operator_id: request_value(context, :operator_id),
        selected_skill: Map.get(context, :selected_skill),
        skill_metadata: Redactor.redact(Map.get(context, :skill_metadata)),
        action_capability: Redactor.redact(Map.get(context, :action_capability)),
        contract_status: contract_status(context)
      },
      source: "/allbert/actions/#{action_name}",
      subject: request_value(context, :operator_id)
    )
  end

  @doc "Create an action-completed signal."
  @spec action_completed(String.t(), module() | nil, atom(), map(), map(), non_neg_integer()) ::
          {:ok, Signal.t()} | {:error, term()}
  def action_completed(action_name, action_module, status, response, context, duration_ms) do
    Signal.new(
      @action_completed,
      %{
        action_name: action_name,
        action_module: module_name(action_module),
        status: status,
        duration_ms: duration_ms,
        permission_decision: permission_decision(response),
        selected_skill: Map.get(context, :selected_skill),
        skill_metadata: Redactor.redact(Map.get(context, :skill_metadata)),
        action_capability: Redactor.redact(Map.get(context, :action_capability)),
        contract_status: contract_status(context),
        response: response_summary(response),
        error: sanitized_error(response)
      },
      source: "/allbert/actions/#{action_name}",
      subject: request_value(context, :operator_id)
    )
  end

  @doc "Log a signal using the current runtime log style."
  @spec log(Signal.t()) :: :ok
  def log(%Signal{} = signal) do
    Logger.info("allbert signal #{signal.type} id=#{signal.id} source=#{signal.source}")
    publish(signal)
    :ok
  end

  @doc "Recursively redact values with sensitive key names."
  @spec redact(term()) :: term()
  defdelegate redact(value), to: Redactor

  defp runtime_turn_signal(type, metadata) do
    Signal.new(
      type,
      Redactor.redact(metadata),
      source: "/allbert/runtime/turn",
      subject: Map.get(metadata, :user_id) || Map.get(metadata, "user_id")
    )
  end

  defp publish(%Signal{} = signal) do
    case Bus.publish(AllbertAssist.SignalBus, [signal]) do
      {:ok, _recorded} ->
        :ok

      {:error, reason} ->
        Logger.debug(
          "allbert signal publish skipped type=#{signal.type} reason=#{inspect(reason)}"
        )

        :ok
    end
  rescue
    exception ->
      Logger.debug(
        "allbert signal publish failed type=#{signal.type} reason=#{Exception.message(exception)}"
      )

      :ok
  catch
    :exit, reason ->
      Logger.debug(
        "allbert signal publish unavailable type=#{signal.type} reason=#{inspect(reason)}"
      )

      :ok
  end

  defp bound_objective_payload(metadata) do
    metadata
    |> bound_string(:title, 200)
    |> bound_string(:objective, 2_000)
    |> bound_string(:acceptance_criteria, 2_000)
    |> bound_string(:observation_summary, 2_000)
    |> bound_string(:result_summary, 2_000)
    |> bound_string(:progress_summary, 2_000)
    |> bound_string(:reason, 500)
    |> bound_string(:error, 500)
  end

  defp bound_string(map, key, max) do
    case Map.fetch(map, key) do
      {:ok, value} when is_binary(value) and byte_size(value) > max ->
        Map.put(map, key, binary_part(value, 0, max) <> "...")

      _other ->
        map
    end
  end

  defp response_summary(%{} = response) do
    response
    |> Map.take([:message, :status, :permission_decision, :actions])
    |> Redactor.redact()
  end

  defp response_summary(response), do: Redactor.redact(response)

  defp permission_decision(%{permission_decision: decision}), do: Redactor.redact(decision)

  defp permission_decision(%{actions: actions}) when is_list(actions) do
    Enum.find_value(actions, &Map.get(&1, :permission_decision))
    |> Redactor.redact()
  end

  defp permission_decision(_response), do: nil

  defp sanitized_error(%{error: error}), do: inspect(error)
  defp sanitized_error(_response), do: nil

  defp request_value(%{request: request}, key) when is_map(request), do: Map.get(request, key)
  defp request_value(context, key) when is_map(context), do: Map.get(context, key)

  defp source_signal_id(%{request: %{input_signal_id: id}}), do: id
  defp source_signal_id(%{input_signal_id: id}), do: id
  defp source_signal_id(_context), do: nil

  defp contract_status(%{skill_metadata: %{capability_contract: %{validation_status: status}}}),
    do: status

  defp contract_status(%{
         skill_metadata: %{"capability_contract" => %{"validation_status" => status}}
       }),
       do: status

  defp contract_status(_context), do: nil

  defp module_name(nil), do: nil
  defp module_name(module) when is_atom(module), do: inspect(module)
end
