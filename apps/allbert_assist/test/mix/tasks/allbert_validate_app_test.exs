defmodule Mix.Tasks.Allbert.ValidateAppTest do
  use ExUnit.Case, async: false

  import ExUnit.CaptureIO

  alias AllbertAssist.Surface
  alias AllbertAssist.Surface.Node
  alias Mix.Tasks.Allbert.ValidateApp, as: ValidateAppTask

  defmodule DuplicateSurfaceApp do
    use AllbertAssist.App
    use AllbertAssist.App.SurfaceProvider

    def app_id, do: :validate_app_duplicate_surface
    def display_name, do: "Validate App Duplicate Surface"
    def version, do: "0.18.0"
    def validate(_opts), do: :ok

    def surfaces do
      [
        %Surface{
          id: :home,
          app_id: :validate_app_duplicate_surface,
          label: "Home",
          path: "/duplicate-one",
          kind: :route,
          status: :available,
          nodes: [%Node{id: "one", component: :route}],
          fallback_text: "Home."
        },
        %Surface{
          id: :home,
          app_id: :validate_app_duplicate_surface,
          label: "Home Again",
          path: "/duplicate-two",
          kind: :route,
          status: :available,
          nodes: [%Node{id: "two", component: :route}],
          fallback_text: "Home again."
        }
      ]
    end

    def surface_catalog, do: [%{component: :route, allowed_props: [], allowed_bindings: []}]
  end

  setup do
    on_exit(fn ->
      Mix.Task.reenable("allbert.validate_app")
    end)
  end

  test "prints v0.18 contract summary for CoreApp without raw provider data" do
    output =
      capture_io(fn ->
        assert :ok = ValidateAppTask.run(["AllbertAssist.App.CoreApp"])
      end)

    assert output =~ "Validation: ok"
    assert output =~ "app_id: allbert"
    assert output =~ "provider_surfaces: :workspace:/workspace"
    refute output =~ "chat-root"
    refute output =~ "bot_token"
    refute output =~ "password"
  end

  test "non-app module raises with validation diagnostics" do
    assert_raise Mix.Error, ~r/App validation failed: {:invalid_module, String}/, fn ->
      capture_io(fn ->
        ValidateAppTask.run(["Elixir.String"])
      end)
    end
  end

  test "same-app duplicate surface ids are visible through validation output" do
    output =
      capture_io(fn ->
        assert_raise Mix.Error, ~r/invalid_surface_provider/, fn ->
          ValidateAppTask.run(["Mix.Tasks.Allbert.ValidateAppTest.DuplicateSurfaceApp"])
        end
      end)

    assert output =~ "Validation: error"
    assert output =~ "invalid_surface_provider"
    assert output =~ "duplicate_id"
  end

  test "unknown module does not create atoms" do
    unknown = "AllbertAssist.App.Unknown#{System.unique_integer([:positive])}"
    atom_name = "Elixir." <> unknown

    assert_raise Mix.Error, ~r/unknown_module/, fn ->
      capture_io(fn ->
        ValidateAppTask.run([unknown])
      end)
    end

    assert_raise ArgumentError, fn ->
      String.to_existing_atom(atom_name)
    end
  end

  test "usage errors raise through Mix task surface" do
    assert_raise Mix.Error, ~r/Usage: mix allbert.validate_app MODULE/, fn ->
      ValidateAppTask.run([])
    end
  end
end
