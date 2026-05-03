defmodule AllbertAssist.Actions.Skills.ImportOnlineSkill do
  @moduledoc """
  Confirmed disabled-by-default online skill import action boundary.
  """

  use Jido.Action,
    name: "import_online_skill",
    description:
      "Import a cached online skill only after audit, confirmation, and policy allow it.",
    category: "skills",
    tags: ["skills", "online", "import"],
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
  alias AllbertAssist.Security.PermissionGate
  alias AllbertAssist.Skills.Online.Audit
  alias AllbertAssist.Skills.Online.Importer
  alias AllbertAssist.Skills.Online.RegistryClient
  alias AllbertAssist.Skills.Online.Source

  @impl true
  def run(params, context) when is_map(params) do
    source_id = param(params, :source)
    id = params |> param(:id) |> to_string() |> String.trim()
    permission_decision = PermissionGate.authorize(:online_skill_import, context)

    with {:ok, source} <- Source.load(source_id, context),
         :ok <- Source.validate_enabled(source) do
      cond do
        permission_decision.decision == :denied ->
          denied_response(id, source, permission_decision, :permission_denied)

        approval_resume?(context) ->
          execute_import(id, source, permission_decision)

        true ->
          create_confirmation(id, source, context, permission_decision)
      end
    else
      {:error, reason} ->
        denied_response(id, %Source{id: to_string(source_id)}, permission_decision, reason)
    end
  end

  defp param(params, key), do: Map.get(params, key) || Map.get(params, Atom.to_string(key))

  defp execute_import(id, source, permission_decision) do
    with {:ok, detail} <- RegistryClient.show(source, id),
         audit <- Audit.run(detail),
         {:ok, import} <- Importer.import(detail, audit, Source.summary(source)) do
      {:ok,
       %{
         message: "Online skill imported disabled and untrusted: #{import.target_root}.",
         status: :completed,
         permission_decision: permission_decision,
         online_skill_import: import,
         result: import,
         actions: [
           %{
             name: "import_online_skill",
             status: :completed,
             permission: :online_skill_import,
             permission_decision: permission_decision,
             execution: :online_skill_import,
             target_resumed?: true,
             online_skill_import: import
           }
         ]
       }}
    else
      {:error, reason} -> denied_response(id, source, permission_decision, reason)
    end
  end

  defp create_confirmation(id, source, context, permission_decision) do
    attrs = %{
      origin: origin(context),
      target_action: %{name: "import_online_skill", module: inspect(__MODULE__)},
      target_permission: :online_skill_import,
      target_execution_mode: :online_skill_import,
      security_decision: permission_decision,
      params_summary: %{source: Source.summary(source), id: id},
      resume_params_ref: %{source: source.id, id: id}
    }

    case Confirmations.create(attrs) do
      {:ok, confirmation} ->
        {:ok,
         %{
           message:
             "Online skill import is ready for approval. Confirmation request: #{confirmation["id"]}. Nothing has fetched or written yet.",
           status: :needs_confirmation,
           permission_decision: permission_decision,
           online_skill_import_request: %{source: Source.summary(source), id: id},
           confirmation: confirmation,
           confirmation_id: confirmation["id"],
           actions: [
             %{
               name: "import_online_skill",
               status: :needs_confirmation,
               permission: :online_skill_import,
               permission_decision: permission_decision,
               execution: :pending_confirmation,
               confirmation_id: confirmation["id"],
               online_skill: %{source: Source.summary(source), id: id}
             }
           ]
         }}

      {:error, reason} ->
        denied_response(id, source, permission_decision, reason)
    end
  end

  defp denied_response(id, source, permission_decision, reason) do
    {:ok,
     %{
       message: "Online skill import was denied: #{inspect(reason)}.",
       status: :denied,
       permission_decision: permission_decision,
       online_skill_import_request: %{
         source: Source.summary(source),
         id: id,
         denial_reason: reason
       },
       actions: [
         %{
           name: "import_online_skill",
           status: :denied,
           permission: :online_skill_import,
           permission_decision: permission_decision,
           execution: :not_started,
           denial_reason: reason
         }
       ]
     }}
  end

  defp origin(context) do
    request = Map.get(context, :request, %{})

    %{
      actor: Map.get(request, :operator_id, Map.get(context, :actor, "local")),
      channel: Map.get(request, :channel, Map.get(context, :channel, :unknown)),
      surface: Map.get(context, :surface, "import_online_skill"),
      session_id: Map.get(request, :session_id, Map.get(context, :session_id)),
      response_target: Map.get(context, :response_target)
    }
  end

  defp approval_resume?(context) do
    get_in(context, [:confirmation, :approved?]) == true ||
      get_in(context, ["confirmation", "approved?"]) == true
  end
end
