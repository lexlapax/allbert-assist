defmodule AllbertAssist.Pack.ProductCLILicensesTest do
  use ExUnit.Case, async: false

  @moduletag :global_process_serial

  alias AllbertAssist.Pack.ProductCLI

  defmodule CLI do
    def entry_plan(_argv), do: %{disposition: :license_view}
    def run_local(_plan, []), do: {:stdout, "licensed", 0}
  end

  test "license view retains the zero-runtime local path" do
    assert {:stdout, "licensed", 0} =
             ProductCLI.run_entry_for_test(["licenses", "--help"],
               cli: CLI,
               req_starter: fn :req -> flunk("license view must not start Req") end,
               attach: fn _argv -> flunk("license view must not attach") end,
               bootstrap: fn _opts -> flunk("license view must not bootstrap") end
             )
  end
end
