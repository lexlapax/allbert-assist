defmodule AllbertAssist.Templates.ScaffoldTest do
  use ExUnit.Case, async: false

  import ExUnit.CaptureIO

  alias AllbertAssist.App.Validator, as: AppValidator
  alias AllbertAssist.Plugin.Validator, as: PluginValidator
  alias AllbertAssist.Templates
  alias AllbertAssist.Templates.Scaffold
  alias Mix.Tasks.Allbert.Gen.App, as: GenAppTask
  alias Mix.Tasks.Allbert.Gen.Plugin, as: GenPluginTask
  alias Mix.Tasks.Allbert.ValidateApp, as: ValidateAppTask

  setup do
    tmp = Path.join(System.tmp_dir!(), "allbert-templates-#{System.unique_integer([:positive])}")
    File.mkdir_p!(tmp)

    on_exit(fn ->
      File.rm_rf!(tmp)
      Mix.Task.reenable("allbert.gen.plugin")
      Mix.Task.reenable("allbert.gen.app")
      Mix.Task.reenable("allbert.validate_app")
    end)

    {:ok, tmp: tmp}
  end

  test "default registry exposes plugin and app patterns" do
    ids = Templates.list_patterns() |> Enum.map(& &1.id)

    assert "plugin" in ids
    assert "app" in ids
  end

  test "plugin scaffold defaults to ./plugins/name and renders inert manifest", %{tmp: tmp} do
    result =
      File.cd!(tmp, fn ->
        assert {:ok, result} =
                 Scaffold.write("plugin", %{
                   "name" => "Demo Plugin",
                   "description" => "A demo plugin."
                 })

        result
      end)

    assert String.ends_with?(result.target_root, "/plugins/demo_plugin")
    assert File.regular?(Path.join(result.target_root, "allbert_plugin.json"))
    assert File.regular?(Path.join(result.target_root, "lib/demo_plugin/plugin.ex"))
    refute File.exists?(Path.join(result.target_root, "mix.exs"))

    manifest =
      result.target_root
      |> Path.join("allbert_plugin.json")
      |> File.read!()
      |> Jason.decode!()

    assert {:ok, entry} =
             PluginValidator.normalize_manifest(manifest,
               source: :project,
               root_path: result.target_root
             )

    assert entry.plugin_id == "demo_plugin"
    assert entry.source == :project
    assert entry.status == :enabled
  end

  test "app scaffold validates after the generated reviewed module is compiled", %{tmp: tmp} do
    unique = System.unique_integer([:positive])
    name = "M2 Generated App #{unique}"
    target = Path.join(tmp, "m2_app")

    assert {:ok, result} =
             Scaffold.write(
               "app",
               %{
                 "name" => name,
                 "description" => "Generated app for validation."
               },
               target: target
             )

    app_module = result.params["app_module"]
    Code.compile_file(Path.join(target, "lib/#{result.params["slug"]}/app.ex"))

    assert {:ok, attrs} = AppValidator.validate(Module.concat([app_module]))
    assert attrs.app_id |> Atom.to_string() == result.params["app_id"]
    assert attrs.memory_namespace.writable == false
    assert attrs.actions == []
    assert length(attrs.provider_surfaces) == 1

    output =
      capture_io(fn ->
        assert :ok = ValidateAppTask.run([result.params["app_id"]])
      end)

    assert output =~ "Validation: ok"
    assert output =~ "app_id: #{result.params["app_id"]}"
  end

  test "existing roots are not overwritten without force", %{tmp: tmp} do
    target = Path.join(tmp, "existing")
    File.mkdir_p!(target)
    sentinel = Path.join(target, "README.md")
    File.write!(sentinel, "keep me")

    assert {:error, {:target_exists, preview}} =
             Scaffold.write("plugin", %{"name" => "Existing"}, target: target)

    assert preview.existing?
    assert Enum.any?(preview.files, &(&1.status in [:create, :overwrite]))
    assert File.read!(sentinel) == "keep me"

    assert {:ok, _result} =
             Scaffold.write("plugin", %{"name" => "Existing"}, target: target, force?: true)

    assert File.read!(sentinel) =~ "# Existing"
  end

  test "unsafe target roots are denied before writing", %{tmp: tmp} do
    File.cd!(tmp, fn ->
      assert {:error, {:unsafe_target_root, "../escape"}} =
               Scaffold.write("plugin", %{"name" => "Escape"}, target: "../escape")
    end)

    refute File.exists?(Path.expand("../escape", tmp))
  end

  test "Mix generator tasks write app and plugin scaffolds", %{tmp: tmp} do
    plugin_target = Path.join(tmp, "plugin_task")
    app_target = Path.join(tmp, "app_task")

    plugin_output =
      capture_io(fn ->
        assert :ok = GenPluginTask.run(["Task Plugin", "--target", plugin_target])
      end)

    app_output =
      capture_io(fn ->
        assert :ok = GenAppTask.run(["Task App", "--target", app_target])
      end)

    assert plugin_output =~ "Generated plugin scaffold."
    assert app_output =~ "Generated app scaffold."
    assert File.regular?(Path.join(plugin_target, "allbert_plugin.json"))
    assert File.regular?(Path.join(app_target, "lib/task_app/app.ex"))
  end
end
