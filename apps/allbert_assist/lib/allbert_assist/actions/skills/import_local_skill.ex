defmodule AllbertAssist.Actions.Skills.ImportLocalSkill do
  @moduledoc """
  Confirmed local directory skill import action boundary.
  """

  use Jido.Action,
    name: "import_local_skill",
    description: "Import a local skill directory disabled and untrusted after approval.",
    category: "skills",
    tags: ["skills", "local", "import", "uri"],
    schema: [
      path: [type: :string, required: true, doc: "Local directory containing SKILL.md."]
    ],
    output_schema: [
      message: [type: :string, required: true],
      status: [type: :atom, required: true],
      permission_decision: [type: :map, required: true],
      actions: [type: {:list, :map}, required: true]
    ]

  alias AllbertAssist.Confirmations
  alias AllbertAssist.Resources.GrantHandoff
  alias AllbertAssist.Resources.Ref
  alias AllbertAssist.Security.PermissionGate
  alias AllbertAssist.Skills.DirectImport
  alias AllbertAssist.Skills.Online.Audit
  alias AllbertAssist.Skills.Online.Importer

  @permission :skill_write
  @action_name "import_local_skill"

  @impl true
  def run(params, context) when is_map(params) do
    path = params |> param(:path) |> to_string() |> String.trim()
    permission_decision = PermissionGate.authorize(@permission, request_context(path, context))
    summary = request_summary(path)

    cond do
      path == "" ->
        denied_response(path, permission_decision, :missing_path)

      permission_decision.decision == :denied ->
        denied_response(path, permission_decision, :permission_denied)

      approval_resume?(context) ->
        execute_import(path, permission_decision, context)

      grant_context = grant_execution_context(summary, @permission, context) ->
        execute_import(path, permission_decision, grant_context)

      true ->
        create_confirmation(path, context, permission_decision)
    end
  end

  defp execute_import(path, permission_decision, context) do
    with {:ok, detail} <- DirectImport.collect_local(path),
         audit <- Audit.run(detail),
         {:ok, import} <-
           Importer.import(
             detail,
             audit,
             DirectImport.source_summary(:local_directory, detail.source_url)
           ) do
      import =
        import
        |> Map.put(:resource_refs, resource_refs(path))
        |> Map.put(:source_kind, :local_directory)

      {:ok,
       %{
         message: "Local skill imported disabled and untrusted: #{import.target_root}.",
         status: :completed,
         permission_decision: permission_decision,
         skill_import: import,
         result: import,
         actions: [
           %{
             name: @action_name,
             status: :completed,
             permission: @permission,
             permission_decision: permission_decision,
             execution: :local_skill_import,
             skill_import: import
           }
           |> Map.put(:target_resumed?, GrantHandoff.target_resumed?(context))
           |> Map.merge(GrantHandoff.action_metadata(context))
         ]
       }}
    else
      {:error, reason} -> failed_response(path, permission_decision, reason, context)
    end
  end

  defp create_confirmation(path, context, permission_decision) do
    attrs = %{
      origin: origin(context),
      target_action: %{name: @action_name, module: inspect(__MODULE__)},
      target_permission: @permission,
      target_execution_mode: :local_skill_import,
      security_decision: permission_decision,
      params_summary: request_summary(path),
      resume_params_ref: %{path: path}
    }

    case Confirmations.create(attrs) do
      {:ok, confirmation} ->
        {:ok,
         %{
           message:
             "Local skill directory import is ready for approval. Confirmation request: #{confirmation["id"]}. Nothing has read or written yet.",
           status: :needs_confirmation,
           permission_decision: permission_decision,
           skill_import_request: request_summary(path),
           confirmation: confirmation,
           confirmation_id: confirmation["id"],
           actions: [
             %{
               name: @action_name,
               status: :needs_confirmation,
               permission: @permission,
               permission_decision: permission_decision,
               execution: :pending_confirmation,
               confirmation_id: confirmation["id"],
               skill_import: request_summary(path)
             }
           ]
         }}

      {:error, reason} ->
        denied_response(path, permission_decision, reason)
    end
  end

  defp denied_response(path, permission_decision, reason) do
    result =
      path
      |> request_summary()
      |> Map.put(:status, :denied)
      |> Map.put(:denial_reason, reason_summary(reason))

    {:ok,
     %{
       message: "Local skill import was denied: #{inspect(reason)}.",
       status: :denied,
       permission_decision: permission_decision,
       skill_import_request: result,
       result: result,
       actions: [
         %{
           name: @action_name,
           status: :denied,
           permission: @permission,
           permission_decision: permission_decision,
           execution: :not_started,
           skill_import_request: result,
           denial_reason: reason
         }
       ]
     }}
  end

  defp failed_response(path, permission_decision, reason, context) do
    result =
      path
      |> request_summary()
      |> Map.put(:status, :failed)
      |> Map.put(:failure_reason, reason_summary(reason))

    {:ok,
     %{
       message: "Local skill import failed after approval: #{inspect(reason)}.",
       status: :failed,
       permission_decision: permission_decision,
       skill_import_request: result,
       result: result,
       actions: [
         %{
           name: @action_name,
           status: :failed,
           permission: @permission,
           permission_decision: permission_decision,
           execution: :local_skill_import,
           skill_import_request: result,
           failure_reason: reason
         }
         |> Map.put(:target_resumed?, GrantHandoff.target_resumed?(context))
         |> Map.merge(GrantHandoff.action_metadata(context))
       ]
     }}
  end

  defp request_summary(path) do
    %{
      source: DirectImport.source_summary(:local_directory, local_resource_uri(path)),
      operation: :import_local_skill,
      path: Path.expand(to_string(path)),
      resource_uri: local_resource_uri(path),
      resource_refs: resource_refs(path)
    }
  end

  defp resource_refs(path), do: [Ref.local_skill_import(path)]

  defp local_resource_uri(path) do
    path
    |> Ref.local_skill_import()
    |> Map.fetch!(:resource_uri)
  end

  defp request_context(path, context) do
    Map.merge(context, %{
      resource: %{
        kind: :local_skill_import,
        path: Path.expand(to_string(path)),
        resource_uri: local_resource_uri(path),
        request: request_summary(path)
      }
    })
  end

  defp grant_execution_context(summary, permission, context) do
    case GrantHandoff.find_applicable(Map.get(summary, :resource_refs, []), permission, context) do
      {:ok, grants} -> GrantHandoff.put_applied(context, grants)
      _other -> nil
    end
  end

  defp origin(context) do
    AllbertAssist.Confirmations.Origin.from_context(context, @action_name)
  end

  defp approval_resume?(context) do
    get_in(context, [:confirmation, :approved?]) == true ||
      get_in(context, ["confirmation", "approved?"]) == true
  end

  defp param(params, key), do: Map.get(params, key) || Map.get(params, Atom.to_string(key))

  defp reason_summary({code, detail}), do: %{code: code, detail: inspect(detail)}
  defp reason_summary(reason) when is_atom(reason), do: Atom.to_string(reason)
  defp reason_summary(reason) when is_binary(reason), do: reason
  defp reason_summary(reason), do: inspect(reason)
end
