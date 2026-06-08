defmodule AllbertAssist.Actions.Confirmations.ApproveConfirmation do
  @moduledoc false

  use AllbertAssist.Action,
    permission: :confirmation_decide,
    exposure: :internal,
    execution_mode: :confirmation_decision,
    skill_backed?: false,
    confirmation: :not_required,
    notes: "Approves a pending request; target resumption remains version-scoped.",
    name: "approve_confirmation",
    description: "Approve a durable confirmation request without bypassing target action policy.",
    category: "confirmations",
    tags: ["confirmations", "approval"],
    schema: [
      id: [type: :string, required: true],
      reason: [type: :string, required: false],
      remember_scope: [type: :string, required: false],
      resource_index: [type: :integer, required: false],
      remember_all: [type: :boolean, required: false],
      expires_at: [type: :string, required: false]
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
  alias AllbertAssist.Conversations
  alias AllbertAssist.Objectives
  alias AllbertAssist.PlanBuild
  alias AllbertAssist.Resources.GrantHandoff
  alias AllbertAssist.Runtime.MediaOutputs
  alias AllbertAssist.Runtime.Redactor
  alias AllbertAssist.Security.PermissionGate
  alias AllbertAssist.Settings

  @online_action_names ~w[
    search_online_skills
    show_online_skill
    audit_online_skill
    import_online_skill
    import_remote_skill
    import_local_skill
  ]

  @dynamic_integration_action_names ~w[
    integrate_dynamic_draft
    rollback_dynamic_integration
  ]

  @memory_action_names ~w[
    delete_memory_entry
    prune_memory_entries
    promote_conversation_turn
    sync_app_lesson
  ]

  @self_improvement_action_names ~w[
    promote_skill_draft
    promote_workflow_draft
    promote_memory_draft
    promote_objective_draft
  ]

  @mcp_action_names ~w[
    mcp_server_connect
    mcp_read_resource
    mcp_call_tool
  ]

  @notes_files_action_names ~w[
    write_note
  ]

  @voice_provider_action_names ~w[
    transcribe_voice
    synthesize_voice
    generate_image
  ]

  @impl true
  def run(%{id: id} = params, context) do
    permission_decision = PermissionGate.authorize(:confirmation_decide, context)
    context = Map.put(context, :approval_params, params)

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

    if action_name == PlanBuild.Runtime.plan_step_confirm_action() do
      resume_plan_step_confirm(record, reason, context, permission_decision, target_decision)
    else
      maybe_resume_registered_action(
        record,
        reason,
        context,
        permission_decision,
        target_decision,
        action_name
      )
    end
  end

  defp maybe_resume_registered_action(
         record,
         reason,
         context,
         permission_decision,
         target_decision,
         action_name
       ) do
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
       )
       when action_name in @dynamic_integration_action_names do
    resume_dynamic_integration_action(
      record,
      reason,
      context,
      permission_decision,
      target_decision,
      action_name
    )
  end

  defp resume_registered_action(
         record,
         reason,
         context,
         permission_decision,
         target_decision,
         "external_network_request"
       ) do
    resume_external_network_request(record, reason, context, permission_decision, target_decision)
  end

  defp resume_registered_action(
         record,
         reason,
         context,
         permission_decision,
         target_decision,
         "run_shell_command"
       ) do
    resume_shell_command(record, reason, context, permission_decision, target_decision)
  end

  defp resume_registered_action(
         record,
         reason,
         context,
         permission_decision,
         target_decision,
         "capture_workspace_voice"
       ) do
    resume_voice_capture(record, reason, context, permission_decision, target_decision)
  end

  defp resume_registered_action(
         record,
         reason,
         context,
         permission_decision,
         target_decision,
         action_name
       )
       when action_name in @voice_provider_action_names do
    resume_voice_provider_action(
      record,
      reason,
      context,
      permission_decision,
      target_decision,
      action_name
    )
  end

  defp resume_registered_action(
         record,
         reason,
         context,
         permission_decision,
         target_decision,
         "run_package_install"
       ) do
    resume_package_install(record, reason, context, permission_decision, target_decision)
  end

  defp resume_registered_action(
         record,
         reason,
         context,
         permission_decision,
         target_decision,
         action_name
       )
       when action_name in @online_action_names do
    resume_online_action(
      record,
      reason,
      context,
      permission_decision,
      target_decision,
      action_name
    )
  end

  defp resume_registered_action(
         record,
         reason,
         context,
         permission_decision,
         target_decision,
         "run_skill_script"
       ) do
    resume_skill_script(record, reason, context, permission_decision, target_decision)
  end

  defp resume_registered_action(
         record,
         reason,
         context,
         permission_decision,
         target_decision,
         action_name
       )
       when action_name in @memory_action_names do
    resume_memory_action(
      record,
      reason,
      context,
      permission_decision,
      target_decision,
      action_name
    )
  end

  defp resume_registered_action(
         record,
         reason,
         context,
         permission_decision,
         target_decision,
         action_name
       )
       when action_name in @self_improvement_action_names do
    resume_self_improvement_action(
      record,
      reason,
      context,
      permission_decision,
      target_decision,
      action_name
    )
  end

  defp resume_registered_action(
         record,
         reason,
         context,
         permission_decision,
         target_decision,
         action_name
       )
       when action_name in @mcp_action_names do
    resume_mcp_action(record, reason, context, permission_decision, target_decision, action_name)
  end

  defp resume_registered_action(
         record,
         reason,
         context,
         permission_decision,
         target_decision,
         action_name
       )
       when action_name in @notes_files_action_names do
    resume_notes_files_action(
      record,
      reason,
      context,
      permission_decision,
      target_decision,
      action_name
    )
  end

  defp resume_registered_action(
         record,
         reason,
         context,
         permission_decision,
         target_decision,
         "run_analysis"
       ) do
    resume_run_analysis(record, reason, context, permission_decision, target_decision)
  end

  defp resume_registered_action(
         record,
         reason,
         context,
         permission_decision,
         target_decision,
         "start_plan_run"
       ) do
    resume_start_plan_run(record, reason, context, permission_decision, target_decision)
  end

  defp resume_registered_action(
         record,
         reason,
         context,
         permission_decision,
         target_decision,
         _action_name
       ) do
    resolve_status(record, :adapter_unavailable, reason, context, permission_decision, %{
      target_policy_decision: target_decision,
      target_resumed?: false,
      adapter_unavailable?: true
    })
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

  defp resume_voice_capture(record, reason, context, permission_decision, target_decision) do
    target_context =
      record
      |> target_context(context)
      |> put_in([:confirmation, :approved?], true)

    case Runner.run(
           "capture_workspace_voice",
           Map.get(record, "resume_params_ref", %{}),
           target_context
         ) do
      {:ok, %{status: :completed} = response} ->
        target_result = %{
          status: :completed,
          output_data: Map.get(response, :output_data, %{})
        }

        resolve_status(record, :approved, reason, context, permission_decision, %{
          target_policy_decision: target_decision,
          target_resumed?: true,
          target_status: :completed,
          target_result: target_result
        })

      {:ok, response} ->
        target_status = Map.get(response, :status, :denied)

        resolve_status(
          record,
          :denied,
          reason || "Workspace microphone capture did not start: #{inspect(target_status)}",
          context,
          permission_decision,
          %{
            target_policy_decision: target_decision,
            target_resumed?: false,
            target_status: target_status,
            target_result: %{status: target_status},
            blocked_by_policy?: target_status == :denied
          }
        )
    end
  end

  defp resume_voice_provider_action(
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
      {:ok, %{status: :completed} = response} ->
        resolve_status(record, :approved, reason, context, permission_decision, %{
          target_policy_decision: target_decision,
          target_resumed?: true,
          target_status: :completed,
          target_result: provider_target_result(action_name, response),
          output_data: provider_output_data(action_name, response)
        })

      {:ok, response} ->
        target_status = Map.get(response, :status, :denied)

        resolve_status(record, :approved, reason, context, permission_decision, %{
          target_policy_decision: target_decision,
          target_resumed?: true,
          target_status: target_status,
          target_result: provider_target_result(action_name, response),
          output_data: provider_output_data(action_name, response)
        })
    end
  end

  defp resolve_status(record, status, reason, context, permission_decision, metadata) do
    id = Map.fetch!(record, "id")

    with {:ok, remembered_grants} <- maybe_remember_grants(record, status, context) do
      metadata =
        if remembered_grants == [] do
          metadata
        else
          Map.put(
            metadata,
            :remembered_grants,
            Enum.map(remembered_grants, &GrantHandoff.summary/1)
          )
        end

      resolution_attrs =
        Context.resolution_attrs(context, reason, record, resolution_metadata(metadata))

      case Confirmations.resolve(id, status, resolution_attrs) do
        {:ok, record} ->
          completed(record, permission_decision, Map.put(metadata, :idempotent?, false))

        {:error, {:confirmation_not_pending, ^id}} ->
          idempotent(id, permission_decision)

        {:error, reason} ->
          Context.denied(
            "approve_confirmation",
            :confirmation_decide,
            permission_decision,
            reason
          )
      end
    else
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
    metadata = Map.new(metadata)

    output_data =
      Map.get(metadata, :output_data) ||
        metadata
        |> Map.get(:target_result, %{})
        |> case do
          %{output_data: output_data} -> output_data
          %{"output_data" => output_data} -> output_data
          _other -> nil
        end

    media_outputs = MediaOutputs.collect(output_data || %{})

    response = %{
      message: Confirmations.status_message(record),
      status: :completed,
      permission_decision: permission_decision,
      confirmation: Confirmations.redact_for_output(record),
      output_data: output_data,
      actions: [
        Context.action(
          record,
          "approve_confirmation",
          :completed,
          permission_decision,
          metadata
        )
      ]
    }

    {:ok, maybe_put_media_outputs(response, media_outputs)}
  end

  defp maybe_put_media_outputs(response, []), do: response

  defp maybe_put_media_outputs(response, media_outputs),
    do: Map.put(response, :media_outputs, media_outputs)

  defp resume_start_plan_run(record, reason, context, permission_decision, target_decision) do
    target_context =
      record
      |> target_context(context)
      |> put_in([:confirmation, :approved?], true)

    case Runner.run("start_plan_run", Map.get(record, "resume_params_ref", %{}), target_context) do
      {:ok, %{status: status} = response}
      when status in [:completed, :needs_confirmation, :failed, :cancelled] ->
        target_result = %{status: status, output_data: Map.get(response, :output_data, %{})}

        resolve_status(record, :approved, reason, context, permission_decision, %{
          target_policy_decision: target_decision,
          target_resumed?: true,
          target_status: status,
          target_result: target_result
        })

      {:ok, response} ->
        target_status = Map.get(response, :status, :denied)

        resolve_status(
          record,
          :denied,
          reason || "Plan run target did not start: #{inspect(target_status)}",
          context,
          permission_decision,
          %{
            target_policy_decision: target_decision,
            target_resumed?: false,
            target_status: target_status,
            target_result: %{
              status: target_status,
              output_data: Map.get(response, :output_data, %{})
            },
            blocked_by_policy?: target_status == :denied
          }
        )
    end
  end

  defp resume_plan_step_confirm(record, reason, context, permission_decision, target_decision) do
    resume_params = Map.get(record, "resume_params_ref", %{})
    objective_id = Map.get(resume_params, "objective_id") || Map.get(resume_params, :objective_id)

    target_context =
      record
      |> target_context(context)
      |> put_in([:confirmation, :approved?], true)

    with {:ok, approved} <-
           resolve_status(record, :approved, reason, context, permission_decision, %{
             target_policy_decision: target_decision,
             target_resumed?: true,
             target_status: :approved,
             target_result: %{status: :approved}
           }),
         {:ok, advanced} <- PlanBuild.Runtime.advance(objective_id, target_context) do
      output_data =
        Map.merge(Map.get(approved, :output_data, %{}) || %{}, %{
          objective_id: objective_id,
          run_status: advanced.status,
          confirmation_id: Map.get(advanced, :confirmation_id)
        })

      {:ok,
       approved
       |> Map.put(:output_data, output_data)
       |> Map.put(:plan_run, advanced)}
    end
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

  defp resume_memory_action(
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
      {:ok, %{status: :completed} = response} ->
        target_result =
          Map.get(response, :archived) ||
            Map.get(response, :memory) ||
            %{
              status: :completed,
              archived_count: get_in(response, [:actions, Access.at(0), :archived_count])
            }

        resolve_status(record, :approved, reason, context, permission_decision, %{
          target_policy_decision: target_decision,
          target_resumed?: true,
          target_status: :completed,
          target_result: target_result
        })

      {:ok, response} ->
        resolve_status(
          record,
          :denied,
          reason || "#{action_name} target did not run: #{inspect(Map.get(response, :status))}",
          context,
          permission_decision,
          %{
            target_policy_decision: target_decision,
            target_resumed?: false,
            target_status: Map.get(response, :status, :denied),
            target_result: %{status: Map.get(response, :status), error: Map.get(response, :error)},
            blocked_by_policy?: Map.get(response, :status) == :denied
          }
        )
    end
  end

  defp resume_self_improvement_action(
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
      {:ok, %{status: :completed} = response} ->
        target_result =
          Map.get(response, :result) ||
            Map.get(response, :skill) ||
            Map.get(response, :workflow) ||
            Map.get(response, :memory) ||
            %{status: :completed}

        resolve_status(record, :approved, reason, context, permission_decision, %{
          target_policy_decision: target_decision,
          target_resumed?: true,
          target_status: :completed,
          target_result: target_result
        })

      {:ok, response} ->
        resolve_status(
          record,
          :denied,
          reason || "#{action_name} target did not run: #{inspect(Map.get(response, :status))}",
          context,
          permission_decision,
          %{
            target_policy_decision: target_decision,
            target_resumed?: false,
            target_status: Map.get(response, :status, :denied),
            target_result: %{status: Map.get(response, :status), error: Map.get(response, :error)},
            blocked_by_policy?: Map.get(response, :status) == :denied
          }
        )
    end
  end

  defp resume_mcp_action(
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
      {:ok, %{status: :completed} = response} ->
        target_result =
          Map.get(response, :connection) ||
            Map.get(response, :resource) ||
            Map.get(response, :tool_call) ||
            %{status: :completed}

        resolve_status(record, :approved, reason, context, permission_decision, %{
          target_policy_decision: target_decision,
          target_resumed?: true,
          target_status: :completed,
          target_result: target_result
        })

      {:ok, response} ->
        resolve_status(
          record,
          :denied,
          reason || "#{action_name} target did not run: #{inspect(Map.get(response, :status))}",
          context,
          permission_decision,
          %{
            target_policy_decision: target_decision,
            target_resumed?: false,
            target_status: Map.get(response, :status, :denied),
            target_result: %{status: Map.get(response, :status), error: Map.get(response, :error)},
            blocked_by_policy?: Map.get(response, :status) == :denied
          }
        )
    end
  end

  defp resume_notes_files_action(
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
      {:ok, %{status: :completed} = response} ->
        target_result = Map.get(response, :note, %{status: :completed})

        resolve_status(record, :approved, reason, context, permission_decision, %{
          target_policy_decision: target_decision,
          target_resumed?: true,
          target_status: :completed,
          target_result: target_result
        })

      {:ok, response} ->
        resolve_status(
          record,
          :denied,
          reason || "#{action_name} target did not run: #{inspect(Map.get(response, :status))}",
          context,
          permission_decision,
          %{
            target_policy_decision: target_decision,
            target_resumed?: false,
            target_status: Map.get(response, :status, :denied),
            target_result: %{status: Map.get(response, :status), error: Map.get(response, :error)},
            blocked_by_policy?: Map.get(response, :status) == :denied
          }
        )
    end
  end

  defp resume_run_analysis(record, reason, context, permission_decision, target_decision) do
    target_context =
      record
      |> target_context(context)
      |> put_in([:confirmation, :approved?], true)

    resume_params = Map.get(record, "resume_params_ref", %{})
    confirmation_id = Map.fetch!(record, "id")

    initial_metadata = %{
      target_policy_decision: target_decision,
      target_resumed?: true,
      target_status: :running,
      target_result: run_analysis_start_result(record, resume_params),
      target_async?: live_view_async_run_analysis?(resume_params, context)
    }

    {:ok, approval} =
      resolve_status(record, :approved, reason, context, permission_decision, initial_metadata)

    mark_run_analysis_step_running(record, resume_params, context)

    if live_view_async_run_analysis?(resume_params, context) do
      start_run_analysis_resume_task(
        confirmation_id,
        record,
        resume_params,
        target_context,
        context
      )

      {:ok, approval}
    else
      response = run_analysis_resume(resume_params, target_context)
      metadata = final_run_analysis_metadata(response)

      updated_record =
        case Confirmations.annotate_resolution(confirmation_id, metadata) do
          {:ok, record} -> record
          {:error, _reason} -> Map.get(approval, :confirmation)
        end

      mark_run_analysis_step_finished(record, response, context)
      {:ok, put_run_analysis_approval_metadata(approval, metadata, updated_record)}
    end
  end

  defp resume_dynamic_integration_action(
         record,
         reason,
         context,
         permission_decision,
         target_decision,
         action_name
       ) do
    with {:ok, approved_record} <-
           resolve_dynamic_approval_before_resume(record, reason, context) do
      target_context =
        approved_record
        |> target_context(context)
        |> put_in([:confirmation, :approved?], true)

      case Runner.run(action_name, Map.get(record, "resume_params_ref", %{}), target_context) do
        {:ok, %{status: :completed} = response} ->
          target_result = Map.get(response, :dynamic_plugin_metadata, %{status: :completed})

          complete_dynamic_resume(approved_record, permission_decision, %{
            target_policy_decision: target_decision,
            target_resumed?: true,
            target_status: :completed,
            target_result: target_result
          })

        {:ok, response} ->
          target_result =
            Map.get(response, :dynamic_plugin_metadata, %{
              status: Map.get(response, :status),
              error: Map.get(response, :error)
            })

          complete_dynamic_resume(approved_record, permission_decision, %{
            target_policy_decision: target_decision,
            target_resumed?: false,
            target_status: Map.get(response, :status, :denied),
            target_result: target_result,
            blocked_by_policy?: Map.get(response, :status) == :denied
          })
      end
    else
      {:error, reason} ->
        Context.denied("approve_confirmation", :confirmation_decide, permission_decision, reason)
    end
  end

  defp resolve_dynamic_approval_before_resume(record, reason, context) do
    resolution_attrs =
      Context.resolution_attrs(context, reason, record, %{
        target_resumed?: false,
        target_status: :resuming,
        target_result: %{status: :resuming}
      })

    Confirmations.resolve(Map.fetch!(record, "id"), :approved, resolution_attrs)
  end

  defp complete_dynamic_resume(record, permission_decision, metadata) do
    attrs = resolution_metadata(metadata)

    case Confirmations.annotate_resolution(Map.fetch!(record, "id"), attrs) do
      {:ok, updated_record} ->
        completed(updated_record, permission_decision, Map.put(metadata, :idempotent?, false))

      {:error, reason} ->
        Context.denied("approve_confirmation", :confirmation_decide, permission_decision, reason)
    end
  end

  defp live_view_async_run_analysis?(resume_params, context) do
    channel_key(channel(context)) == "live_view" and
      !truthy?(param_value(resume_params, "force_stub")) and
      run_analysis_engine(resume_params) == "native"
  end

  defp start_run_analysis_resume_task(
         confirmation_id,
         record,
         resume_params,
         target_context,
         context
       ) do
    task = fn ->
      response = run_analysis_resume(resume_params, target_context)
      metadata = final_run_analysis_metadata(response)

      _ =
        Confirmations.annotate_resolution(
          confirmation_id,
          Map.put(metadata, :target_async?, true)
        )

      mark_run_analysis_step_finished(record, response, context)
      append_run_analysis_async_message(record, response, context, confirmation_id, metadata)
    end

    case Process.whereis(AllbertAssist.TaskSupervisor) do
      nil -> Task.start(task)
      _pid -> Task.Supervisor.start_child(AllbertAssist.TaskSupervisor, task)
    end
  end

  defp run_analysis_resume(resume_params, target_context) do
    {:ok, response} = Runner.run("run_analysis", resume_params, target_context)
    response
  end

  defp run_analysis_start_result(record, resume_params) do
    %{
      status: :running,
      ticker: param_value(resume_params, "ticker"),
      analysis_date: param_value(resume_params, "analysis_date"),
      engine: run_analysis_engine(resume_params),
      stub: truthy?(param_value(resume_params, "force_stub")),
      objective_id: objective_id(record),
      step_id: step_id(record)
    }
    |> drop_nil_values()
  end

  defp final_run_analysis_metadata(%{status: status} = response) do
    %{
      target_resumed?: true,
      target_status: status,
      target_result: run_analysis_target_result(response)
    }
  end

  defp final_run_analysis_metadata(response) when is_map(response) do
    status = Map.get(response, :status, Map.get(response, "status", :failed))

    %{
      target_resumed?: true,
      target_status: status,
      target_result: run_analysis_target_result(response)
    }
  end

  defp run_analysis_target_result(response) when is_map(response) do
    result =
      Map.get(response, :result) ||
        Map.take(response, [
          :analysis_id,
          :ticker,
          :analysis_date,
          :engine,
          :bridge_duration_ms,
          :truncated,
          :stub,
          :status,
          :summary,
          :error,
          :objective_id,
          :step_id
        ])

    ensure_target_status(result, response)
  end

  defp provider_target_result("generate_image", response) when is_map(response),
    do: image_target_result(response)

  defp provider_target_result(_action_name, response) when is_map(response),
    do: voice_target_result(response)

  defp provider_output_data("generate_image", response) when is_map(response),
    do: image_output_data(response)

  defp provider_output_data(action_name, response) when is_map(response),
    do: voice_output_data(action_name, response)

  defp voice_target_result(response) when is_map(response) do
    %{
      status: Map.get(response, :status, :unknown),
      message: Map.get(response, :message),
      error:
        response
        |> Map.get(:error)
        |> Redactor.redact(),
      output_resource_uri:
        response
        |> Map.get(:output_resource_uri)
        |> Redactor.redact_audio_resource_uri(),
      voice_metadata:
        response
        |> Map.get(:voice_metadata, %{})
        |> Redactor.redact_audio_metadata()
    }
    |> drop_nil_values()
  end

  defp image_target_result(response) when is_map(response) do
    %{
      status: Map.get(response, :status, :unknown),
      message: Map.get(response, :message),
      error:
        response
        |> Map.get(:error)
        |> Redactor.redact(),
      output_resource_uri:
        response
        |> Map.get(:output_resource_uri)
        |> Redactor.redact_image_resource_uri(),
      image_metadata:
        response
        |> Map.get(:image_metadata, %{})
        |> Redactor.redact_image_metadata()
    }
    |> drop_nil_values()
  end

  defp voice_output_data("transcribe_voice", response) when is_map(response) do
    %{
      status: Map.get(response, :status, :unknown),
      message: Map.get(response, :message),
      error:
        response
        |> Map.get(:error)
        |> Redactor.redact(),
      transcript: Map.get(response, :transcript),
      voice_metadata:
        response
        |> Map.get(:voice_metadata, %{})
        |> Redactor.redact_audio_metadata()
    }
    |> drop_nil_values()
  end

  defp voice_output_data("synthesize_voice", response) when is_map(response) do
    %{
      status: Map.get(response, :status, :unknown),
      message: Map.get(response, :message),
      error:
        response
        |> Map.get(:error)
        |> Redactor.redact(),
      audio_file: Map.get(response, :audio_file),
      output_resource_uri:
        response
        |> Map.get(:output_resource_uri)
        |> Redactor.redact_audio_resource_uri(),
      voice_metadata:
        response
        |> Map.get(:voice_metadata, %{})
        |> Redactor.redact_audio_metadata()
    }
    |> drop_nil_values()
  end

  defp voice_output_data(_action_name, _response), do: nil

  defp image_output_data(response) when is_map(response) do
    %{
      status: Map.get(response, :status, :unknown),
      message: Map.get(response, :message),
      error:
        response
        |> Map.get(:error)
        |> Redactor.redact(),
      image_file: Map.get(response, :image_file),
      output_resource_uri:
        response
        |> Map.get(:output_resource_uri)
        |> Redactor.redact_image_resource_uri(),
      image_metadata:
        response
        |> Map.get(:image_metadata, %{})
        |> Redactor.redact_image_metadata()
    }
    |> drop_nil_values()
  end

  defp ensure_target_status(result, response) do
    Map.put_new(result, :status, Map.get(response, :status, :failed))
  end

  defp put_run_analysis_approval_metadata(
         %{actions: [action | rest]} = approval,
         metadata,
         confirmation
       ) do
    updated_action =
      Map.update(action, :confirmation_metadata, metadata, fn existing ->
        Map.merge(existing, metadata)
      end)

    approval
    |> Map.put(:actions, [updated_action | rest])
    |> Map.put(:confirmation, confirmation)
  end

  defp mark_run_analysis_step_running(record, resume_params, context) do
    mark_run_analysis_step(record, :running, %{
      result_summary:
        "Approved; StockSage #{run_analysis_engine(resume_params)} analysis is running.",
      trace_id: Map.get(context, :trace_id)
    })
  end

  defp mark_run_analysis_step_finished(record, %{status: status} = response, context) do
    completed? = status == :completed or status == "completed"
    step_status = if completed?, do: :completed, else: :failed
    result = run_analysis_target_result(response)

    mark_run_analysis_step(record, step_status, %{
      result_summary: run_analysis_result_summary(result),
      trace_id: Map.get(context, :trace_id)
    })
  end

  defp mark_run_analysis_step_finished(record, response, context) do
    mark_run_analysis_step_finished(record, Map.put(response, :status, :failed), context)
  end

  defp mark_run_analysis_step(record, status, attrs) do
    with objective_id when is_binary(objective_id) and objective_id != "" <- objective_id(record),
         step_id when is_binary(step_id) and step_id != "" <- step_id(record),
         {:ok, objective} <- Objectives.get_objective(objective_id),
         false <- terminal_objective?(objective),
         step when not is_nil(step) <- find_objective_step(objective_id, step_id),
         false <- terminal_step?(step) do
      _ = Objectives.transition_step(step, status, attrs)

      _ =
        Objectives.update_objective(objective, %{
          status: objective_status_for_step(status),
          current_step_id: step.id,
          progress_summary: Map.get(attrs, :result_summary)
        })

      _ =
        Objectives.create_event(%{
          objective_id: objective.id,
          step_id: step.id,
          kind: objective_event_kind_for_step(status),
          summary: Map.get(attrs, :result_summary),
          payload: %{status: status}
        })

      :ok
    else
      _other -> :ok
    end
  end

  defp find_objective_step(objective_id, step_id) do
    objective_id
    |> Objectives.list_steps()
    |> Enum.find(&(&1.id == step_id))
  end

  defp terminal_objective?(%{status: status}),
    do: status in ["cancelled", "completed", "failed", "abandoned"]

  defp terminal_step?(%{status: status}), do: status in ["cancelled", "completed", "failed"]

  defp objective_status_for_step(:failed), do: "failed"
  defp objective_status_for_step(_status), do: "running"

  defp objective_event_kind_for_step(:running), do: "step_running"
  defp objective_event_kind_for_step(:completed), do: "step_completed"
  defp objective_event_kind_for_step(_status), do: "step_failed"

  defp run_analysis_result_summary(result) when is_map(result) do
    result
    |> then(fn result ->
      Map.get(result, :summary) ||
        Map.get(result, "summary") ||
        Map.get(result, :error) ||
        Map.get(result, "error") ||
        "StockSage analysis #{Map.get(result, :status, Map.get(result, "status", "finished"))}."
    end)
    |> stringify_summary()
  end

  defp run_analysis_engine(resume_params) do
    param_value(resume_params, "engine") || "native"
  end

  defp append_run_analysis_async_message(record, response, context, confirmation_id, metadata) do
    with user_id when is_binary(user_id) and user_id != "" <-
           run_analysis_message_user_id(record, context),
         thread_id when is_binary(thread_id) and thread_id != "" <-
           run_analysis_message_thread_id(record, response, context),
         {:ok, thread} <- Conversations.get_thread(user_id, thread_id) do
      _ =
        Conversations.append_assistant_message(
          thread,
          run_analysis_async_message(response),
          %{
            trace_id: Map.get(context, :trace_id),
            action_log: %{
              confirmation_id: confirmation_id,
              target_status: Map.get(metadata, :target_status),
              target_result: Map.get(metadata, :target_result)
            },
            metadata: %{
              source: "run_analysis_async_resume",
              confirmation_id: confirmation_id
            }
          }
        )

      :ok
    else
      _other -> :ok
    end
  end

  defp run_analysis_message_user_id(record, context) do
    resume_params = Map.get(record, "resume_params_ref", %{})

    param_value(resume_params, "user_id") ||
      get_in(record, ["origin", "user_id"]) ||
      Map.get(context, :user_id) ||
      Map.get(context, :operator_id) ||
      Map.get(context, :actor)
  end

  defp run_analysis_message_thread_id(record, response, context) do
    resume_params = Map.get(record, "resume_params_ref", %{})

    Map.get(response, :thread_id) ||
      Map.get(response, "thread_id") ||
      param_value(resume_params, "thread_id") ||
      get_in(record, ["origin", "thread_id"]) ||
      Map.get(context, :thread_id)
  end

  defp run_analysis_async_message(%{message: message}) when is_binary(message) do
    String.slice(message, 0, 1_000)
  end

  defp run_analysis_async_message(response) when is_map(response) do
    status = Map.get(response, :status, Map.get(response, "status", :failed))
    "StockSage analysis #{status}."
  end

  defp param_value(map, key) when is_map(map) and is_binary(key) do
    Map.get(map, key) || Map.get(map, String.to_atom(key))
  end

  defp truthy?(value) when value in [true, "true", "1", 1], do: true
  defp truthy?(_value), do: false

  defp stringify_summary(value) when is_binary(value), do: value
  defp stringify_summary(value), do: inspect(value, limit: 20, printable_limit: 500)

  defp drop_nil_values(map) do
    Map.reject(map, fn {_key, value} -> is_nil(value) end)
  end

  defp resolution_metadata(metadata) do
    Map.take(metadata, [
      :target_resumed?,
      :target_status,
      :target_result,
      :target_async?,
      :remembered_grants,
      :adapter_unavailable?
    ])
  end

  defp maybe_remember_grants(_record, status, _context) when status != :approved, do: {:ok, []}

  defp maybe_remember_grants(record, :approved, context) do
    params = Map.get(context, :approval_params, %{})
    GrantHandoff.remember_from_confirmation(record, params, context)
  end

  defp approval_surface_allowed(record, context) do
    with :ok <- approval_channel_allowed(context),
         :ok <- dynamic_integration_approval_allowed(record, context),
         :ok <- cross_channel_allowed(record, context) do
      :ok
    end
  end

  defp dynamic_integration_approval_allowed(record, context) do
    if target_action_name(record) in @dynamic_integration_action_names do
      with :ok <- dynamic_approval_surface_allowed(context) do
        dynamic_same_channel_allowed(record, context)
      end
    else
      :ok
    end
  end

  defp dynamic_approval_surface_allowed(context) do
    resolver_surface = dynamic_surface(context)
    allowed = allowed_dynamic_surfaces()

    if resolver_surface in allowed do
      :ok
    else
      {:error, {:dynamic_integration_approval_surface_denied, resolver_surface}}
    end
  end

  defp dynamic_same_channel_allowed(record, context) do
    origin_channel =
      record
      |> Map.get("origin", %{})
      |> Map.get("channel")
      |> channel_key()

    resolver_channel = context |> channel() |> channel_key()

    if origin_channel == resolver_channel do
      :ok
    else
      {:error, :dynamic_integration_cross_channel_approval_denied}
    end
  end

  defp allowed_dynamic_surfaces do
    case Settings.get("dynamic_codegen.integration_approval_surfaces") do
      {:ok, surfaces} when is_list(surfaces) ->
        Enum.map(surfaces, &normalize_dynamic_surface/1)

      _other ->
        ["cli", "liveview"]
    end
  end

  defp dynamic_surface(context) do
    case channel_key(channel(context)) do
      "cli" -> "cli"
      "live_view" -> "liveview"
      "liveview" -> "liveview"
      _other -> normalize_dynamic_surface(surface(context))
    end
  end

  defp normalize_dynamic_surface("live_view"), do: "liveview"
  defp normalize_dynamic_surface("liveview"), do: "liveview"
  defp normalize_dynamic_surface(:liveview), do: "liveview"
  defp normalize_dynamic_surface(:live_view), do: "liveview"
  defp normalize_dynamic_surface(:cli), do: "cli"
  defp normalize_dynamic_surface("cli"), do: "cli"
  defp normalize_dynamic_surface(value) when is_atom(value), do: Atom.to_string(value)
  defp normalize_dynamic_surface(value) when is_binary(value), do: value
  defp normalize_dynamic_surface(value), do: inspect(value)

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
      objective_id: objective_id(record),
      step_id: step_id(record),
      trace_id: Map.get(record, "source_trace_id") || Map.get(context, :trace_id),
      action_capability: Map.get(record, "capability_contract", %{}),
      active_app: target_active_app(record),
      selected_skill: selected_skill,
      skill_metadata: skill_metadata
    })
  end

  defp target_active_app(record) do
    get_in(record, ["origin", "app_id"]) ||
      get_in(record, ["resume_params_ref", "app_id"]) ||
      get_in(record, ["params_summary", "app_id"])
  end

  defp objective_id(record) do
    Map.get(record, "objective_id") ||
      get_in(record, ["resume_params_ref", "objective_id"]) ||
      get_in(record, ["params_summary", "objective_id"]) ||
      get_in(record, ["origin", "objective_id"])
  end

  defp step_id(record) do
    Map.get(record, "step_id") ||
      get_in(record, ["resume_params_ref", "step_id"]) ||
      get_in(record, ["params_summary", "step_id"]) ||
      get_in(record, ["origin", "step_id"])
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
