defmodule Mix.Tasks.Allbert.IntentTest do
  use ExUnit.Case, async: false
  @moduletag :app_env_serial

  import ExUnit.CaptureIO

  alias AllbertAssist.Actions.Runner
  alias AllbertAssist.Intent.Router.DescriptorStore
  alias AllbertAssist.Paths
  alias Mix.Tasks.Allbert.Intent, as: IntentTask

  setup do
    original_home = System.get_env("ALLBERT_HOME")
    original_home_dir = System.get_env("ALLBERT_HOME_DIR")
    original_paths = Application.get_env(:allbert_assist, Paths)

    home =
      Path.join(System.tmp_dir!(), "allbert-intent-task-#{System.unique_integer([:positive])}")

    System.put_env("ALLBERT_HOME", home)
    System.delete_env("ALLBERT_HOME_DIR")
    Application.delete_env(:allbert_assist, Paths)

    on_exit(fn ->
      if original_home,
        do: System.put_env("ALLBERT_HOME", original_home),
        else: System.delete_env("ALLBERT_HOME")

      if original_home_dir,
        do: System.put_env("ALLBERT_HOME_DIR", original_home_dir),
        else: System.delete_env("ALLBERT_HOME_DIR")

      if original_paths,
        do: Application.put_env(:allbert_assist, Paths, original_paths),
        else: Application.delete_env(:allbert_assist, Paths)

      Mix.Task.reenable("allbert.intent")
      File.rm_rf!(home)
    end)

    {:ok, home: home}
  end

  test "help documents mutation and maintenance subcommands" do
    assert {:docs_v1, _, _, _, %{"en" => moduledoc}, _, _} = Code.fetch_docs(IntentTask)

    assert moduledoc =~ "mix allbert.intent disable ACTION"
    assert moduledoc =~ "mix allbert.intent promote ACTION [--from TIER] [--to TIER]"
    assert moduledoc =~ "mix allbert.intent optimize [--heuristic]"
    assert moduledoc =~ "mix allbert.intent reindex"
  end

  test "edit materializes an override YAML descriptor and list reports override source" do
    output = capture_io(fn -> assert :ok = IntentTask.run(["edit", "append_memory"]) end)
    assert output =~ "override append_memory ->"

    assert {:ok, path} = DescriptorStore.path(:overrides, :allbert, "append_memory")
    assert File.exists?(path)

    yaml = File.read!(path)
    assert yaml =~ "action_name: append_memory"
    assert yaml =~ "disabled: false"
    refute String.ends_with?(path, ".exs")

    list_output = capture_io(fn -> assert :ok = IntentTask.run(["list"]) end)
    assert list_output =~ "append_memory source=override app_id=allbert"
  end

  test "disable is gate-backed and enable removes a reviewed disable override" do
    disable_output =
      capture_io(fn -> assert :ok = IntentTask.run(["disable", "append_memory"]) end)

    assert disable_output =~ "could not disable append_memory: gate failed"

    {:ok, _path} =
      DescriptorStore.put(:overrides, %{
        app_id: :allbert,
        action_name: "append_memory",
        disabled: true
      })

    disabled_list = capture_io(fn -> assert :ok = IntentTask.run(["list"]) end)
    refute disabled_list =~ "append_memory source="

    enable_output = capture_io(fn -> assert :ok = IntentTask.run(["enable", "append_memory"]) end)
    assert enable_output =~ "enabled append_memory"

    restored_list = capture_io(fn -> assert :ok = IntentTask.run(["list"]) end)
    assert restored_list =~ "append_memory source=code app_id=allbert"
  end

  test "read commands render the registered action DTO messages" do
    assert_cli_matches_action(["list"], "intent_list_descriptors", operator_report_params())

    assert_cli_matches_action(["show", "append_memory"], "intent_show_descriptor", %{
      action: "append_memory"
    })

    assert_cli_matches_action(["coverage"], "intent_coverage", operator_report_params())
  end

  test "eval run can render the deterministic by-surface report" do
    output = capture_io(fn -> assert :ok = IntentTask.run(["eval", "run", "--by-surface"]) end)

    assert output =~ "intent eval run total="
    assert output =~ "surface runs:"
    assert output =~ "web: total="
    assert output =~ "tui: total="
    assert output =~ "telegram: total="
  end

  test "eval capture and add are thin views over registered actions", %{home: home} do
    fixture_root =
      Path.join(
        File.cwd!(),
        "tmp/allbert-intent-task-fixture-#{System.unique_integer([:positive])}"
      )

    on_exit(fn -> File.rm_rf!(fixture_root) end)

    capture_output =
      capture_io(fn ->
        assert :ok =
                 IntentTask.run([
                   "eval",
                   "capture",
                   "trace-123",
                   "--id",
                   "task-capture-001",
                   "--domain",
                   "captured",
                   "--surface",
                   "tui",
                   "--utterance",
                   "operator saw a routing miss",
                   "--kind",
                   "none",
                   "--rationale",
                   "operator reviewed"
                 ])
      end)

    assert capture_output =~ "captured intent eval case task-capture-001 ->"

    captured_path =
      Path.join([home, "intents", "eval", "captured", "task-capture-001.yaml"])

    assert File.exists?(captured_path)

    add_output =
      capture_io(fn ->
        assert :ok =
                 IntentTask.run([
                   "eval",
                   "add",
                   "task-capture-001",
                   "--fixture-root",
                   fixture_root
                 ])
      end)

    assert add_output =~ "added intent eval case task-capture-001 ->"
    assert File.exists?(Path.join([fixture_root, "captured", "task-capture-001.yaml"]))
  end

  test "review lists learned proposals and promote makes them generated" do
    {:ok, _path} =
      DescriptorStore.put(:review, %{
        app_id: :allbert,
        action_name: "show_app",
        label: "Show app",
        examples: ["show app"],
        synonyms: ["app details"],
        required_slots: []
      })

    review_output = capture_io(fn -> assert :ok = IntentTask.run(["review"]) end)
    assert review_output =~ "show_app app_id=allbert"

    assert clean_output(review_output) ==
             action_message("intent_list_review", operator_report_params())

    promote_output =
      capture_io(fn ->
        assert :ok = IntentTask.run(["promote", "show_app", "--from", "learned"])
      end)

    assert promote_output =~ "promoted show_app ->"
    assert promote_output =~ "/intents/generated/allbert/show_app.yaml"

    list_output = capture_io(fn -> assert :ok = IntentTask.run(["list"]) end)
    assert list_output =~ "show_app source=generated app_id=allbert"
  end

  test "promote rejects a descriptor that fails the routing gate without mutating files" do
    {:ok, review_path} =
      DescriptorStore.put(:review, %{
        app_id: :allbert,
        action_name: "list_channels",
        label: "List channels",
        examples: ["list my channels"],
        synonyms: ["channels"],
        required_slots: [:channel]
      })

    output = capture_io(fn -> assert :ok = IntentTask.run(["promote", "list_channels"]) end)

    assert output =~ "could not promote list_channels: gate failed"
    assert File.exists?(review_path)

    assert {:ok, generated_path} = DescriptorStore.path(:generated, :allbert, "list_channels")
    refute File.exists?(generated_path)
  end

  defp assert_cli_matches_action(args, action, params) do
    output = capture_io(fn -> assert :ok = IntentTask.run(args) end)
    assert clean_output(output) == action_message(action, params)
  end

  defp action_message(action, params) do
    {:ok, response} = Runner.run(action, params, operator_context())
    response.message
  end

  defp operator_report_params do
    %{render_mode: "operator_report", surface_policy_affordance: true}
  end

  defp operator_context do
    %{
      actor: "local",
      operator_id: "local",
      channel: :mix,
      request: %{operator_id: "local", channel: :mix, source: "mix allbert.intent"}
    }
  end

  defp clean_output(output), do: String.trim_trailing(output)
end
