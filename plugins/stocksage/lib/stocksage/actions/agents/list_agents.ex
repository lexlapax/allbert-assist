defmodule StockSage.Actions.Agents.ListAgents do
  @moduledoc false

  use Jido.Action,
    name: "list_stocksage_agents",
    description: "List registered StockSage native specialist agents.",
    category: "stocksage",
    tags: ["stocksage", "agents", "read_only"],
    schema: [
      user_id: [type: :string, required: false]
    ],
    output_schema: [
      message: [type: :string, required: true],
      status: [type: :atom, required: true],
      actions: [type: {:list, :map}, required: true]
    ]

  alias AllbertAssist.Objectives.AgentRegistry
  alias StockSage.{Actions, Agents}

  def capability do
    Actions.capability(:read_only, %{
      exposure: :internal,
      execution_mode: :read_only,
      skill_backed?: false
    })
  end

  @impl true
  def run(_params, context) do
    permission_decision = Actions.authorize(:read_only, context)

    if Actions.allowed?(permission_decision) do
      agents = Enum.map(Agents.specialists(), &agent_summary/1)

      {:ok,
       %{
         message: "Found #{length(agents)} StockSage native agents.",
         status: :completed,
         agents: agents,
         actions: [
           Actions.action("list_stocksage_agents", :completed, :read_only, permission_decision, %{
             returned: length(agents)
           })
         ]
       }}
    else
      status = Actions.status_from_decision(permission_decision)

      {:ok,
       %{
         message: "StockSage native agent listing is not available to this request.",
         status: status,
         error: :permission_denied,
         actions: [
           Actions.action("list_stocksage_agents", status, :read_only, permission_decision)
         ]
       }}
    end
  end

  defp agent_summary(spec) do
    registry_entry =
      case AgentRegistry.lookup(spec.id) do
        {:ok, entry} -> entry
        {:error, :not_found} -> nil
      end

    %{
      id: spec.id,
      role: spec.role,
      module: spec.module,
      type: spec.type,
      status: if(registry_entry, do: :running, else: :not_registered),
      prompt_version: spec.prompt_version,
      prompt_path: Agents.prompt_path(spec),
      model_profile: model_profile(spec),
      tools: spec.tool_names,
      registry_metadata: registry_metadata(registry_entry)
    }
  end

  defp registry_metadata(nil), do: %{}
  defp registry_metadata(%{metadata: metadata}) when is_map(metadata), do: metadata

  defp model_profile(%{role: :quality_gate}), do: nil
  defp model_profile(spec), do: Agents.ModelProfile.resolve(spec.role)
end
