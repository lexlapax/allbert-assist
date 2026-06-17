defmodule Mix.Tasks.Allbert.IntentTest do
  use ExUnit.Case, async: false
  @moduletag :app_env_serial

  import ExUnit.CaptureIO

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

    promote_output =
      capture_io(fn ->
        assert :ok = IntentTask.run(["promote", "show_app", "--from", "learned"])
      end)

    assert promote_output =~ "promoted show_app ->"
    assert promote_output =~ "/intents/generated/allbert/show_app.yaml"

    list_output = capture_io(fn -> assert :ok = IntentTask.run(["list"]) end)
    assert list_output =~ "show_app source=generated app_id=allbert"
  end
end
