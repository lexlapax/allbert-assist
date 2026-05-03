defmodule AllbertAssist.Actions.Skills.ImportOnlineSkill do
  @moduledoc """
  Disabled-by-default online skill import action boundary.
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

  alias AllbertAssist.Security.PermissionGate

  @impl true
  def run(%{source: source, id: id}, context) do
    permission_decision = PermissionGate.authorize(:online_skill_import, context)
    request = %{source: String.trim(source), id: String.trim(id)}

    {:ok,
     %{
       message: message(request, permission_decision),
       status: PermissionGate.response_status(permission_decision),
       permission_decision: permission_decision,
       online_skill_import_request: request,
       actions: [
         %{
           name: "import_online_skill",
           status: :not_executed,
           permission: :online_skill_import,
           permission_decision: permission_decision,
           execution: :not_available,
           online_skill_import_request: request
         }
       ]
     }}
  end

  defp message(request, permission_decision) do
    """
    Online skill import request recorded, not executed by M1.

    Source: #{request.source}
    Skill id: #{request.id}
    Permission gate decision: #{permission_decision.decision} for online_skill_import.

    Import remains disabled by default and must stay untrusted until an operator reviews and enables it.
    """
    |> String.trim()
  end
end
