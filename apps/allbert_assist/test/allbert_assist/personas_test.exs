defmodule AllbertAssist.PersonasTest do
  @moduledoc """
  v0.63 M4 — the persona catalog loads, validates against the live safe-write keys,
  and rejects structural problems. Seed-only: every settings_seed key must be a
  `@safe_write_key`, and only the 8 envelope fields are allowed.
  """
  use ExUnit.Case, async: true

  alias AllbertAssist.Personas
  alias AllbertAssist.Settings

  @expected_ids ~w(general researcher developer writer ops)

  test "ships all five personas in catalog (selection) order" do
    assert Personas.ids() == @expected_ids
    assert Enum.map(Personas.all(), & &1["persona_id"]) == @expected_ids
  end

  test "the whole catalog validates at boot" do
    assert Personas.validate!() == :ok
  end

  test "every persona is the 8-field envelope with a label" do
    for persona <- Personas.all() do
      assert is_binary(persona["label"]) and persona["label"] != ""
      assert is_map(persona["settings_seeds"])
      assert is_list(persona["first_chat_prompts"])
      assert Enum.all?(persona["first_chat_prompts"], &is_binary/1)
    end
  end

  test "every settings_seed key across all personas is a live safe-write key" do
    for persona <- Personas.all(), {key, _value} <- Personas.settings_seeds(persona) do
      assert Settings.safe_write_key?(key),
             "#{persona["persona_id"]} seeds non-safe-write key #{key}"
    end
  end

  test "the pinned developer seed values match the plan contract" do
    dev = Personas.get("developer")
    seeds = Map.new(Personas.settings_seeds(dev))

    assert seeds["coding.default_approval_mode"] == "plan"
    assert seeds["coding.model_profile"] == "pi_coding_local"
    assert seeds["coding.read.default_limit"] == 4000

    assert seeds["model_preferences.tasks.coding"] ==
             ["pi_coding_local", "coding_local", "coding", "capable", "local"]
  end

  describe "validate/2 rejects bad personas" do
    test "an unknown envelope key" do
      bad = %{"persona_id" => "x", "label" => "X", "settings_seeds" => %{}, "bogus" => 1}
      assert {:error, {:unknown_envelope_keys, ["bogus"]}} = Personas.validate("x", bad)
    end

    test "a settings_seed that is not a safe-write key" do
      bad = %{
        "persona_id" => "x",
        "label" => "X",
        "settings_seeds" => %{"security.master_floor" => "off"}
      }

      assert {:error, {:non_safe_write_keys, ["security.master_floor"]}} =
               Personas.validate("x", bad)
    end

    test "an id that disagrees with the filename" do
      bad = %{"persona_id" => "other", "label" => "X", "settings_seeds" => %{}}
      assert {:error, {:id_mismatch, "x", "other"}} = Personas.validate("x", bad)
    end

    test "a missing label" do
      bad = %{"persona_id" => "x", "settings_seeds" => %{}}
      assert {:error, :missing_label} = Personas.validate("x", bad)
    end

    test "M7.1: a schema-invalid seed VALUE (bad enum) is rejected at boot validation" do
      bad = %{
        "persona_id" => "x",
        "label" => "X",
        "settings_seeds" => %{"operator.communication_style" => "not_an_enum_value"}
      }

      assert {:error, {:invalid_seed_value, "operator.communication_style", _reason}} =
               Personas.validate("x", bad)
    end
  end
end
