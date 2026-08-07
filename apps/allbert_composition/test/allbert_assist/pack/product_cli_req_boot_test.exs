defmodule AllbertAssist.Pack.ProductCLIReqBootTest do
  use ExUnit.Case, async: false

  alias AllbertAssist.Pack.ProductCLI

  defmodule CLI do
    def entry_plan(_argv), do: %{disposition: :runtime_free}
    def run_local(_plan, _opts), do: {:stdout, "ok", 0}
  end

  test "Req startup failure does not turn a runtime-free command into composition bootstrap" do
    assert {:stdout, "ok", 0} =
             ProductCLI.run_entry_for_test(["--help"],
               cli: CLI,
               req_starter: fn :req -> {:error, {:req, :unavailable}} end,
               attach: fn _argv -> flunk("runtime-free command must not attach") end,
               bootstrap: fn _opts -> flunk("runtime-free command must not bootstrap") end
             )
  end
end
