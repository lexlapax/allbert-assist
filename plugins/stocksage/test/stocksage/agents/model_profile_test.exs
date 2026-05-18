defmodule StockSage.Agents.ModelProfileTest do
  use ExUnit.Case, async: false

  alias AllbertAssist.Plugin.Registry, as: PluginRegistry
  alias AllbertAssist.Settings
  alias StockSage.Agents.ModelProfile

  setup do
    original = Application.get_env(:allbert_assist, Settings)

    root =
      Path.join(
        System.tmp_dir!(),
        "stocksage-model-profile-#{System.unique_integer([:positive])}"
      )

    Application.put_env(:allbert_assist, Settings, root: Path.join(root, "settings"))
    PluginRegistry.register_module(StockSage.Plugin)

    on_exit(fn ->
      if original do
        Application.put_env(:allbert_assist, Settings, original)
      else
        Application.delete_env(:allbert_assist, Settings)
      end

      File.rm_rf!(root)
    end)

    :ok
  end

  test "returns per-agent override when present" do
    assert {:ok, _setting} =
             Settings.put("stocksage.native_model_profile_market_context", "deep-fast", %{
               audit?: false
             })

    assert ModelProfile.resolve(:market_context) == "deep-fast"
  end

  test "falls back to role default before global default" do
    assert {:ok, _setting} =
             Settings.put("stocksage.native_model_profile", "global-fast", %{audit?: false})

    assert ModelProfile.resolve(:risk_aggressive) == "slow"
    assert ModelProfile.resolve(:research_manager) == "slow"
    assert ModelProfile.resolve(:trader_plan) == "slow"
    assert ModelProfile.resolve(:market_context) == "fast"
  end

  test "quality gate has no model profile" do
    assert ModelProfile.resolve(:quality_gate) == "fast"
  end
end
