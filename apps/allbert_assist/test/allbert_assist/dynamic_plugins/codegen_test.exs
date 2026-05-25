defmodule AllbertAssist.DynamicPlugins.CodegenTest do
  use AllbertAssist.DataCase, async: false

  alias AllbertAssist.DynamicPlugins
  alias AllbertAssist.DynamicPlugins.Codegen.LLM
  alias AllbertAssist.DynamicPlugins.MetadataStore
  alias AllbertAssist.DynamicPlugins.TrustedValidator
  alias AllbertAssist.Objectives
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

    {:ok, home: home}
  end

  test "dynamic codegen is unavailable when disabled" do
    assert {:error, :dynamic_codegen_disabled} =
             DynamicPlugins.request_draft(%{
               slug: "disabled_gap",
               summary: "Need a read-only diagnostic action"
             })
  end

  test "enabled workflow fails closed without a provider profile" do
    enable_dynamic_codegen!()

    assert {:error, :missing_dynamic_codegen_provider_profile} =
             DynamicPlugins.request_draft(%{
               slug: "missing_provider_gap",
               summary: "Need a read-only diagnostic action"
             })
  end

  test "provider-call budget caps explicit generation requests" do
    enable_dynamic_codegen!("local")

    assert {:ok, _setting} =
             Settings.put("dynamic_codegen.max_provider_calls_per_gap", 1, %{audit?: false})

    assert {:error,
            {:dynamic_codegen_budget_exhausted,
             %{"budget" => "provider_calls", "requested" => 2, "limit" => 1}}} =
             DynamicPlugins.request_draft(%{
               slug: "budget_gap",
               summary: "Need a read-only diagnostic action",
               provider_calls_requested: 2
             })
  end

  test "low-confidence automatic intent output cannot start generation" do
    enable_dynamic_codegen!("local")

    assert {:error,
            {:dynamic_codegen_auto_generation_denied,
             %{"source" => "intent_suggestion", "confidence" => 0.31}}} =
             DynamicPlugins.request_draft(%{
               slug: "auto_gap",
               summary: "Need a read-only diagnostic action",
               source: "intent_suggestion",
               confidence: 0.31
             })
  end

  test "explicit objective generation creates source-bearing draft metadata and an objective event" do
    enable_dynamic_codegen!("local")

    assert {:ok, objective} =
             Objectives.create_objective(%{
               user_id: "operator",
               title: "Request diagnostic draft",
               objective: "Create a read-only diagnostic draft"
             })

    assert {:ok, result} =
             DynamicPlugins.request_draft(
               %{
                 slug: "objective_gap",
                 summary: "Need a read-only diagnostic action",
                 objective_id: objective.id,
                 source: "objective",
                 target_shapes: ["action"]
               },
               context()
             )

    assert result.draft.slug == "objective_gap"
    assert result.draft.tier == "draft"
    assert result.draft.producer == "codegen_llm"
    assert result.budget["provider_calls_used"] == 1
    assert result.budget["provider_usage_units_used"] == 123

    assert result.manifest["modules"] == [
             "AllbertAssist.DynamicPlugins.Generated.ObjectiveGap.Action"
           ]

    assert {:ok, shown} = DynamicPlugins.show_draft("objective_gap")
    assert shown.tier == "draft"
    assert shown.gate_status == "not_run"
    assert shown.diagnostics |> List.first() |> Map.get("status") == "source_generated"

    assert {:ok, draft} = DynamicPlugins.get_draft("objective_gap")
    assert :ok = MetadataStore.verify_source_hashes(draft)
    assert {:ok, manifest} = MetadataStore.get_manifest("objective_gap")
    assert {:ok, _validation} = TrustedValidator.validate(draft, manifest)
    assert File.read!(Path.join(draft.root, "source/lib/action.ex")) =~ "defmodule"
    assert File.read!(Path.join(draft.root, "source/test/action_test.exs")) =~ "Ada: high"

    assert {:ok, staging} =
             DynamicPlugins.stage_draft("objective_gap",
               project_root: project_root(),
               project_paths: [
                 "mix.exs",
                 "mix.lock",
                 ".formatter.exs",
                 "apps/allbert_assist/mix.exs",
                 "apps/allbert_assist/lib",
                 "apps/allbert_assist/test/support"
               ]
             )

    assert length(staging.generated_files) == 2
    assert staging.focused_test_paths == manifest["focused_test_paths"]

    assert Enum.any?(Objectives.list_events(objective.id), fn event ->
             event.kind == "observed" and
               event.summary == "Dynamic codegen draft requested for objective_gap." and
               event.payload =~ "\"stage\":\"dynamic_codegen_draft_requested\""
           end)
  end

  defp enable_dynamic_codegen!(profile \\ nil) do
    settings =
      %{"dynamic_codegen" => %{"enabled" => true}}
      |> maybe_put_profile(profile)

    assert {:ok, _settings} = Settings.write_user_settings(settings)
  end

  defp maybe_put_profile(settings, nil), do: settings

  defp maybe_put_profile(settings, profile) do
    put_in(settings, ["dynamic_codegen", "provider_profile"], profile)
  end

  defp context do
    %{actor: "local", channel: :cli, surface: "cli", explicit_generation?: true}
  end

  defp project_root, do: Path.expand("../../../../..", __DIR__)

  defp temp_path(name) do
    Path.join(
      System.tmp_dir!(),
      "allbert-dynamic-codegen-#{name}-#{System.unique_integer([:positive])}"
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
