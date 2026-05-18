defmodule StockSage.Actions.AgentsTest do
  use ExUnit.Case, async: false

  alias AllbertAssist.Actions.Runner
  alias AllbertAssist.Plugin.Registry, as: PluginRegistry
  alias AllbertAssist.Security.PermissionGate

  setup do
    PluginRegistry.register_module(StockSage.Plugin)
    :ok
  end

  test "list_stocksage_agents returns all specialist agents with registry status" do
    assert {:ok, response} =
             Runner.run("list_stocksage_agents", %{}, %{
               request: %{
                 channel: :test,
                 user_id: "alice",
                 operator_id: "alice",
                 app_id: :stocksage
               }
             })

    assert response.status == :completed
    assert length(response.agents) == 12
    assert Enum.any?(response.agents, &(&1.id == "stocksage.market_context"))
    assert Enum.any?(response.agents, &(&1.id == "stocksage.research_manager"))
    assert Enum.any?(response.agents, &(&1.id == "stocksage.trader_plan"))
    assert Enum.all?(response.agents, &(&1.prompt_version == "v0.25.0"))
    assert Enum.all?(response.agents, &(&1.status == :running))
  end

  test "show_stocksage_agent returns details and unknown ids are not found" do
    assert {:ok, response} =
             Runner.run("show_stocksage_agent", %{agent_id: "stocksage.quality_gate"}, %{
               request: %{
                 channel: :test,
                 user_id: "alice",
                 operator_id: "alice",
                 app_id: :stocksage
               }
             })

    assert response.status == :completed
    assert response.agent.role == :quality_gate
    assert response.agent.model_profile == nil
    assert response.agent.prompt_path =~ "quality_gate.md"

    assert {:ok, missing} =
             Runner.run("show_stocksage_agent", %{agent_id: "stocksage.nope"}, %{
               request: %{
                 channel: :test,
                 user_id: "alice",
                 operator_id: "alice",
                 app_id: :stocksage
               }
             })

    assert missing.status == :not_found
  end

  test "stocksage_evidence_fetch permission requires confirmation except approved parent analysis" do
    outside = PermissionGate.authorize(:stocksage_evidence_fetch, %{channel: :test})
    assert outside.decision == :needs_confirmation

    inside =
      PermissionGate.authorize(:stocksage_evidence_fetch, %{
        parent: %{permission: :stocksage_analyze, approved?: true},
        channel: :test
      })

    assert inside.decision == :allowed
  end
end
