defmodule AllbertAssist.Actions.Skills.ShowOnlineSkill do
  @moduledoc """
  Online skill detail action boundary.
  """

  use Jido.Action,
    name: "show_online_skill",
    description: "Fetch or display details for a configured online skill source result.",
    category: "skills",
    tags: ["skills", "online", "external_network"],
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
    permission_decision = PermissionGate.authorize(:external_network, context)

    {:ok,
     %{
       message: message(source, id, permission_decision),
       status: PermissionGate.response_status(permission_decision),
       permission_decision: permission_decision,
       actions: [
         %{
           name: "show_online_skill",
           status: :not_executed,
           permission: :external_network,
           permission_decision: permission_decision,
           execution: :not_available,
           input: %{source: String.trim(source), id: String.trim(id)}
         }
       ]
     }}
  end

  defp message(source, id, permission_decision) do
    """
    Online skill detail is registered, not executed by M1.

    Source: #{source}
    Skill id: #{id}
    Permission gate decision: #{permission_decision.decision} for external_network.
    """
    |> String.trim()
  end
end
