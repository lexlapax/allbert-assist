defmodule StockSage.SupervisorTest do
  use ExUnit.Case, async: false

  test "starts TraderBridge as a one_for_one child" do
    # The application boots the plugin's Supervisor at startup, so the bridge
    # process should already be registered under the StockSage.TraderBridge
    # name.
    assert is_pid(Process.whereis(StockSage.TraderBridge))
  end

  test "child spec returns the Supervisor's child_spec map" do
    # v0.22 pre-existing dialyzer cleanup: Plugin.child_spec/1 now returns
    # the supervisor's full child_spec map (delegating to
    # `StockSage.Supervisor.child_spec/1`) to satisfy the
    # `AllbertAssist.Plugin` `@callback child_spec/1` typespec, which
    # expects a Supervisor.child_spec map (not the `{module, args}`
    # shorthand). The supervisor still boots the same way at runtime.
    spec = StockSage.Plugin.child_spec([])
    assert is_map(spec)
    assert spec.id == StockSage.Supervisor
    assert {StockSage.Supervisor, :start_link, [_opts]} = spec.start
    assert spec.type == :supervisor
  end
end
