defmodule StockSage.Actions.Agents.ShowAgent do
  @moduledoc false

  use AllbertAssist.Action,
    permission: :read_only,
    exposure: :internal,
    execution_mode: :read_only,
    skill_backed?: false,
    confirmation: :not_required,
    app_id: :stocksage,
    plugin_id: "stocksage",
    name: "show_stocksage_agent",
    description: "Show one StockSage native specialist agent.",
    category: "stocksage",
    tags: ["stocksage", "agents", "read_only"],
    schema: [
      agent_id: [type: :string, required: true],
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
  def run(params, context) do
    permission_decision = Actions.authorize(:read_only, context)
    agent_id = Actions.field(params, :agent_id) || Actions.field(params, :id)

    cond do
      not Actions.allowed?(permission_decision) ->
        denied(permission_decision)

      not is_binary(agent_id) or String.trim(agent_id) == "" ->
        not_found(agent_id, permission_decision)

      true ->
        show(String.trim(agent_id), permission_decision)
    end
  end

  defp show(agent_id, permission_decision) do
    with {:ok, spec} <- Agents.spec(agent_id) do
      registry_entry =
        case AgentRegistry.lookup(spec.id) do
          {:ok, entry} -> entry
          {:error, :not_found} -> nil
        end

      {:ok,
       %{
         message: "StockSage native agent #{spec.id}.",
         status: :completed,
         agent: %{
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
         },
         actions: [
           Actions.action("show_stocksage_agent", :completed, :read_only, permission_decision, %{
             agent_id: spec.id
           })
         ]
       }}
    else
      {:error, :not_found} -> not_found(agent_id, permission_decision)
    end
  end

  defp denied(permission_decision) do
    status = Actions.status_from_decision(permission_decision)

    {:ok,
     %{
       message: "StockSage native agent detail is not available to this request.",
       status: status,
       error: :permission_denied,
       actions: [
         Actions.action("show_stocksage_agent", status, :read_only, permission_decision)
       ]
     }}
  end

  defp not_found(agent_id, permission_decision) do
    {:ok,
     %{
       message: "StockSage native agent not found: #{inspect(agent_id)}",
       status: :not_found,
       error: :not_found,
       actions: [
         Actions.action("show_stocksage_agent", :not_found, :read_only, permission_decision, %{
           error: :not_found
         })
       ]
     }}
  end

  defp registry_metadata(nil), do: %{}
  defp registry_metadata(%{metadata: metadata}) when is_map(metadata), do: metadata

  defp model_profile(%{role: :quality_gate}), do: nil
  defp model_profile(spec), do: Agents.ModelProfile.resolve(spec.role)
end
