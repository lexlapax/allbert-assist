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
      assert usage =~ "admin models use-direct-answer"
      assert usage =~ "admin models doctor"
      # The singular `admin model list/use/doctor` forms are NOT dispatchable here and
      # must not be advertised (guards against the regression the operator hit).
      refute usage =~ "admin model list"
      refute usage =~ "admin model use"
      refute usage =~ "admin model doctor"
    end
  end

  test "catalog rendering exposes central model-role assignments without inventing mappings" do
    roles = [
      %{
        role: "fast",
        reference: "role:fast",
        settings_key: "model_roles.fast.profile",
        profile: nil,
        status: :unconfigured
      },
      %{
        role: "capable",
        reference: "role:capable",
        settings_key: "model_roles.capable.profile",
        profile: "local",
        status: :assigned
      }
    ]

    entries = [
      %{
        id: "profile:local",
        source: :configured,
        purposes: ["direct_answer"],
        assigned_roles: ["capable"],
        floor_gb: nil,
        status: :ready
      }
    ]

    {output, 0} = Area.render_catalog(roles, entries, 1)

    assert output =~ "role:fast: unconfigured key=model_roles.fast.profile"
    assert output =~ "role:capable: assigned=local key=model_roles.capable.profile"

    assert output =~
             "profile:local: source=configured purposes=direct_answer assigned_roles=capable ready"
  end
end
