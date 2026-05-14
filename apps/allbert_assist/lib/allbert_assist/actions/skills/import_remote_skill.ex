defmodule AllbertAssist.Actions.Skills.ImportRemoteSkill do
  @moduledoc """
  Confirmed direct HTTPS skill import action boundary.
  """

  use Jido.Action,
    name: "import_remote_skill",
    description: "Import a direct HTTPS skill URL disabled and untrusted after approval.",
    category: "skills",
    tags: ["skills", "remote", "import", "uri"],
    schema: [
      url: [type: :string, required: true, doc: "Direct HTTPS URL for SKILL.md or a files JSON."]
    ],
    output_schema: [
      message: [type: :string, required: true],
      status: [type: :atom, required: true],
      permission_decision: [type: :map, required: true],
      actions: [type: {:list, :map}, required: true]
    ]

  alias AllbertAssist.Confirmations
  alias AllbertAssist.External.RequestSpec
  alias AllbertAssist.Resources.GrantHandoff
  alias AllbertAssist.Resources.Ref
  alias AllbertAssist.Security.PermissionGate
  alias AllbertAssist.Skills.DirectImport
  alias AllbertAssist.Skills.Online.Audit
  alias AllbertAssist.Skills.Online.Importer

  @permission :online_skill_import
  @action_name "import_remote_skill"

  @impl true
  def run(params, context) when is_map(params) do
    url = params |> param(:url) |> to_string() |> String.trim()

    case RequestSpec.normalize(%{url: url, method: "GET"}, context: context) do
      {:ok, spec} -> run_spec(spec, context)
      {:error, spec} -> denied_response_from_spec(spec, context)
    end
  end

  defp run_spec(spec, context) do
    permission_decision = PermissionGate.authorize(@permission, request_context(spec, context))

    cond do
      permission_decision.decision == :denied ->
        denied_response(spec, permission_decision, :permission_denied)

      approval_resume?(context) ->
        execute_import(spec, permission_decision, context)

      grant_context = grant_execution_context(request_summary(spec), @permission, context) ->
        execute_import(spec, permission_decision, grant_context)

      true ->
        create_confirmation(spec, context, permission_decision)
    end
  end

  defp execute_import(spec, permission_decision, context) do
    with {:ok, detail} <- DirectImport.fetch_remote(spec, context),
         audit <- Audit.run(detail),
         {:ok, import} <-
           Importer.import(detail, audit, DirectImport.source_summary(:remote_url, spec.url)) do
      import =
        import
        |> Map.put(:resource_refs, resource_refs(spec))
        |> Map.put(:source_kind, :direct_url)

      {:ok,
       %{
         message: "Remote skill imported disabled and untrusted: #{import.target_root}.",
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
             execution: :direct_skill_import,
             skill_import: import
           }
           |> Map.put(:target_resumed?, GrantHandoff.target_resumed?(context))
           |> Map.merge(GrantHandoff.action_metadata(context))
         ]
       }}
    else
      {:error, reason} -> failed_response(spec, permission_decision, reason, context)
    end
  end

  defp create_confirmation(spec, context, permission_decision) do
    attrs = %{
      origin: origin(context),
      target_action: %{name: @action_name, module: inspect(__MODULE__)},
      target_permission: @permission,
      target_execution_mode: :direct_skill_import,
      security_decision: permission_decision,
      params_summary: request_summary(spec),
      resume_params_ref: %{url: spec.url}
    }

    case Confirmations.create(attrs) do
      {:ok, confirmation} ->
        {:ok,
         %{
           message:
             "Remote skill URL import is ready for approval. Confirmation request: #{confirmation["id"]}. Nothing has fetched or written yet.",
           status: :needs_confirmation,
           permission_decision: permission_decision,
           skill_import_request: request_summary(spec),
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
               skill_import: request_summary(spec)
             }
           ]
         }}

      {:error, reason} ->
        denied_response(spec, permission_decision, reason)
    end
  end

  defp denied_response_from_spec(spec, context) do
    permission_decision = PermissionGate.authorize(@permission, context)
    denied_response(spec, permission_decision, spec.denial_reason)
  end

  defp denied_response(spec, permission_decision, reason) do
    summary = request_summary(spec)

    result =
      summary
      |> Map.put(:status, :denied)
      |> Map.put(:denial_reason, reason_summary(reason))

    {:ok,
     %{
       message: "Remote skill import was denied: #{inspect(reason)}.",
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

  defp failed_response(spec, permission_decision, reason, context) do
    summary = request_summary(spec)

    result =
      summary
      |> Map.put(:status, :failed)
      |> Map.put(:failure_reason, reason_summary(reason))

    {:ok,
     %{
       message: "Remote skill import failed after approval: #{inspect(reason)}.",
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
           execution: :direct_skill_import,
           skill_import_request: result,
           failure_reason: reason
         }
         |> Map.put(:target_resumed?, GrantHandoff.target_resumed?(context))
         |> Map.merge(GrantHandoff.action_metadata(context))
       ]
     }}
  end

  defp request_summary(%RequestSpec{} = spec) do
    %{
      source: DirectImport.source_summary(:remote_url, spec.url),
      operation: :import_skill,
      url: RequestSpec.redacted_url(spec),
      canonical_url: spec.url,
      host: spec.host,
      path: spec.path,
      method: spec.method,
      max_response_bytes: spec.max_response_bytes,
      resource_refs: resource_refs(spec)
    }
  end

  defp resource_refs(%RequestSpec{} = spec) do
    Ref.remote_skill_import(spec.url, %{
      display_url: RequestSpec.redacted_url(spec),
      host: spec.host,
      path: spec.path,
      max_response_bytes: spec.max_response_bytes
    })
    |> List.wrap()
  end

  defp request_context(spec, context) do
    Map.merge(context, %{
      resource: %{
        kind: :remote_skill_import,
        url: spec.url,
        host: spec.host,
        path: spec.path,
        request: request_summary(spec)
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
