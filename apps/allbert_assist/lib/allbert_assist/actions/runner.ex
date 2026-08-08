defmodule AllbertAssist.Actions.Runner do
  @moduledoc """
  Shared runtime boundary for invoking registered Allbert Jido actions.
  """

  alias AllbertAssist.Actions.Capability
  alias AllbertAssist.Actions.ParamContract
  alias AllbertAssist.Actions.Registry
  alias AllbertAssist.Kernel.Contract
  alias AllbertAssist.Kernel.Contract.Membership
  alias AllbertAssist.Kernel.Contract.ReleaseAvailability
  alias AllbertAssist.Kernel.Contract.Signals
  alias AllbertAssist.Pack.EffectGuard
  alias AllbertAssist.RegistryContext
  alias AllbertAssist.Runtime.Response
  alias AllbertAssist.Security.Redactor
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
    with {:ok, ready_context} <- admit_ready_context(context) do
      case Registry.resolve(action_or_name, registry_opts(ready_context)) do
        {:ok, action_module} ->
          run_registered(action_module, params, ready_context)

        {:error, {:unknown_action, unknown}} ->
          unknown_action_response(unknown, params, ready_context)
      end
    else
      {:error, _readiness_reason} -> product_not_ready_response()
    end
  end

  def run(action_or_name, params, context) when is_map(context) do
    case admit_ready_context(context) do
      {:ok, ready_context} -> invalid_params_response(action_or_name, params, ready_context)
      {:error, _readiness_reason} -> product_not_ready_response()
    end
  end

  defp admit_ready_context(%{allbert_pack_activation: _carrier}),
    do: {:error, :product_not_ready}

  defp admit_ready_context(%{allbert_pack_epoch: epoch} = context) do
    with :ok <- EffectGuard.validate(epoch),
         :ok <- admit_bound_contracts() do
      {:ok, context}
    end
  end

  defp admit_ready_context(context) do
    with {:ok, epoch} <- EffectGuard.admit_ready(),
         :ok <- EffectGuard.validate(epoch),
         :ok <- admit_bound_contracts() do
      {:ok, Map.put(context, :allbert_pack_epoch, epoch)}
    end
  end

  # An action cannot run against an unbound kernel: every relocated concern
  # would fall to its fail-closed value while the caller believed the product
  # was ready. Refusing here returns the existing product-not-ready response.
  #
  # This asserts a binding exists, not that it matches the admitted epoch's
  # digest. Providers are process-independent module references, so a
  # test-scoped or replacement readiness barrier is still correctly served by
  # the bound set. Epoch identity is enforced where it belongs — by
  # `EffectGuard.validate/1` at the final boundary, and by the contract owner,
  # which releases the whole set when the barrier it was bound against dies.
  defp admit_bound_contracts do
    with {:ok, _implementation} <- Contract.fetch(:signals), do: :ok
  end

  defp product_not_ready_response do
    {:ok, Response.unavailable("Allbert product is not ready.", :product_not_ready)}
  end

  defp run_registered(action_module, params, context) do
    action_name = action_module.name()
    started_at = System.monotonic_time(:millisecond)
    requested_summary = trace_safe_summary(action_module, :params, params)

    requested_signal =
      action_name
      |> Signals.action_requested(action_module, requested_summary, context)
      |> log_signal()

    runner_context = runner_context(context, action_module, requested_signal)

    response =
      case release_availability_check(action_name, action_module, registry_opts(context)) do
        :ok -> app_scope_or_run(action_module, params, runner_context)
        {:denied, response} -> {:ok, response}
      end
      |> Response.canonical_action_result(action_name)

    duration_ms = System.monotonic_time(:millisecond) - started_at

    {response, status, completed_signal} =
      case completion_admission(response, context) do
        :ok ->
          status = response_status(response)

          completed_signal =
            action_name
            |> Signals.action_completed(
              action_module,
              status,
              trace_safe_summary(action_module, :result, response),
              context,
              duration_ms
            )
            |> log_signal()

          {response, status, completed_signal}

        {:error, _reason} ->
          unavailable = product_not_ready_response() |> elem(1)
          {unavailable, :unavailable, nil}
      end

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

  defp completion_admission(%{status: :unavailable, error: :product_not_ready}, _context),
    do: {:error, :product_not_ready}

  defp completion_admission(_response, context),
    do: EffectGuard.validate(Map.fetch!(context, :allbert_pack_epoch))

  defp safe_run(action_module, params, context) do
    try do
      case ParamContract.normalize_and_validate(action_module, params) do
        {:ok, validated_params} ->
          run_validated_action(action_module, validated_params, context)

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

  # Compatibility admission carries one exact epoch through the complete Runner
  # pipeline. The action call is the effect boundary, so validate that same
  # epoch after param validation and every Runner preflight, immediately before
  # invoking the action. Never admit again here: an E1 -> E2 replacement must
  # remain unavailable to this invocation rather than silently using E2.
  defp run_validated_action(action_module, validated_params, context) do
    case EffectGuard.validate(Map.fetch!(context, :allbert_pack_epoch)) do
      :ok -> action_module.run(validated_params, context)
      {:error, _reason} -> product_not_ready_response()
    end
  end

  defp trace_safe_summary(action_module, stage, value) do
    if function_exported?(action_module, :trace_safe_summary, 2) do
      try do
        case action_module.trace_safe_summary(stage, value) do
          summary when is_map(summary) -> wrap_trace_summary(stage, summary)
          _other -> wrap_trace_summary(stage, %{summary_unavailable: true})
        end
      rescue
        _exception -> wrap_trace_summary(stage, %{summary_unavailable: true})
      catch
        _kind, _reason -> wrap_trace_summary(stage, %{summary_unavailable: true})
      end
    else
      value
    end
  end

  defp wrap_trace_summary(:result, summary), do: %{__trace_safe_summary__: summary}
  defp wrap_trace_summary(_stage, summary), do: summary

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
    release_opts = [
      plugin_entries: Membership.registered_plugins(RegistryContext.plugin_opts(registry))
    ]

    action_module
    |> release_refs(action_name, registry)
    |> Enum.find_value(:ok, fn ref ->
      case ReleaseAvailability.ensure_live_use_allowed(ref, release_opts) do
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
        with :ok <- check_app_membership(action_module, expected_app, context) do
          check_active_app_scope(action_module, expected_app, active_app(context))
        end

      _other ->
        :ok
    end
  end

  defp check_app_membership(action_module, expected_app, context) do
    app_opts = context |> registry_opts() |> RegistryContext.app_opts()

    if Membership.known_app_id?(expected_app, app_opts) do
      :ok
    else
      {:denied,
       app_scope_denied(action_module, expected_app, active_app(context), :unregistered_app)}
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

    Response.denied(
      "Action #{action_name} is scoped to #{inspect(expected_app)} and cannot run from #{inspect(active_app)}.",
      error: {:app_scope_denied, reason},
      actions: [
        Response.action(action_name, :denied,
          error: {:app_scope_denied, reason},
          app_scope: %{expected_app: expected_app, active_app: active_app}
        )
      ]
    )
  end

  defp log_signal({:ok, %Signal{} = signal}) do
    :ok = Signals.log(signal)
    signal
  end

  defp log_signal({:error, reason}) do
    raise ArgumentError, "could not create action lifecycle signal: #{inspect(reason)}"
  end

  defp signal_id(%Signal{id: id}), do: id
  defp signal_id(nil), do: nil

  defp runner_action_id(%Signal{id: id}), do: id

  defp unknown_action_name(unknown) when is_binary(unknown), do: unknown

  defp unknown_action_name(unknown) when is_atom(unknown) do
    unknown
    |> Atom.to_string()
    |> String.replace_prefix("Elixir.", "")
  end

  defp unknown_action_name(unknown), do: inspect(unknown)
end
