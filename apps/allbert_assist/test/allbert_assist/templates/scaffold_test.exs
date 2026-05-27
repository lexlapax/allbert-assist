defmodule AllbertAssist.Templates.ScaffoldTest do
  use ExUnit.Case, async: false

  import ExUnit.CaptureIO

  alias AllbertAssist.App.Validator, as: AppValidator
  alias AllbertAssist.DynamicPlugins.Draft
  alias AllbertAssist.DynamicPlugins.TrustedValidator
  alias AllbertAssist.Paths
  alias AllbertAssist.Plugin.Validator, as: PluginValidator
  alias AllbertAssist.Settings
  alias AllbertAssist.Templates
  alias AllbertAssist.Templates.Scaffold
  alias Mix.Tasks.Allbert.Gen.App, as: GenAppTask
  alias Mix.Tasks.Allbert.Gen.Flow, as: GenFlowTask
  alias Mix.Tasks.Allbert.Gen.Plugin, as: GenPluginTask
  alias Mix.Tasks.Allbert.Gen.Tool, as: GenToolTask
  alias Mix.Tasks.Allbert.ValidateApp, as: ValidateAppTask

  setup do
    tmp = Path.join(System.tmp_dir!(), "allbert-templates-#{System.unique_integer([:positive])}")
    File.mkdir_p!(tmp)
    original_paths_config = Application.get_env(:allbert_assist, Paths)
    original_settings_config = Application.get_env(:allbert_assist, Settings)

    Application.put_env(:allbert_assist, Paths, home: Path.join(tmp, "home"))
    Application.delete_env(:allbert_assist, Settings)

    on_exit(fn ->
      restore_env(Paths, original_paths_config)
      restore_env(Settings, original_settings_config)
      File.rm_rf!(tmp)
      Mix.Task.reenable("allbert.gen.plugin")
      Mix.Task.reenable("allbert.gen.app")
      Mix.Task.reenable("allbert.gen.tool")
      Mix.Task.reenable("allbert.gen.flow")
      Mix.Task.reenable("allbert.validate_app")
    end)

    {:ok, tmp: tmp}
  end

  test "default registry exposes plugin and app patterns" do
    ids = Templates.list_patterns() |> Enum.map(& &1.id)

    assert "plugin" in ids
    assert "app" in ids
    assert "llm_tool" in ids
    assert "flow" in ids
    assert "objective" in ids
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

  test "LLM-tool scaffold is action-shaped and read-only variants need no delegate", %{tmp: tmp} do
    unique = System.unique_integer([:positive])
    target = Path.join(tmp, "tool_read_only")

    assert {:ok, result} =
             Scaffold.write(
               "llm_tool",
               %{"name" => "Read Tool #{unique}", "permission" => "read_only"},
               target: target
             )

    assert result.live_integration?
    assert result.target_shapes == ["action"]

    source = File.read!(Path.join(target, "source/lib/action.ex"))
    assert source =~ "permission: :read_only"
    refute source =~ "DynamicPlugins.Delegate.run"

    assert [{module, _binary}] = Code.compile_file(Path.join(target, "source/lib/action.ex"))
    assert module.name() == result.params["action_name"]

    assert {:ok, validation} = validate_dynamic_action(result, target)
    assert [%{permission: "read_only", exposure: "internal"}] = validation.actions
  end

  test "LLM-tool delegated variants route through reviewed facades", %{tmp: tmp} do
    allow_permissions!(["read_only", "memory_write", "external_network"])
    allow_facades!(["append_memory", "external_network_request"])

    cases = [
      {"memory_write", "append_memory"},
      {"external_network", "external_network_request"}
    ]

    for {permission, facade} <- cases do
      unique = System.unique_integer([:positive])
      target = Path.join(tmp, "tool_#{permission}_#{unique}")

      assert {:ok, result} =
               Scaffold.write(
                 "llm_tool",
                 %{"name" => "#{permission} Tool #{unique}", "permission" => permission},
                 target: target
               )

      source = File.read!(Path.join(target, "source/lib/action.ex"))
      assert source =~ ~s(AllbertAssist.DynamicPlugins.Delegate.run("#{facade}")
      assert source =~ "permission: :#{permission}"

      assert {:ok, validation} = validate_dynamic_action(result, target)
      assert [%{permission: ^permission}] = validation.actions
    end
  end

  test "flow and objective scaffolds remain inert developer blueprints", %{tmp: tmp} do
    flow_target = Path.join(tmp, "morning_flow")

    assert {:ok, flow} =
             Scaffold.write(
               "flow",
               %{
                 "name" => "Morning Flow",
                 "schedule" => "daily",
                 "at" => "09:30",
                 "objective" => "Prepare a morning review."
               },
               target: flow_target
             )

    refute flow.live_integration?
    assert flow.target_shapes == ["job_blueprint", "objective_wiring"]

    job =
      flow_target
      |> Path.join("priv/jobs/morning_flow.json")
      |> File.read!()
      |> Jason.decode!()

    assert job["enabled"] == false
    assert job["schedule"] == %{"kind" => "daily", "at" => "09:30"}

    assert [{flow_module, _binary}] =
             Code.compile_file(Path.join(flow_target, "lib/morning_flow/flow.ex"))

    assert flow_module.job_blueprint().enabled? == false

    objective_target = Path.join(tmp, "objective_flow")

    assert {:ok, objective} =
             Scaffold.write(
               "objective",
               %{
                 "name" => "Objective Flow",
                 "objective" => "Complete a bounded workflow.",
                 "steps" => "Frame|Collect|Confirm"
               },
               target: objective_target
             )

    refute objective.live_integration?
    assert objective.target_shapes == ["objective_workflow", "objective_steps"]

    workflow =
      objective_target
      |> Path.join("priv/objectives/objective_flow.json")
      |> File.read!()
      |> Jason.decode!()

    assert workflow["enabled"] == false
    assert workflow["steps"] == ["Frame", "Collect", "Confirm"]

    assert [{objective_module, _binary}] =
             Code.compile_file(Path.join(objective_target, "lib/objective_flow/objective.ex"))

    assert objective_module.workflow_blueprint().enabled? == false
  end

  test "Mix generator tasks write tool, flow, and objective scaffolds", %{tmp: tmp} do
    tool_target = Path.join(tmp, "tool_task")
    flow_target = Path.join(tmp, "flow_task")
    objective_target = Path.join(tmp, "objective_task")

    tool_output =
      capture_io(fn ->
        assert :ok = GenToolTask.run(["Task Tool", "--target", tool_target])
      end)

    flow_output =
      capture_io(fn ->
        assert :ok = GenFlowTask.run(["Task Flow", "--target", flow_target])
      end)

    objective_output =
      capture_io(fn ->
        assert :ok =
                 GenFlowTask.run([
                   "Task Objective",
                   "--pattern",
                   "objective",
                   "--target",
                   objective_target
                 ])
      end)

    assert tool_output =~ "Generated llm_tool scaffold."
    assert flow_output =~ "Generated flow scaffold."
    assert objective_output =~ "Generated objective scaffold."
    assert File.regular?(Path.join(tool_target, "source/lib/action.ex"))
    assert File.regular?(Path.join(flow_target, "priv/jobs/task_flow.json"))
    assert File.regular?(Path.join(objective_target, "priv/objectives/task_objective.json"))
  end

  defp validate_dynamic_action(result, root) do
    manifest =
      root
      |> Path.join("dynamic_manifest.json")
      |> File.read!()
      |> Jason.decode!()

    assert {:ok, draft} =
             Draft.new(%{
               "slug" => result.params["slug"],
               "revision" => "rev_test",
               "tier" => "gate_passed",
               "producer" => "template_pattern",
               "target_shapes" => ["action"],
               "root" => root,
               "gate" => %{"status" => "passed", "sandbox_report_id" => "fixture-report"}
             })

    TrustedValidator.validate(draft, manifest, root: root)
  end

  defp allow_permissions!(permissions) do
    assert {:ok, _setting} =
             Settings.put("dynamic_codegen.allowed_action_permissions", permissions, %{
               audit?: false
             })
  end

  defp allow_facades!(facades) do
    assert {:ok, _setting} =
             Settings.put("dynamic_codegen.allowed_facades", facades, %{audit?: false})
  end

  defp restore_env(module, nil), do: Application.delete_env(:allbert_assist, module)
  defp restore_env(module, config), do: Application.put_env(:allbert_assist, module, config)
end
