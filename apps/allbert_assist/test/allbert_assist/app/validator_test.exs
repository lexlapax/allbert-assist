defmodule AllbertAssist.App.ValidatorTest do
  use ExUnit.Case, async: true

  alias AllbertAssist.Actions.Multiply
  alias AllbertAssist.App.Validator

  defmodule ValidAppCase do
    defmacro __using__(_opts) do
      quote do
        use AllbertAssist.App

        @impl true
        def validate(_opts), do: :ok

        defoverridable validate: 1
      end
    end
  end

  defmodule ValidApp do
    use AllbertAssist.App.ValidatorTest.ValidAppCase

    @impl true
    def app_id, do: :validator_valid_app

    @impl true
    def display_name, do: "Validator Valid App"

    @impl true
    def version, do: "0.15.0"
  end

  defmodule DigitAppIdApp do
    use AllbertAssist.App.ValidatorTest.ValidAppCase

    @impl true
    def app_id, do: :"1bad"

    @impl true
    def display_name, do: "Digit App Id"

    @impl true
    def version, do: "0.15.0"
  end

  defmodule UppercaseAppIdApp do
    use AllbertAssist.App.ValidatorTest.ValidAppCase

    @impl true
    def app_id, do: :BadApp

    @impl true
    def display_name, do: "Uppercase App Id"

    @impl true
    def version, do: "0.15.0"
  end

  defmodule NilAppIdApp do
    use AllbertAssist.App.ValidatorTest.ValidAppCase

    @impl true
    def app_id, do: nil

    @impl true
    def display_name, do: "Nil App Id"

    @impl true
    def version, do: "0.15.0"
  end

  defmodule NoneAppIdApp do
    use AllbertAssist.App.ValidatorTest.ValidAppCase

    @impl true
    def app_id, do: :none

    @impl true
    def display_name, do: "None App Id"

    @impl true
    def version, do: "0.15.0"
  end

  defmodule ReservedAllbertApp do
    use AllbertAssist.App.ValidatorTest.ValidAppCase

    @impl true
    def app_id, do: :allbert

    @impl true
    def display_name, do: "Reserved Allbert"

    @impl true
    def version, do: "0.15.0"
  end

  defmodule ReservedStockSageApp do
    use AllbertAssist.App.ValidatorTest.ValidAppCase

    @impl true
    def app_id, do: :stocksage

    @impl true
    def display_name, do: "Reserved StockSage"

    @impl true
    def version, do: "0.15.0"
  end

  defmodule BlankDisplayNameApp do
    use AllbertAssist.App.ValidatorTest.ValidAppCase

    @impl true
    def app_id, do: :blank_display_name_app

    @impl true
    def display_name, do: " "

    @impl true
    def version, do: "0.15.0"
  end

  defmodule LongDisplayNameApp do
    use AllbertAssist.App.ValidatorTest.ValidAppCase

    @impl true
    def app_id, do: :long_display_name_app

    @impl true
    def display_name, do: String.duplicate("a", 65)

    @impl true
    def version, do: "0.15.0"
  end

  defmodule BlankVersionApp do
    use AllbertAssist.App.ValidatorTest.ValidAppCase

    @impl true
    def app_id, do: :blank_version_app

    @impl true
    def display_name, do: "Blank Version"

    @impl true
    def version, do: " "
  end

  defmodule LongVersionApp do
    use AllbertAssist.App.ValidatorTest.ValidAppCase

    @impl true
    def app_id, do: :long_version_app

    @impl true
    def display_name, do: "Long Version"

    @impl true
    def version, do: String.duplicate("1", 33)
  end

  defmodule UnknownActionApp do
    use AllbertAssist.App.ValidatorTest.ValidAppCase

    @impl true
    def app_id, do: :unknown_action_validator_app

    @impl true
    def display_name, do: "Unknown Action"

    @impl true
    def version, do: "0.15.0"

    @impl true
    def actions, do: [Multiply]
  end

  defmodule RelativeSkillPathApp do
    use AllbertAssist.App.ValidatorTest.ValidAppCase

    @impl true
    def app_id, do: :relative_skill_path_app

    @impl true
    def display_name, do: "Relative Skill Path"

    @impl true
    def version, do: "0.15.0"

    @impl true
    def skill_paths, do: ["relative/skills"]
  end

  defmodule NonStringSkillPathApp do
    use AllbertAssist.App.ValidatorTest.ValidAppCase

    @impl true
    def app_id, do: :non_string_skill_path_app

    @impl true
    def display_name, do: "Non String Skill Path"

    @impl true
    def version, do: "0.15.0"

    @impl true
    def skill_paths, do: [123]
  end

  defmodule SurfaceMissingIdApp do
    use AllbertAssist.App.ValidatorTest.ValidAppCase

    @impl true
    def app_id, do: :surface_missing_id_app

    @impl true
    def display_name, do: "Surface Missing Id"

    @impl true
    def version, do: "0.15.0"

    @impl true
    def surfaces, do: [%{label: "Missing", path: "/missing", app_id: :surface_missing_id_app}]
  end

  defmodule SurfaceBadPathApp do
    use AllbertAssist.App.ValidatorTest.ValidAppCase

    @impl true
    def app_id, do: :surface_bad_path_app

    @impl true
    def display_name, do: "Surface Bad Path"

    @impl true
    def version, do: "0.15.0"

    @impl true
    def surfaces,
      do: [%{id: :home, label: "Bad Path", path: "bad-path", app_id: :surface_bad_path_app}]
  end

  defmodule SurfaceAppMismatchApp do
    use AllbertAssist.App.ValidatorTest.ValidAppCase

    @impl true
    def app_id, do: :surface_app_mismatch_app

    @impl true
    def display_name, do: "Surface App Mismatch"

    @impl true
    def version, do: "0.15.0"

    @impl true
    def surfaces,
      do: [%{id: :home, label: "Mismatch", path: "/mismatch", app_id: :other_app}]
  end

  defmodule SurfaceOversizedOptionalApp do
    use AllbertAssist.App.ValidatorTest.ValidAppCase

    @impl true
    def app_id, do: :surface_oversized_optional_app

    @impl true
    def display_name, do: "Surface Oversized Optional"

    @impl true
    def version, do: "0.15.0"

    @impl true
    def surfaces do
      [
        %{
          id: :home,
          label: "Oversized",
          path: "/oversized",
          app_id: :surface_oversized_optional_app,
          icon: String.duplicate("i", 65)
        }
      ]
    end
  end

  defmodule SurfaceDuplicateIdApp do
    use AllbertAssist.App.ValidatorTest.ValidAppCase

    @impl true
    def app_id, do: :surface_duplicate_id_app

    @impl true
    def display_name, do: "Surface Duplicate Id"

    @impl true
    def version, do: "0.15.0"

    @impl true
    def surfaces do
      [
        %{id: :home, label: "One", path: "/one", app_id: :surface_duplicate_id_app},
        %{id: :home, label: "Two", path: "/two", app_id: :surface_duplicate_id_app}
      ]
    end
  end

  test "accepts valid app modules and built-in reserved-id owners" do
    assert {:ok, %{app_id: :validator_valid_app}} = Validator.validate(ValidApp, [])
    assert {:ok, %{app_id: :allbert}} = Validator.validate(AllbertAssist.App.CoreApp, [])
    assert {:ok, %{app_id: :stocksage}} = Validator.validate(AllbertAssist.App.StockSageStub, [])
  end

  test "rejects invalid and reserved app ids" do
    assert_error(DigitAppIdApp, {:invalid_app_id, :"1bad"})
    assert_error(UppercaseAppIdApp, {:invalid_app_id, :BadApp})
    assert_error(NilAppIdApp, {:reserved_app_id, nil})
    assert_error(NoneAppIdApp, {:reserved_app_id, :none})
    assert_error(ReservedAllbertApp, {:reserved_app_id, :allbert})
    assert_error(ReservedStockSageApp, {:reserved_app_id, :stocksage})
  end

  test "rejects blank or oversized metadata strings" do
    assert_error(BlankDisplayNameApp, {:invalid_metadata, :display_name})
    assert_error(LongDisplayNameApp, {:invalid_metadata, :display_name})
    assert_error(BlankVersionApp, {:invalid_metadata, :version})
    assert_error(LongVersionApp, {:invalid_metadata, :version})
  end

  test "rejects unknown action modules and invalid skill paths" do
    assert_error(UnknownActionApp, {:unknown_action_module, Multiply})
    assert_error(RelativeSkillPathApp, {:invalid_skill_path, "relative/skills"})
    assert_error(NonStringSkillPathApp, {:invalid_skill_path, 123})
  end

  test "rejects malformed surface declarations" do
    assert_error(SurfaceMissingIdApp, {:invalid_surface, :id})
    assert_error(SurfaceBadPathApp, {:invalid_surface, :path})
    assert_error(SurfaceAppMismatchApp, {:invalid_surface, :app_id})
    assert_error(SurfaceOversizedOptionalApp, {:invalid_surface, :icon})
    assert_error(SurfaceDuplicateIdApp, {:invalid_surface, :duplicate_id})
  end

  defp assert_error(module, reason) do
    assert {:error, ^reason, [%{kind: kind}]} = Validator.validate(module, [])
    assert kind == elem(reason, 0)
  end
end
