defmodule AllbertAssist.Actions.Skills.AuditOnlineSkill do
  @moduledoc """
  Confirmed online skill audit over fetched source metadata.
  """

  use Jido.Action,
    name: "audit_online_skill",
    description: "Audit online skill metadata before any disabled-by-default import.",
    category: "skills",
    tags: ["skills", "online", "audit", "external_network"],
    schema: [
      source: [type: :string, required: true, doc: "Configured online skill source."],
      id: [type: :string, required: true, doc: "Source-local skill identifier."]
    ],
    output_schema: [
      message: [type: :string, required: true],
      status: [type: :atom, required: true],
      permission_decision: [type: :map, required: true],
      actions: [type: {:list, :map}, required: true]
    ]

  alias AllbertAssist.Confirmations
  alias AllbertAssist.Confirmations.Origin
  alias AllbertAssist.Resources.GrantHandoff
  alias AllbertAssist.Resources.Ref
  alias AllbertAssist.Security.PermissionGate
  alias AllbertAssist.Skills.Online.Audit
  alias AllbertAssist.Skills.Online.RegistryClient
  alias AllbertAssist.Skills.Online.Source

  @impl true
  def run(params, context) when is_map(params) do
    source_id = param(params, :source)
    id = params |> param(:id) |> to_string() |> String.trim()
    permission_decision = PermissionGate.authorize(:external_network, context)

    with {:ok, source} <- Source.load(source_id, context),
         :ok <- Source.validate_enabled(source) do
      cond do
        permission_decision.decision == :denied ->
          denied_response(id, source, permission_decision, :permission_denied)

        approval_resume?(context) ->
          execute_audit(id, source, permission_decision, context)

        grant_context =
            grant_execution_context(
              request_summary(source, :online_skill_audit, %{id: id}),
              :external_network,
              context
            ) ->
          execute_audit(id, source, permission_decision, grant_context)

        true ->
          create_confirmation(id, source, context, permission_decision)
      end
    else
      {:error, reason} ->
        denied_response(id, %Source{id: to_string(source_id)}, permission_decision, reason)
    end
  end

  defp param(params, key), do: Map.get(params, key) || Map.get(params, Atom.to_string(key))

  defp execute_audit(id, source, permission_decision, context) do
    with {:ok, detail} <- RegistryClient.show(source, id) do
      audit =
        detail
        |> Audit.run()
        |> Map.put(:resource_refs, online_resource_refs(source, :online_skill_audit, %{id: id}))

      {:ok,
       %{
         message: "Online skill audit #{audit.status} for #{id}.",
         status: :completed,
         permission_decision: permission_decision,
         online_skill_audit: audit,
         result: audit,
         actions: [
           %{
             name: "audit_online_skill",
             status: :completed,
             permission: :external_network,
             requested_permission: :online_skill_import,
             permission_decision: permission_decision,
             execution: :online_skill_audit,
             online_skill_audit: audit
           }
           |> Map.put(:target_resumed?, GrantHandoff.target_resumed?(context))
           |> Map.merge(GrantHandoff.action_metadata(context))
         ]
       }}
    else
      {:error, reason} -> failed_response(id, source, permission_decision, reason, context)
    end
  end

  defp create_confirmation(id, source, context, permission_decision) do
    attrs = %{
      origin: origin(context),
      target_action: %{name: "audit_online_skill", module: inspect(__MODULE__)},
      target_permission: :external_network,
      target_execution_mode: :online_skill_audit,
      security_decision: permission_decision,
      params_summary: request_summary(source, :online_skill_audit, %{id: id}),
      resume_params_ref: %{source: source.id, id: id}
    }

    case Confirmations.create(attrs) do
      {:ok, confirmation} ->
        {:ok,
         %{
           message:
             "Online skill audit is ready for approval. Confirmation request: #{confirmation["id"]}. Nothing has fetched yet.",
           status: :needs_confirmation,
           permission_decision: permission_decision,
           confirmation: confirmation,
           confirmation_id: confirmation["id"],
           actions: [
             %{
               name: "audit_online_skill",
               status: :needs_confirmation,
               permission: :external_network,
               permission_decision: permission_decision,
               execution: :pending_confirmation,
               confirmation_id: confirmation["id"],
               online_skill: request_summary(source, :online_skill_audit, %{id: id})
             }
           ]
         }}

      {:error, reason} ->
        denied_response(id, source, permission_decision, reason)
    end
  end

  defp denied_response(id, source, permission_decision, reason) do
    result = %{
      source: Source.summary(source),
      id: id,
      resource_refs: online_resource_refs(source, :online_skill_audit, %{id: id}),
      status: :denied,
      denial_reason: reason_summary(reason)
    }

    {:ok,
     %{
       message: "Online skill audit was denied: #{inspect(reason)}.",
       status: :denied,
       permission_decision: permission_decision,
       online_skill_audit: result,
       result: result,
       actions: [
         %{
           name: "audit_online_skill",
           status: :denied,
           permission: :external_network,
           requested_permission: :online_skill_import,
           permission_decision: permission_decision,
           execution: :not_started,
           online_skill_audit: result,
           denial_reason: reason
         }
       ]
     }}
  end

  defp failed_response(id, source, permission_decision, reason, context) do
    result = %{
      source: Source.summary(source),
      id: id,
      resource_refs: online_resource_refs(source, :online_skill_audit, %{id: id}),
      status: :failed,
      failure_reason: reason_summary(reason)
    }

    {:ok,
     %{
       message: "Online skill audit failed after approval: #{inspect(reason)}.",
       status: :failed,
       permission_decision: permission_decision,
       online_skill_audit: result,
       result: result,
       actions: [
         %{
           name: "audit_online_skill",
           status: :failed,
           permission: :external_network,
           requested_permission: :online_skill_import,
           permission_decision: permission_decision,
           execution: :online_skill_audit,
           online_skill_audit: result,
           failure_reason: reason
         }
         |> Map.put(:target_resumed?, GrantHandoff.target_resumed?(context))
         |> Map.merge(GrantHandoff.action_metadata(context))
       ]
     }}
  end

  defp reason_summary({code, detail}), do: %{code: code, detail: inspect(detail)}
  defp reason_summary(reason) when is_atom(reason), do: Atom.to_string(reason)
  defp reason_summary(reason) when is_binary(reason), do: reason
  defp reason_summary(reason), do: inspect(reason)

  defp request_summary(source, operation_class, metadata) do
    source_summary = Source.summary(source)

    metadata
    |> Map.put(:source, source_summary)
    |> Map.put(:resource_refs, Ref.online_skill_source(source_summary, operation_class, metadata))
  end

  defp online_resource_refs(source, operation_class, metadata) do
    source
    |> Source.summary()
    |> Ref.online_skill_source(operation_class, metadata)
  end

  defp grant_execution_context(summary, permission, context) do
    case GrantHandoff.find_applicable(Map.get(summary, :resource_refs, []), permission, context) do
      {:ok, grants} -> GrantHandoff.put_applied(context, grants)
      _other -> nil
    end
  end

  defp origin(context) do
    Origin.from_context(context, "audit_online_skill")
  end

  defp approval_resume?(context) do
    get_in(context, [:confirmation, :approved?]) == true ||
      get_in(context, ["confirmation", "approved?"]) == true
  end
end
