defmodule AllbertAssist.Actions.Skills.SearchOnlineSkills do
  @moduledoc """
  Online skill search action boundary.

  M1 registers the capability without performing network access. M4 routes this
  through the confirmed external service adapter.
  """

  use Jido.Action,
    name: "search_online_skills",
    description: "Search a configured online skill source after confirmation.",
    category: "skills",
    tags: ["skills", "online", "external_network"],
    schema: [
      query: [type: :string, required: true, doc: "Search query."],
      source: [type: :string, required: false, doc: "Configured online skill source."]
    ],
    output_schema: [
      message: [type: :string, required: true],
      status: [type: :atom, required: true],
      permission_decision: [type: :map, required: true],
      actions: [type: {:list, :map}, required: true]
    ]

  alias AllbertAssist.Security.PermissionGate

  @impl true
  def run(%{query: query} = params, context) do
    permission_decision = PermissionGate.authorize(:external_network, context)
    query = String.trim(query)
    source = Map.get(params, :source, "skills_sh")

    {:ok,
     %{
       message: message(query, source, permission_decision),
       status: PermissionGate.response_status(permission_decision),
       permission_decision: permission_decision,
       actions: [
         %{
           name: "search_online_skills",
           status: :not_executed,
           permission: :external_network,
           permission_decision: permission_decision,
           execution: :not_available,
           input: %{query: query, source: source}
         }
       ]
     }}
  end

  defp message(query, source, permission_decision) do
    """
    Online skill search is registered, not executed by M1.

    Query: #{query}
    Source: #{source}
    Permission gate decision: #{permission_decision.decision} for external_network.

    M4 will execute this through the confirmed external service adapter and cache results disabled-by-default.
    """
    |> String.trim()
  end
end
