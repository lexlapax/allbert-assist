defmodule StockSage.SupervisorTest do
  use ExUnit.Case, async: false

  test "starts TraderBridge as a one_for_one child" do
    # The application boots the plugin's Supervisor at startup, so the bridge
    # process should already be registered under the StockSage.TraderBridge
    # name.
    assert is_pid(Process.whereis(StockSage.TraderBridge))
  end

  test "child spec returns the Supervisor module tuple" do
    assert StockSage.Plugin.child_spec([]) == {StockSage.Supervisor, []}
  end
end
