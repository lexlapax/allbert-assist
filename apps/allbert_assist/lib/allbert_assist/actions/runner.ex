defmodule AllbertAssist.Actions.Runner do
  @moduledoc """
  Shared runtime boundary for invoking registered Allbert Jido actions.
  """

  alias AllbertAssist.Actions.Capability
  alias AllbertAssist.Actions.ParamContract
  alias AllbertAssist.Actions.Registry
  alias AllbertAssist.Capabilities.ReleaseAvailability
  alias AllbertAssist.RegistryContext
  alias AllbertAssist.Runtime.Redactor
  alias AllbertAssist.Runtime.Response
  alias AllbertAssist.Signals
  alias Jido.Signal

  @type result :: {:ok, map()}

  @doc """
  Run a registered action by module or action name.

  Unknown action names and unregistered modules are denied without dynamic
  loading or invocation.
  """
  @spec run(module() | String.t() | atom(), map(), map()) :: result()
  def run(action_or_name, params, context \\ %{})

  def run(action_or_name, params, context) when is_map(params) and is_map(context) do
    case Registry.resolve(action_or_name, registry_opts(context)) do
      {:ok, action_module} ->
        run_registered(action_module, params, context)

      {:error, {:unknown_action, unknown}} ->
        unknown_action_response(unknown, params, context)
    end
  end

  def run(action_or_name, params, context) when is_map(context) do
    invalid_params_response(action_or_name, params, context)
  end

  defp run_registered(action_module, params, context) do
    action_name = action_module.name()
    started_at = System.monotonic_time(:millisecond)

    requested_signal =
      action_name
      |> Signals.action_requested(action_module, params, context)
      |> log_signal()

    runner_context = runner_context(context, action_module, requested_signal)

    response =
      case release_availability_check(action_name, action_module, registry_opts(context)) do
        :ok -> app_scope_or_run(action_module, params, runner_context)
        {:denied, response} -> {:ok, response}
      end
      |> Response.from_action_result(action_name)

    duration_ms = System.monotonic_time(:millisecond) - started_at
    status = response_status(response)

    completed_signal =
      action_name
      |> Signals.action_completed(action_module, status, response, context, duration_ms)
      |> log_signal()

    metadata = %{
      runner_action_id: runner_action_id(requested_signal),
      requested_signal_id: signal_id(requested_signal),
      completed_signal_id: signal_id(completed_signal),
      action_name: action_name,
      action_module: action_module,
      status: status,
      duration_ms: duration_ms,
      permission_decision: permission_decision(response),
      selected_skill: Map.get(context, :selected_skill),
      skill_metadata: Redactor.redact(Map.get(context, :skill_metadata)),
      action_capability: Redactor.redact(action_capability(context, action_module)),
      error: Map.get(response, :error)
    }

    {:ok, attach_runner_metadata(response, metadata)}
  end

  defp safe_run(action_module, params, context) do
    try do
      case ParamContract.normalize_and_validate(action_module, params) do
        {:ok, validated_params} ->
          action_module.run(validated_params, context)

        {:error, reason} ->
          {:ok, invalid_params_response(action_module, reason)}
      end
    rescue
      exception ->
        {:error, {exception.__struct__, Exception.message(exception)}}
    catch
      kind, reason ->
        {:error, {kind, reason}}
    end
  end

  defp invalid_params_response(action_module, reason) do
    action_name = action_module.name()
    redacted_reason = ParamContract.redacted_reason(reason)

    Response.error(
      "Action #{action_name} rejected: invalid params.",
      {:invalid_params, redacted_reason},
      actions: [
        Response.action(action_name, :error, error: {:invalid_params, redacted_reason})
      ],
      diagnostics: [
        %{
          code: :invalid_params,
          action: action_name,
          reason: redacted_reason
        }
      ]
    )
  end

  defp app_scope_or_run(action_module, params, runner_context) do
    case app_scope_check(action_module, runner_context) do
      :ok -> safe_run(action_module, params, runner_context)
      {:denied, response} -> {:ok, response}
    end
  end

  # v1.0.2 M8.2 (ADR 0082): the internal registry context rides the action
  # context map under `:registry` (mirroring `selected_skill`/`action_capability`
  # — never serialized params) so Runner registry reads resolve against the same
  # registries the caller holds. Production callers pass nothing.
  defp registry_opts(%{registry: registry}) when is_list(registry),
    do: RegistryContext.take(registry)

  defp registry_opts(_context), do: []

  defp runner_context(context, action_module, requested_signal) do
    Map.merge(context, %{
      action_metadata: action_module.__action_metadata__(),
      selected_action: action_module.name(),
      selected_action_module: action_module,
      runner_requested_signal_id: signal_id(requested_signal)
    })
  end

  defp unknown_action_response(unknown, params, context) do
    action_name = unknown_action_name(unknown)
    started_at = System.monotonic_time(:millisecond)

    requested_signal =
      action_name
      |> Signals.action_requested(nil, params, context)
      |> log_signal()

    response = Response.unknown_action(unknown, action_name)

    duration_ms = System.monotonic_time(:millisecond) - started_at

    completed_signal =
      action_name
      |> Signals.action_completed(nil, :denied, response, context, duration_ms)
      |> log_signal()

    metadata = %{
      runner_action_id: runner_action_id(requested_signal),
      requested_signal_id: signal_id(requested_signal),
      completed_signal_id: signal_id(completed_signal),
      action_name: action_name,
      action_module: nil,
      status: :denied,
      duration_ms: duration_ms,
      permission_decision: nil,
      selected_skill: Map.get(context, :selected_skill),
      skill_metadata: Redactor.redact(Map.get(context, :skill_metadata)),
      action_capability: Redactor.redact(Map.get(context, :action_capability)),
      error: {:unknown_action, unknown}
    }

    {:ok, attach_runner_metadata(response, metadata)}
  end

  # A non-map `params` payload never reaches an action body. The Runner is the
  # central seam that rejects it with `:invalid_params` — distinct from an
  # unknown/unregistered action — so callers get correct semantics and no action
  # runs on a malformed payload. The raw value is not embedded (it may carry
  # untrusted/sensitive content); only its shape is reported.
  defp invalid_params_response(action_or_name, _params, context) do
    action_name = unknown_action_name(action_or_name)
    started_at = System.monotonic_time(:millisecond)

    requested_signal =
      action_name
      |> Signals.action_requested(nil, %{}, context)
      |> log_signal()

    response =
      Response.error(
        "Action #{action_name} rejected: params must be a map.",
        {:invalid_params, :non_map},
        actions: [Response.action(action_name, :error, error: {:invalid_params, :non_map})]
      )

    duration_ms = System.monotonic_time(:millisecond) - started_at
    status = response_status(response)

    completed_signal =
      action_name
      |> Signals.action_completed(nil, status, response, context, duration_ms)
      |> log_signal()

    metadata = %{
      runner_action_id: runner_action_id(requested_signal),
      requested_signal_id: signal_id(requested_signal),
      completed_signal_id: signal_id(completed_signal),
      action_name: action_name,
      action_module: nil,
      status: status,
      duration_ms: duration_ms,
      permission_decision: nil,
      selected_skill: Map.get(context, :selected_skill),
      skill_metadata: Redactor.redact(Map.get(context, :skill_metadata)),
      action_capability: Redactor.redact(Map.get(context, :action_capability)),
      error: {:invalid_params, :non_map}
    }

    {:ok, attach_runner_metadata(response, metadata)}
  end

  defp attach_runner_metadata(response, metadata) do
    response
    |> Map.put(:runner_metadata, metadata)
    |> Map.update(:actions, [], fn actions ->
      Enum.map(actions, &attach_action_metadata(&1, metadata))
    end)
  end

  defp attach_action_metadata(action, metadata) do
    action
    |> Map.put(:runner_metadata, metadata)
    |> put_if_absent(:skill_metadata, metadata.skill_metadata)
    |> put_if_absent(:action_capability, metadata.action_capability)
  end

  defp put_if_absent(action, _key, nil), do: action
  defp put_if_absent(action, key, value), do: Map.put_new(action, key, value)

  defp response_status(response), do: Response.status(response)

  defp permission_decision(response) do
    direct_decision = Map.get(response, :permission_decision)

    action_decision =
      response
      |> Map.get(:actions, [])
      |> Enum.find_value(&Map.get(&1, :permission_decision))

    Redactor.redact(direct_decision || action_decision)
  end

  defp action_capability(context, action_module) do
    Map.get(context, :action_capability) ||
      case Registry.capability(action_module, registry_opts(context)) do
        {:ok, capability} -> Capability.summary(capability)
        {:error, _reason} -> nil
      end
  end

  defp release_availability_check(action_name, action_module, registry) do
    action_module
    |> release_refs(action_name, registry)
    |> Enum.find_value(:ok, fn ref ->
      case ReleaseAvailability.ensure_live_use_allowed(ref) do
        :ok ->
          false

        {:error, {status, decision}} ->
          {:denied, release_availability_blocked(action_name, status, decision)}
      end
    end)
  end

  defp release_refs(action_module, action_name, registry) do
    capability =
      case Registry.capability(action_module, registry) do
        {:ok, capability} -> capability
        {:error, _reason} -> %{}
      end

    [
      {:action, action_name},
      plugin_release_ref(Map.get(capability, :plugin_id)),
      app_release_ref(Map.get(capability, :app_id))
    ]
    |> Enum.reject(&is_nil/1)
  end

  defp plugin_release_ref(plugin_id) when is_binary(plugin_id), do: {:plugin, plugin_id}
  defp plugin_release_ref(_plugin_id), do: nil

  defp app_release_ref(app_id) when is_atom(app_id) and not is_nil(app_id),
    do: {:app, Atom.to_string(app_id)}

  defp app_release_ref(app_id) when is_binary(app_id), do: {:app, app_id}
  defp app_release_ref(_app_id), do: nil

  defp release_availability_blocked(action_name, status, decision) do
    reason = {status, %{kind: decision.kind, id: decision.id}}

    Response.unavailable(
      "Action #{action_name} is implemented but not released for live use: #{decision.decision}",
      reason,
      actions: [
        Response.action(action_name, :unavailable,
          error: reason,
          release_decision: Redactor.redact(decision)
        )
      ],
      release_decision: Redactor.redact(decision)
    )
  end

  defp app_scope_check(action_module, context) do
    case Registry.capability(action_module, registry_opts(context)) do
      {:ok, %{app_id: expected_app}} when not is_nil(expected_app) ->
        check_active_app_scope(action_module, expected_app, active_app(context))

      _other ->
        :ok
    end
  end

  defp check_active_app_scope(action_module, expected_app, raw_active_app) do
    case normalize_active_app(raw_active_app) do
      {:ok, ^expected_app} ->
        :ok

      {:ok, nil} ->
        {:denied, app_scope_denied(action_module, expected_app, nil, :missing_active_app_scope)}

      {:ok, normalized_active_app} ->
        {:denied, app_scope_denied(action_module, expected_app, normalized_active_app)}

      {:error, reason} ->
        {:denied, app_scope_denied(action_module, expected_app, raw_active_app, reason)}
    end
  end

  defp active_app(context) do
    Map.get(context, :active_app) ||
      Map.get(context, "active_app") ||
      get_in(context, [:request, :active_app]) ||
      get_in(context, ["request", "active_app"])
  end

  defp normalize_active_app(nil), do: {:ok, nil}
  defp normalize_active_app(""), do: {:ok, nil}
  defp normalize_active_app("none"), do: {:ok, nil}
  defp normalize_active_app("general"), do: {:ok, nil}

  defp normalize_active_app(app_id) when is_atom(app_id), do: {:ok, app_id}

  defp normalize_active_app(app_id) when is_binary(app_id) do
    normalized =
      app_id
      |> String.trim()
      |> String.downcase()

    cond do
      normalized in ["", "none", "general"] ->
        {:ok, nil}

      Regex.match?(~r/^[a-z][a-z0-9_]*$/, normalized) ->
        {:ok, String.to_existing_atom(normalized)}

      true ->
        {:error, :unknown_app}
    end
  rescue
    ArgumentError -> {:error, :unknown_app}
  end

  defp normalize_active_app(_app_id), do: {:error, :unknown_app}

  defp app_scope_denied(action_module, expected_app, active_app, reason \\ :app_scope_mismatch) do
    action_name = action_module.name()

    %{
      message:
        "Action #{action_name} is scoped to #{inspect(expected_app)} and cannot run from #{inspect(active_app)}.",
      status: :denied,
      error: {:app_scope_denied, reason},
      actions: [
        %{
          name: action_name,
          status: :denied,
          error: {:app_scope_denied, reason},
          app_scope: %{expected_app: expected_app, active_app: active_app}
        }
      ]
    }
  end

  defp log_signal({:ok, %Signal{} = signal}) do
    :ok = Signals.log(signal)
    signal
  end

  defp log_signal({:error, reason}) do
    raise ArgumentError, "could not create action lifecycle signal: #{inspect(reason)}"
  end

  defp signal_id(%Signal{id: id}), do: id

  defp runner_action_id(%Signal{id: id}), do: id

  defp unknown_action_name(unknown) when is_binary(unknown), do: unknown

  defp unknown_action_name(unknown) when is_atom(unknown) do
    unknown
    |> Atom.to_string()
    |> String.replace_prefix("Elixir.", "")
  end

  defp unknown_action_name(unknown), do: inspect(unknown)
end
