defmodule AllbertAssist.Actions.DynamicPluginsTest do
  use ExUnit.Case, async: false

  alias AllbertAssist.Actions.Registry
  alias AllbertAssist.Actions.Runner
  alias AllbertAssist.DynamicPlugins
  alias AllbertAssist.Paths

  setup do
    original_paths_config = Application.get_env(:allbert_assist, Paths)
    home = temp_path("home")
    Application.put_env(:allbert_assist, Paths, home: home)

    on_exit(fn ->
      restore_app_env(Paths, original_paths_config)
      File.rm_rf!(home)
    end)

    :ok
  end

  test "registry exposes read-only dynamic metadata actions" do
    assert {:ok, AllbertAssist.Actions.DynamicPlugins.ListDynamicDrafts} =
             Registry.resolve("list_dynamic_drafts")

    assert {:ok, capability} = Registry.capability("show_dynamic_draft")
    assert capability.permission == :read_only
    assert capability.exposure == :internal
  end

  test "list and show dynamic drafts through the runner" do
    assert {:ok, _draft} =
             DynamicPlugins.put_draft(%{
               slug: "runner_draft",
               revision: "rev_test",
               producer: "test"
             })

    assert {:ok, %{status: :completed, drafts: [draft]}} =
             Runner.run("list_dynamic_drafts", %{}, context())

    assert draft.slug == "runner_draft"

    assert {:ok, %{status: :completed, draft: shown}} =
             Runner.run("show_dynamic_draft", %{slug: "runner_draft"}, context())

    assert shown.revision == "rev_test"
  end

  test "show missing dynamic draft fails closed" do
    assert {:ok, %{status: :denied, error: {:metadata_not_found, _path}}} =
             Runner.run("show_dynamic_draft", %{slug: "missing"}, context())
  end

  defp context, do: %{actor: "local", channel: :cli}

  defp temp_path(name) do
    Path.join(
      System.tmp_dir!(),
      "allbert-dynamic-actions-#{name}-#{System.unique_integer([:positive])}"
    )
  end

  defp restore_app_env(module, nil), do: Application.delete_env(:allbert_assist, module)
  defp restore_app_env(module, value), do: Application.put_env(:allbert_assist, module, value)
end
