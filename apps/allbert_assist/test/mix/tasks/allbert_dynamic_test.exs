defmodule Mix.Tasks.Allbert.DynamicTest do
  use ExUnit.Case, async: false

  import ExUnit.CaptureIO

  alias AllbertAssist.DynamicPlugins
  alias AllbertAssist.Paths
  alias Mix.Tasks.Allbert.Dynamic, as: DynamicTask

  setup do
    original_paths_config = Application.get_env(:allbert_assist, Paths)
    home = temp_path("home")
    Application.put_env(:allbert_assist, Paths, home: home)

    on_exit(fn ->
      restore_app_env(Paths, original_paths_config)
      Mix.Task.reenable("allbert.dynamic")
      File.rm_rf!(home)
    end)

    :ok
  end

  test "draft list and show print read-only metadata" do
    assert {:ok, _draft} =
             DynamicPlugins.put_draft(%{
               slug: "task_draft",
               revision: "rev_test",
               producer: "test"
             })

    list_output = capture_io(fn -> assert :ok = DynamicTask.run(["drafts", "list"]) end)
    assert list_output =~ "task_draft"
    assert list_output =~ "tier=draft"

    show_output =
      capture_io(fn -> assert :ok = DynamicTask.run(["drafts", "show", "task_draft"]) end)

    assert show_output =~ "Slug: task_draft"
    assert show_output =~ "Revision: rev_test"
    assert show_output =~ "Tier: draft"
  end

  test "unknown subcommand raises usage" do
    assert_raise Mix.Error, ~r/mix allbert.dynamic drafts list/, fn ->
      DynamicTask.run(["wat"])
    end
  end

  defp temp_path(name) do
    Path.join(
      System.tmp_dir!(),
      "allbert-dynamic-task-#{name}-#{System.unique_integer([:positive])}"
    )
  end

  defp restore_app_env(module, nil), do: Application.delete_env(:allbert_assist, module)
  defp restore_app_env(module, value), do: Application.put_env(:allbert_assist, module, value)
end
