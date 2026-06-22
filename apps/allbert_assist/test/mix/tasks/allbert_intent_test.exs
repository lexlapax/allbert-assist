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

  test "enable removes a disable override and restores the resolved descriptor" do
    disable_output =
      capture_io(fn -> assert :ok = IntentTask.run(["disable", "append_memory"]) end)

    assert disable_output =~ "disabled append_memory"

    disabled_list = capture_io(fn -> assert :ok = IntentTask.run(["list"]) end)
    refute disabled_list =~ "append_memory source="

    enable_output = capture_io(fn -> assert :ok = IntentTask.run(["enable", "append_memory"]) end)
    assert enable_output =~ "enabled append_memory"

    restored_list = capture_io(fn -> assert :ok = IntentTask.run(["list"]) end)
    assert restored_list =~ "append_memory source=code app_id=allbert"
  end

  test "read commands render the registered action DTO messages" do
    assert_cli_matches_action(["list"], "intent_list_descriptors", %{})

    assert_cli_matches_action(["show", "append_memory"], "intent_show_descriptor", %{
      action: "append_memory"
    })

    assert_cli_matches_action(["coverage"], "intent_coverage", %{})
  end

  test "eval run can render the deterministic by-surface report" do
    output = capture_io(fn -> assert :ok = IntentTask.run(["eval", "run", "--by-surface"]) end)

    assert output =~ "intent eval run total="
    assert output =~ "surface runs:"
    assert output =~ "web: total="
    assert output =~ "tui: total="
    assert output =~ "telegram: total="
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
    assert clean_output(review_output) == action_message("intent_list_review", %{})

    promote_output =
      capture_io(fn ->
        assert :ok = IntentTask.run(["promote", "show_app", "--from", "learned"])
      end)

    assert promote_output =~ "promoted show_app ->"
    assert promote_output =~ "/intents/generated/allbert/show_app.yaml"

    list_output = capture_io(fn -> assert :ok = IntentTask.run(["list"]) end)
    assert list_output =~ "show_app source=generated app_id=allbert"
  end

  defp assert_cli_matches_action(args, action, params) do
    output = capture_io(fn -> assert :ok = IntentTask.run(args) end)
    assert clean_output(output) == action_message(action, params)
  end

  defp action_message(action, params) do
    {:ok, response} = Runner.run(action, params, operator_context())
    response.message
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
