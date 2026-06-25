defmodule AllbertAssist.HelperModulesTest do
  use ExUnit.Case, async: true

  alias AllbertAssist.Maps
  alias AllbertAssist.Serialization
  alias AllbertAssist.Settings.Helpers, as: SettingsHelpers
  alias AllbertAssist.Validation

  test "Maps.field reads atom or string keys without creating atoms" do
    assert Maps.field(%{name: "atom"}, :name) == "atom"
    assert Maps.field(%{"name" => "string"}, :name) == "string"
    assert Maps.field(%{name: "atom"}, "name") == "atom"
    assert Maps.field(%{"name" => "string"}, "name") == "string"
    assert Maps.field(%{}, :missing, "fallback") == "fallback"
    assert Maps.field(nil, :missing, "fallback") == "fallback"
  end

  test "Maps.get_any returns the first present mixed-key value" do
    assert Maps.get_any(%{"id" => "string-id"}, [:missing, :id]) == "string-id"
    assert Maps.get_any(%{id: "atom-id"}, ["missing", "id"]) == "atom-id"
    assert Maps.get_any(%{}, [:missing], "fallback") == "fallback"
    assert Maps.get_any(nil, [:id], "fallback") == "fallback"
  end

  test "Serialization.stringify_keys recursively stringifies keys" do
    assert Serialization.stringify_keys(%{a: %{b: 1}, list: [%{c: :kept}]}) == %{
             "a" => %{"b" => 1},
             "list" => [%{"c" => :kept}]
           }

    assert Serialization.stringify_keys(%{status: :ok}, atom_values?: true) == %{
             "status" => "ok"
           }
  end

  test "Validation.clamp_limit keeps only positive in-range integers" do
    assert Validation.clamp_limit(5, 10, 100) == 5
    assert Validation.clamp_limit(500, 10, 100) == 100
    assert Validation.clamp_limit(0, 10, 100) == 10
    assert Validation.clamp_limit("5", 10, 100) == 10
  end

  test "Settings.Helpers.setting_bool reads boolean setting DTO rows" do
    rows = [%{key: "workspace.accessibility.reduce_motion", value: true}]

    assert SettingsHelpers.setting_bool(rows, "workspace.accessibility.reduce_motion", false)
    refute SettingsHelpers.setting_bool(rows, "missing", false)
    assert SettingsHelpers.setting_bool(%{}, "missing", true)
  end
end
