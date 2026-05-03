defmodule AllbertAssist.Actions.Confirmations.ApproveConfirmation do
  @moduledoc false

  use Jido.Action,
    name: "approve_confirmation",
    description: "Approve a durable confirmation request without bypassing target action policy.",
    category: "confirmations",
    tags: ["confirmations", "approval"],
    schema: [
      id: [type: :string, required: true],
      reason: [type: :string, required: false]
    ],
    output_schema: [
      message: [type: :string, required: true],
      status: [type: :atom, required: true],
      actions: [type: {:list, :map}, required: true]
    ]

  alias AllbertAssist.Actions.Confirmations.Context
  alias AllbertAssist.Actions.Registry
  alias AllbertAssist.Actions.Runner
  alias AllbertAssist.Confirmations
  alias AllbertAssist.Security.PermissionGate
  alias AllbertAssist.Settings

  @online_action_names ~w[
    search_online_skills
    show_online_skill
    audit_online_skill
    import_online_skill
  ]

  @impl true
  def run(%{id: id} = params, context) do
    permission_decision = PermissionGate.authorize(:confirmation_decide, context)

    if PermissionGate.allowed?(permission_decision) do
      approve(id, Map.get(params, :reason), context, permission_decision)
    else
      Context.denied(
        "approve_confirmation",
        :confirmation_decide,
        permission_decision,
        :permission_denied
      )
    end
  end

  defp approve(id, reason, context, permission_decision) do
    case Confirmations.read(id) do
      {:ok, %{"status" => "pending"} = record} ->
        approve_pending(record, reason, context, permission_decision)

      {:ok, record} ->
        completed(record, permission_decision, idempotent?: true)

      {:error, reason} ->
        Context.denied("approve_confirmation", :confirmation_decide, permission_decision, reason)
    end
  end

  defp approve_pending(record, reason, context, permission_decision) do
    with :ok <- approval_surface_allowed(record, context) do
      target_decision =
        PermissionGate.authorize(target_permission(record), target_context(record, context))

      resolve_after_recheck(record, reason, context, permission_decision, target_decision)
    else
      {:error, reason} ->
        Context.denied("approve_confirmation", :confirmation_decide, permission_decision, reason)
    end
  end

  defp resolve_after_recheck(
         record,
         reason,
         context,
         permission_decision,
         %{decision: :denied} = target_decision
       ) do
    resolve_status(
      record,
      :denied,
      policy_denied_reason(reason, target_decision),
      context,
      permission_decision,
      %{
        target_policy_decision: target_decision,
        target_resumed?: false,
        blocked_by_policy?: true
      }
    )
  end

  defp resolve_after_recheck(record, reason, context, permission_decision, target_decision) do
    action_name = target_action_name(record)

    if Registry.resumable?(action_name) do
      resume_registered_action(
        record,
        reason,
        context,
        permission_decision,
        target_decision,
        action_name
      )
    else
      resolve_status(record, :adapter_unavailable, reason, context, permission_decision, %{
        target_policy_decision: target_decision,
        target_resumed?: false,
        adapter_unavailable?: true
      })
    end
  end

  defp resume_registered_action(
         record,
         reason,
         context,
         permission_decision,
         target_decision,
         action_name
       ) do
    case action_name do
      "external_network_request" ->
        resume_external_network_request(
          record,
          reason,
          context,
          permission_decision,
          target_decision
        )

      "run_shell_command" ->
        resume_shell_command(record, reason, context, permission_decision, target_decision)

      "run_package_install" ->
        resume_package_install(record, reason, context, permission_decision, target_decision)

      action_name when action_name in @online_action_names ->
        resume_online_action(
          record,
          reason,
          context,
          permission_decision,
          target_decision,
          action_name
        )

      "run_skill_script" ->
        resume_skill_script(record, reason, context, permission_decision, target_decision)

      _other ->
        resolve_status(record, :adapter_unavailable, reason, context, permission_decision, %{
          target_policy_decision: target_decision,
          target_resumed?: false,
          adapter_unavailable?: true
        })
    end
  end

  defp resume_external_network_request(
         %{"target_execution_mode" => "req_http"} = record,
         reason,
         context,
         permission_decision,
         target_decision
       ) do
    target_context =
      record
      |> target_context(context)
      |> put_in([:confirmation, :approved?], true)

    case Runner.run(
           "external_network_request",
           Map.get(record, "resume_params_ref", %{}),
           target_context
         ) do
      {:ok, %{status: status} = response} when status in [:completed, :failed] ->
        target_result = Map.get(response, :result, %{status: status})

        resolve_status(record, :approved, reason, context, permission_decision, %{
          target_policy_decision: target_decision,
          target_resumed?: true,
          target_status: status,
          target_result: target_result
        })

      {:ok, response} ->
        target_result = Map.get(response, :result, %{status: Map.get(response, :status)})
        target_status = Map.get(target_result, :status, Map.get(response, :status, :denied))

        resolve_status(
          record,
          :denied,
          reason || "External network target did not run: #{inspect(target_status)}",
          context,
          permission_decision,
          %{
            target_policy_decision: target_decision,
            target_resumed?: false,
            target_status: target_status,
            target_result: target_result,
            blocked_by_policy?: Map.get(response, :status) == :denied
          }
        )
    end
  end

  defp resume_external_network_request(
         record,
         reason,
         context,
         permission_decision,
         target_decision
       ) do
    resolve_status(record, :adapter_unavailable, reason, context, permission_decision, %{
      target_policy_decision: target_decision,
      target_resumed?: false,
      adapter_unavailable?: true
    })
  end

  defp resolve_status(record, status, reason, context, permission_decision, metadata) do
    id = Map.fetch!(record, "id")

    resolution_attrs =
      Context.resolution_attrs(context, reason, record, resolution_metadata(metadata))

    case Confirmations.resolve(id, status, resolution_attrs) do
      {:ok, record} ->
        completed(record, permission_decision, Map.put(metadata, :idempotent?, false))

      {:error, {:confirmation_not_pending, ^id}} ->
        idempotent(id, permission_decision)

      {:error, reason} ->
        Context.denied("approve_confirmation", :confirmation_decide, permission_decision, reason)
    end
  end

  defp idempotent(id, permission_decision) do
    case Confirmations.read(id) do
      {:ok, record} ->
        completed(record, permission_decision, idempotent?: true)

      {:error, reason} ->
        Context.denied("approve_confirmation", :confirmation_decide, permission_decision, reason)
    end
  end

  defp completed(record, permission_decision, metadata) do
    {:ok,
     %{
       message: Confirmations.status_message(record),
       status: :completed,
       permission_decision: permission_decision,
       confirmation: record,
       actions: [
         Context.action(
           record,
           "approve_confirmation",
           :completed,
           permission_decision,
           Map.new(metadata)
         )
       ]
     }}
  end

  defp resume_shell_command(record, reason, context, permission_decision, target_decision) do
    target_context =
      record
      |> target_context(context)
      |> put_in([:confirmation, :approved?], true)

    case Runner.run(
           "run_shell_command",
           Map.get(record, "resume_params_ref", %{}),
           target_context
         ) do
      {:ok, %{status: status} = response} when status in [:completed, :timed_out] ->
        target_result = Map.get(response, :result, %{})

        resolve_status(record, :approved, reason, context, permission_decision, %{
          target_policy_decision: target_decision,
          target_resumed?: true,
          target_status: status,
          target_result: target_result
        })

      {:ok, response} ->
        target_result = Map.get(response, :result, %{status: Map.get(response, :status)})

        resolve_status(
          record,
          :denied,
          reason || "Shell command target did not run: #{inspect(Map.get(response, :status))}",
          context,
          permission_decision,
          %{
            target_policy_decision: target_decision,
            target_resumed?: false,
            target_status: Map.get(response, :status, :denied),
            target_result: target_result,
            blocked_by_policy?: Map.get(response, :status) == :denied
          }
        )
    end
  end

  defp resume_package_install(record, reason, context, permission_decision, target_decision) do
    target_context =
      record
      |> target_context(context)
      |> put_in([:confirmation, :approved?], true)

    case Runner.run(
           "run_package_install",
           Map.get(record, "resume_params_ref", %{}),
           target_context
         ) do
      {:ok, %{status: status} = response} when status in [:completed, :failed, :timed_out] ->
        target_result = Map.get(response, :result, %{status: status})

        resolve_status(record, :approved, reason, context, permission_decision, %{
          target_policy_decision: target_decision,
          target_resumed?: true,
          target_status: status,
          target_result: target_result
        })

      {:ok, response} ->
        target_result = Map.get(response, :result, %{status: Map.get(response, :status)})
        target_status = Map.get(target_result, :status, Map.get(response, :status, :denied))

        resolve_status(
          record,
          :denied,
          reason || "Package install target did not run: #{inspect(target_status)}",
          context,
          permission_decision,
          %{
            target_policy_decision: target_decision,
            target_resumed?: false,
            target_status: target_status,
            target_result: target_result,
            blocked_by_policy?: Map.get(response, :status) == :denied
          }
        )
    end
  end

  defp resume_online_action(
         record,
         reason,
         context,
         permission_decision,
         target_decision,
         action_name
       ) do
    target_context =
      record
      |> target_context(context)
      |> put_in([:confirmation, :approved?], true)

    case Runner.run(action_name, Map.get(record, "resume_params_ref", %{}), target_context) do
      {:ok, %{status: status} = response} when status in [:completed, :failed] ->
        target_result = online_target_result(response)
        target_status = target_result_status(target_result, status)

        resolve_status(record, :approved, reason, context, permission_decision, %{
          target_policy_decision: target_decision,
          target_resumed?: true,
          target_status: target_status,
          target_result: target_result
        })

      {:ok, response} ->
        target_result = online_target_result(response)
        target_status = target_result_status(target_result, Map.get(response, :status, :denied))

        resolve_status(
          record,
          :denied,
          reason || "#{action_name} target did not run: #{inspect(target_status)}",
          context,
          permission_decision,
          %{
            target_policy_decision: target_decision,
            target_resumed?: false,
            target_status: target_status,
            target_result: target_result,
            blocked_by_policy?: Map.get(response, :status) == :denied
          }
        )
    end
  end

  defp online_target_result(response) do
    Map.get(response, :result) ||
      Map.get(response, :online_skill_search) ||
      Map.get(response, :online_skill_detail) ||
      Map.get(response, :online_skill_audit) ||
      Map.get(response, :online_skill_import) ||
      Map.get(response, :online_skill_import_request) ||
      %{status: Map.get(response, :status)}
  end

  defp target_result_status(target_result, default) when is_map(target_result) do
    Map.get(target_result, :status) || Map.get(target_result, "status") || default
  end

  defp target_result_status(_target_result, default), do: default

  defp resume_skill_script(record, reason, context, permission_decision, target_decision) do
    target_context =
      record
      |> target_context(context)
      |> put_in([:confirmation, :approved?], true)

    case Runner.run(
           "run_skill_script",
           Map.get(record, "resume_params_ref", %{}),
           target_context
         ) do
      {:ok, %{status: status} = response} when status in [:completed, :failed, :timed_out] ->
        target_result = Map.get(response, :result, %{status: status})

        resolve_status(record, :approved, reason, context, permission_decision, %{
          target_policy_decision: target_decision,
          target_resumed?: true,
          target_status: status,
          target_result: target_result
        })

      {:ok, response} ->
        target_result = Map.get(response, :result, %{status: Map.get(response, :status)})
        target_status = Map.get(target_result, :status, Map.get(response, :status, :denied))

        resolve_status(
          record,
          :denied,
          reason || "Skill script target did not run: #{inspect(target_status)}",
          context,
          permission_decision,
          %{
            target_policy_decision: target_decision,
            target_resumed?: false,
            target_status: target_status,
            target_result: target_result,
            blocked_by_policy?: Map.get(response, :status) == :denied
          }
        )
    end
  end

  defp resolution_metadata(metadata) do
    Map.take(metadata, [
      :target_resumed?,
      :target_status,
      :target_result,
      :adapter_unavailable?
    ])
  end

  defp approval_surface_allowed(record, context) do
    with :ok <- approval_channel_allowed(context),
         :ok <- cross_channel_allowed(record, context) do
      :ok
    end
  end

  defp approval_channel_allowed(context) do
    case channel_key(channel(context)) do
      "cli" ->
        setting_allowed?("confirmations.allow_cli_approval", :cli_approval_disabled)

      "live_view" ->
        setting_allowed?("confirmations.allow_liveview_approval", :liveview_approval_disabled)

      _other ->
        :ok
    end
  end

  defp cross_channel_allowed(record, context) do
    origin_channel =
      record
      |> Map.get("origin", %{})
      |> Map.get("channel")
      |> channel_key()

    resolver_channel = context |> channel() |> channel_key()

    if origin_channel == resolver_channel do
      :ok
    else
      setting_allowed?(
        "confirmations.allow_cross_channel_approval",
        :cross_channel_approval_disabled
      )
    end
  end

  defp setting_allowed?(key, reason) do
    case Settings.get(key) do
      {:ok, false} -> {:error, reason}
      _other -> :ok
    end
  end

  defp target_context(record, context) do
    target = Map.get(record, "target_action", %{})
    selected_skill = selected_skill_name(record)
    skill_metadata = if selected_skill, do: Map.get(record, "selected_skill", %{}), else: %{}

    Map.merge(context, %{
      selected_action: Map.get(target, "name"),
      selected_action_module: Map.get(target, "module"),
      action_metadata: %{
        name: Map.get(target, "name"),
        confirmation_id: Map.get(record, "id"),
        confirmation_status: Map.get(record, "status"),
        target_permission: Map.get(record, "target_permission")
      },
      confirmation: %{
        id: Map.get(record, "id"),
        origin: Map.get(record, "origin", %{}),
        resolver: resolver_context(context),
        target_execution_mode: Map.get(record, "target_execution_mode")
      },
      action_capability: Map.get(record, "capability_contract", %{}),
      selected_skill: selected_skill,
      skill_metadata: skill_metadata
    })
  end

  defp selected_skill_name(record) do
    record
    |> get_in(["selected_skill", "name"])
    |> nilish()
  end

  defp nilish(value) when value in [nil, "", "nil"], do: nil
  defp nilish(value), do: value

  defp resolver_context(context) do
    %{
      actor: actor(context),
      channel: channel(context),
      surface: surface(context),
      session_id: session_id(context)
    }
  end

  defp target_permission(record) do
    target_permission = Map.get(record, "target_permission")

    Enum.find(PermissionGate.permission_classes(), :unknown_permission, fn permission ->
      Atom.to_string(permission) == target_permission
    end)
  end

  defp target_action_name(record), do: get_in(record, ["target_action", "name"])

  defp policy_denied_reason(nil, target_decision) do
    "Security Central denied approval re-check: #{Map.get(target_decision, :reason)}"
  end

  defp policy_denied_reason(reason, _target_decision), do: reason

  defp actor(%{request: %{operator_id: actor}}), do: actor
  defp actor(%{request: %{"operator_id" => actor}}), do: actor
  defp actor(%{actor: actor}), do: actor
  defp actor(%{"actor" => actor}), do: actor
  defp actor(_context), do: "local"

  defp channel(%{request: %{channel: channel}}), do: channel
  defp channel(%{request: %{"channel" => channel}}), do: channel
  defp channel(%{channel: channel}), do: channel
  defp channel(%{"channel" => channel}), do: channel
  defp channel(_context), do: :unknown

  defp surface(%{surface: surface}), do: surface
  defp surface(%{"surface" => surface}), do: surface
  defp surface(_context), do: "action"

  defp session_id(%{session_id: session_id}), do: session_id
  defp session_id(%{"session_id" => session_id}), do: session_id
  defp session_id(%{request: %{session_id: session_id}}), do: session_id
  defp session_id(%{request: %{"session_id" => session_id}}), do: session_id
  defp session_id(_context), do: nil

  defp channel_key(:liveview), do: "live_view"
  defp channel_key("liveview"), do: "live_view"
  defp channel_key(value) when is_atom(value), do: Atom.to_string(value)
  defp channel_key(value) when is_binary(value), do: value
  defp channel_key(value), do: inspect(value)
end
