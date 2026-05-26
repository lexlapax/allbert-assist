defmodule AllbertAssist.Actions.DynamicPluginsTest do
  use ExUnit.Case, async: false

  alias AllbertAssist.Actions.Registry
  alias AllbertAssist.Actions.Runner
  alias AllbertAssist.DynamicPlugins
  alias AllbertAssist.DynamicPlugins.Codegen.LLM
  alias AllbertAssist.Paths
  alias AllbertAssist.Settings
  alias AllbertAssist.TestSupport.DynamicCodegenFakeProvider

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

  test "discard dynamic draft through the runner tombstones non-live draft" do
    assert {:ok, _draft} =
             DynamicPlugins.put_draft(%{
               slug: "runner_discard",
               revision: "rev_test",
               producer: "test"
             })

    assert {:ok, %{status: :completed, draft: discarded}} =
             Runner.run("discard_dynamic_draft", %{slug: "runner_discard"}, context())

    assert discarded.tier == "discarded"

    assert {:ok, %{status: :completed, draft: discarded_again}} =
             Runner.run("discard_dynamic_draft", %{slug: "runner_discard"}, context())

    assert discarded_again.tier == "discarded"
  end

  test "discard dynamic draft requires rollback before integrated draft" do
    assert {:ok, _draft} =
             DynamicPlugins.put_draft(%{
               slug: "runner_discard_live",
               revision: "rev_test",
               tier: "integrated",
               producer: "test"
             })

    assert {:ok, %{status: :denied, error: :rollback_required}} =
             Runner.run("discard_dynamic_draft", %{slug: "runner_discard_live"}, context())
  end

  test "show missing dynamic draft fails closed" do
    assert {:ok, %{status: :denied, error: {:metadata_not_found, _path}}} =
             Runner.run("show_dynamic_draft", %{slug: "missing"}, context())
  end

  test "request dynamic draft through the runner creates generated source metadata" do
    enable_dynamic_codegen!("local")

    assert {:ok,
            %{
              status: :completed,
              draft: draft,
              budget: budget,
              permission_decision: permission_decision
            }} =
             Runner.run(
               "request_dynamic_draft",
               %{slug: "runner_codegen", summary: "Need a read-only diagnostic action"},
               context()
             )

    assert permission_decision.permission == :dynamic_codegen_request
    assert draft.slug == "runner_codegen"
    assert draft.tier == "draft"
    assert draft.producer == "codegen_llm"
    assert budget["provider_calls_used"] == 4
  end

  defp context, do: %{actor: "local", channel: :cli}

  defp enable_dynamic_codegen!(profile) do
    assert {:ok, _settings} =
             Settings.write_user_settings(%{
               "dynamic_codegen" => %{"enabled" => true, "provider_profile" => profile}
             })
  end

  defp temp_path(name) do
    Path.join(
      System.tmp_dir!(),
      "allbert-dynamic-actions-#{name}-#{System.unique_integer([:positive])}"
    )
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
