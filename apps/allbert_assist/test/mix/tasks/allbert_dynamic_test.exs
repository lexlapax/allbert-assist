defmodule Mix.Tasks.Allbert.DynamicTest do
  use ExUnit.Case, async: false

  import ExUnit.CaptureIO

  alias AllbertAssist.DynamicPlugins
  alias AllbertAssist.DynamicPlugins.Codegen.LLM
  alias AllbertAssist.Paths
  alias AllbertAssist.Settings
  alias AllbertAssist.TestSupport.DynamicCodegenFakeProvider
  alias Mix.Tasks.Allbert.Dynamic, as: DynamicTask

  @env_vars ["ALLBERT_HOME", "ALLBERT_HOME_DIR", "ALLBERT_SETTINGS_ROOT"]

  setup do
    original_env = Map.new(@env_vars, &{&1, System.get_env(&1)})
    original_paths_config = Application.get_env(:allbert_assist, Paths)
    original_settings_config = Application.get_env(:allbert_assist, Settings)
    original_llm_config = Application.get_env(:allbert_assist, LLM)
    home = temp_path("home")

    Enum.each(@env_vars, &System.delete_env/1)
    Application.delete_env(:allbert_assist, Settings)
    Application.put_env(:allbert_assist, Paths, home: home)
    Application.put_env(:allbert_assist, LLM, provider: DynamicCodegenFakeProvider)

    on_exit(fn ->
      restore_app_env(Paths, original_paths_config)
      restore_app_env(Settings, original_settings_config)
      restore_app_env(LLM, original_llm_config)
      restore_env(original_env)
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

  test "draft request prints generated source metadata" do
    enable_dynamic_codegen!("local")

    output =
      capture_io(fn ->
        assert :ok =
                 DynamicTask.run([
                   "drafts",
                   "request",
                   "task_codegen",
                   "Need",
                   "a",
                   "read-only",
                   "diagnostic",
                   "action"
                 ])
      end)

    assert output =~ "Dynamic draft requested for task_codegen."
    assert output =~ "Draft root:"

    assert {:ok, %{slug: "task_codegen", producer: "codegen_llm"}} =
             DynamicPlugins.show_draft("task_codegen")
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

  defp enable_dynamic_codegen!(profile) do
    assert {:ok, _settings} =
             Settings.write_user_settings(%{
               "dynamic_codegen" => %{"enabled" => true, "provider_profile" => profile}
             })
  end

  defp restore_app_env(module, nil), do: Application.delete_env(:allbert_assist, module)
  defp restore_app_env(module, value), do: Application.put_env(:allbert_assist, module, value)

  defp restore_env(original_env) do
    Enum.each(original_env, fn
      {key, nil} -> System.delete_env(key)
      {key, value} -> System.put_env(key, value)
    end)
  end
end
