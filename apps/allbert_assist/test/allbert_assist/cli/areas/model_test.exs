defmodule AllbertAssist.CLI.Areas.ModelTest do
  use ExUnit.Case, async: true
  @moduletag :pure_async

  alias AllbertAssist.CLI.Areas.Model, as: Area

  describe "M8.6: usage/help names dispatchable command forms" do
    test "help/unknown subcommand prints plural `admin models …`, never singular" do
      # `admin models help` (and any unknown subcommand) falls through to the usage route.
      assert {usage, _code} = Area.dispatch(["help"])
      assert usage =~ "admin models list"
      assert usage =~ "admin models use"
      assert usage =~ "admin models doctor"
      # The singular `admin model list/use/doctor` forms are NOT dispatchable here and
      # must not be advertised (guards against the regression the operator hit).
      refute usage =~ "admin model list"
      refute usage =~ "admin model use"
      refute usage =~ "admin model doctor"
    end
  end
end
