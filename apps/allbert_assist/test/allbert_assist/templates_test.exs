defmodule AllbertAssist.TemplatesTest do
  use ExUnit.Case, async: true

  alias AllbertAssist.Templates
  alias AllbertAssist.Templates.Parameters
  alias AllbertAssist.Templates.Renderer

  defmodule FixturePattern do
    @behaviour AllbertAssist.Templates.Pattern

    @impl true
    def id, do: "fixture"

    @impl true
    def label, do: "Fixture"

    @impl true
    def description, do: "Fixture pattern for registry and renderer tests."

    @impl true
    def parameter_schema do
      [
        %{name: "name", type: :string, required: true, min_length: 1, max_length: 64},
        %{name: "description", type: :string, default: "Generated fixture.", max_length: 120},
        %{name: "mode", type: :enum, default: "read_only", allowed_values: ["read_only", "write"]}
      ]
    end

    @impl true
    def files do
      [
        %{
          target: "{{slug}}/README.md",
          content: "# {{display_name}}\n\n{{description}}\nmode={{mode}}\n"
        },
        %{
          target: "{{slug}}/lib/{{module_basename}}.ex",
          content:
            "defmodule {{module_namespace}} do\n  @moduledoc {{description_literal}}\nend\n"
        }
      ]
    end

    @impl true
    def target_shapes, do: ["fixture"]

    @impl true
    def live_integration?, do: false
  end

  test "registry lists and resolves reviewed pattern modules" do
    opts = [patterns: [FixturePattern, String]]

    assert [
             %{
               id: "fixture",
               label: "Fixture",
               live_integration?: false,
               target_shapes: ["fixture"]
             }
           ] = Templates.list_patterns(opts)

    assert {:ok, FixturePattern} = Templates.resolve_pattern("fixture", opts)

    assert {:error, {:unknown_template_pattern, "missing"}} =
             Templates.resolve_pattern("missing", opts)
  end

  test "validates params and derives safe common identifiers" do
    assert {:ok, params} =
             FixturePattern.parameter_schema()
             |> Parameters.validate(%{"name" => "Morning Brief", "mode" => "read_only"})
             |> then(fn {:ok, params} -> Parameters.derive_common(params) end)

    assert params["slug"] == "morning_brief"
    assert params["app_id"] == "morning_brief"
    assert params["module_basename"] == "MorningBrief"
    assert params["module_namespace"] == "MorningBrief"
    assert params["display_name"] == "Morning Brief"
  end

  test "rejects invalid params before rendering" do
    opts = [patterns: [FixturePattern]]

    assert {:error, {:missing_required_parameter, "name"}} =
             Templates.render("fixture", %{"mode" => "read_only"}, opts)

    assert {:error, {:invalid_enum_parameter, "mode", "shell", ["read_only", "write"]}} =
             Templates.render("fixture", %{"name" => "safe", "mode" => "shell"}, opts)
  end

  test "renders deterministically without writing files" do
    opts = [patterns: [FixturePattern]]
    params = %{"name" => "Morning Brief", "description" => "Summarize the day."}

    assert {:ok, first} = Templates.render("fixture", params, opts)
    assert {:ok, second} = Templates.render("fixture", params, opts)

    assert first == second

    assert [
             %{path: "morning_brief/README.md", content: readme},
             %{path: "morning_brief/lib/MorningBrief.ex", content: module_source}
           ] = first.files

    assert readme =~ "# Morning Brief"
    assert module_source =~ "defmodule MorningBrief do"
    assert module_source =~ ~s(@moduledoc "Summarize the day.")
  end

  test "denies unsafe rendered output paths" do
    assert Renderer.safe_relative_path?("safe/lib/file.ex")
    refute Renderer.safe_relative_path?("../escape.ex")
    refute Renderer.safe_relative_path?("/tmp/escape.ex")
  end
end
