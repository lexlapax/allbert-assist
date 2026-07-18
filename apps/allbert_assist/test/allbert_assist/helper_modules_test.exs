defmodule AllbertAssist.HelperModulesTest do
  use ExUnit.Case, async: true
  @moduletag :pure_async

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

  test "Maps.field_truthy falls through nil/false to the cross-type key" do
    # nil/false fall through to the other key spelling (`||` semantics)
    assert Maps.field_truthy(%{:enabled => false, "enabled" => true}, :enabled) == true
    assert Maps.field_truthy(%{:name => nil, "name" => "string"}, :name) == "string"
    assert Maps.field_truthy(%{:flag => true, "flag" => false}, "flag") == true
    # a falsy fallback value passes through as-is (matches the local
    # `Map.get(map, key) || Map.get(map, to_string(key))` copies exactly)
    assert Maps.field_truthy(%{:a => false, "a" => false}, :a, :dft) == false
    # nothing truthy and no fallback present -> default
    assert Maps.field_truthy(%{a: nil}, :a, :dft) == :dft
    assert Maps.field_truthy(%{}, :missing, "fallback") == "fallback"
    assert Maps.field_truthy(nil, :missing, "fallback") == "fallback"
    # string keys resolve the atom spelling only via existing atoms
    assert Maps.field_truthy(%{flag: true}, "flag") == true
  end

  test "Maps.field_truthy contrasts with presence-based Maps.field" do
    mixed = %{:enabled => false, "enabled" => true}

    assert Maps.field(mixed, :enabled) == false
    assert Maps.field_truthy(mixed, :enabled) == true
  end

  test "Maps.get_any returns the first present mixed-key value" do
    assert Maps.get_any(%{"id" => "string-id"}, [:missing, :id]) == "string-id"
    assert Maps.get_any(%{id: "atom-id"}, ["missing", "id"]) == "atom-id"
    assert Maps.get_any(%{}, [:missing], "fallback") == "fallback"
    assert Maps.get_any(nil, [:id], "fallback") == "fallback"
  end

  test "Maps.get_any returns present falsy values instead of the default" do
    assert Maps.get_any(%{a: false}, [:a, :b], :dft) == false
    assert Maps.get_any(%{"a" => nil}, ["a"], :dft) == nil
    assert Maps.get_any(%{a: false, b: "later"}, [:a, :b], :dft) == false
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
