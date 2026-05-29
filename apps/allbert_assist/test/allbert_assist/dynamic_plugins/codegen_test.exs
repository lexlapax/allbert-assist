defmodule AllbertAssist.DynamicPlugins.CodegenTest do
  use AllbertAssist.DataCase, async: false

  alias AllbertAssist.Actions.Registry
  alias AllbertAssist.Actions.Runner
  alias AllbertAssist.DynamicPlugins
  alias AllbertAssist.DynamicPlugins.ActionsOverlay
  alias AllbertAssist.DynamicPlugins.Codegen.LLM
  alias AllbertAssist.DynamicPlugins.Codegen.Schema
  alias AllbertAssist.DynamicPlugins.MetadataStore
  alias AllbertAssist.DynamicPlugins.TrustedValidator
  alias AllbertAssist.Objectives
  alias AllbertAssist.Paths
  alias AllbertAssist.Sandbox.Host
  alias AllbertAssist.Settings
  alias AllbertAssist.TestSupport.DynamicCodegenFakeProvider

  @env_vars ["ALLBERT_HOME", "ALLBERT_HOME_DIR", "ALLBERT_SETTINGS_ROOT"]

  defmodule CompletingDocker do
    @behaviour AllbertAssist.Sandbox.Backend

    alias AllbertAssist.Sandbox.CommandSpec
    alias AllbertAssist.Sandbox.Report
    alias AllbertAssist.Sandbox.ReportWriter

    def id, do: :docker
    def platforms, do: [:linux, :macos]
    def available?(_policy), do: true
    def doctor(_policy), do: %{id: id(), status: :available, reason: :doctor_green}

    def run(bundle, command, _policy) do
      ReportWriter.write(bundle, %Report{
        status: :completed,
        backend: id(),
        command: CommandSpec.summary(command),
        metadata: %{fixture_backend?: true}
      })
    end

    def cleanup(_bundle), do: :ok
  end

  defmodule FailingDocker do
    @behaviour AllbertAssist.Sandbox.Backend

    alias AllbertAssist.Sandbox.CommandSpec
    alias AllbertAssist.Sandbox.Report
    alias AllbertAssist.Sandbox.ReportWriter

    def id, do: :docker
    def platforms, do: [:linux, :macos]
    def available?(_policy), do: true
    def doctor(_policy), do: %{id: id(), status: :available, reason: :doctor_green}

    def run(bundle, command, _policy) do
      ReportWriter.write(bundle, %Report{
        status: :failed,
        backend: id(),
        command: CommandSpec.summary(command),
        diagnostics: [%{reason: :fixture_failure}]
      })
    end

    def cleanup(_bundle), do: :ok
  end

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
    ActionsOverlay.clear()

    on_exit(fn ->
      ActionsOverlay.clear()
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

  test "dynamic codegen defaults to the coding profile when configured" do
    enable_dynamic_codegen!("coding")

    assert {:ok, profile} = Settings.resolve_model_profile("coding")
    assert profile.provider == "gemini"
    assert profile.provider_type == "google"
    assert profile.model == "gemini-3.5-flash"

    assert {:ok, _fallback} = Settings.resolve_model_profile("coding_local")
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

  test "action draft schema satisfies strict structured-output provider requirements" do
    schema = Schema.action_draft_schema()
    property_names = schema.properties |> Map.keys() |> Enum.sort()

    assert schema.additionalProperties == false
    assert Enum.sort(schema.required) == property_names
    assert schema.properties["action_name"].type == "string"
    assert schema.properties["notes"].type == "array"
    assert schema.properties["usage_units"].type == "integer"

    assert {:ok, %{schema: compiled_schema}} = ReqLLM.Schema.compile(schema)

    strict_json =
      compiled_schema
      |> Jason.encode!()
      |> Jason.decode!()

    assert strict_json["additionalProperties"] == false
    assert Enum.sort(strict_json["required"]) == property_names

    for role <- [:planner, :author, :trial_author, :critic, :repair] do
      role_schema = Schema.role_schema(role)
      role_property_names = role_schema.properties |> Map.keys() |> Enum.sort()

      assert role_schema.additionalProperties == false
      assert Enum.sort(role_schema.required) == role_property_names
      assert {:ok, _compiled_schema} = ReqLLM.Schema.compile(role_schema)
    end
  end

  test "provider-call budget caps the whole model-backed workflow" do
    enable_dynamic_codegen!("local")

    assert {:ok, _setting} =
             Settings.put("dynamic_codegen.max_provider_calls_per_gap", 3, %{audit?: false})

    assert {:error,
            {:dynamic_codegen_budget_exhausted,
             %{
               "budget" => "provider_calls",
               "role" => "critic",
               "requested" => 4,
               "limit" => 3
             }}} =
             DynamicPlugins.request_draft(%{
               slug: "role_budget_gap",
               summary: "Need a read-only diagnostic action",
               target_shapes: ["action"]
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
    assert result.budget["provider_calls_used"] == 4
    assert result.budget["provider_usage_units_used"] == 110

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
    roles = get_in(manifest, ["generation", "roles"])
    assert Enum.map(roles, & &1["role"]) == ~w[planner author trial_author critic]
    assert Enum.all?(roles, &(&1["authority"] == "none"))

    assert Enum.map(roles, & &1["status"]) ==
             ~w[planned generated test_authored accepted]

    assert Enum.map(draft.repair_history, & &1["role"]) ==
             ~w[planner author trial_author critic]

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

  test "fake provider can author a delegated memory_write draft when policy allows it" do
    enable_dynamic_codegen!("local")

    assert {:ok, _setting} =
             Settings.put(
               "dynamic_codegen.allowed_action_permissions",
               ["read_only", "memory_write"],
               %{audit?: false}
             )

    assert {:ok, _setting} =
             Settings.put("dynamic_codegen.allowed_facades", ["append_memory"], %{audit?: false})

    assert {:ok, result} =
             DynamicPlugins.request_draft(
               %{
                 slug: "delegated_memory_gap",
                 summary: "Create a generated action to remember a memory note",
                 source: "operator",
                 target_shapes: ["action"]
               },
               context()
             )

    assert result.draft.slug == "delegated_memory_gap"

    assert {:ok, draft} = DynamicPlugins.get_draft("delegated_memory_gap")
    assert {:ok, manifest} = MetadataStore.get_manifest("delegated_memory_gap")
    assert get_in(manifest, ["actions", Access.at(0), "permission"]) == "memory_write"
    assert {:ok, _validation} = TrustedValidator.validate(draft, manifest)

    source = File.read!(Path.join(draft.root, "source/lib/action.ex"))
    assert source =~ "permission: :memory_write"
    assert source =~ ~s(AllbertAssist.DynamicPlugins.Delegate.run("append_memory")
  end

  test "repair creates a new revision from bounded sandbox evidence" do
    enable_dynamic_codegen!("local")

    assert {:ok, generated} =
             DynamicPlugins.request_draft(
               %{
                 slug: "repair_gap",
                 summary: "Need a read-only diagnostic action",
                 target_shapes: ["action"]
               },
               context()
             )

    original_revision = generated.draft.revision

    assert {:ok, repaired} =
             DynamicPlugins.repair_draft(
               "repair_gap",
               %{
                 "source" => "sandbox_gate",
                 "status" => "failed",
                 "diagnostics" => [%{"reason" => "fixture_failure"}]
               },
               context()
             )

    assert repaired.draft.revision != original_revision
    assert repaired.budget["provider_calls_used"] == 7
    assert repaired.budget["provider_usage_units_used"] == 153

    assert {:ok, draft} = DynamicPlugins.get_draft("repair_gap")
    assert draft.gate["status"] == "not_run"
    assert draft.gate["repaired_from_revision"] == original_revision
    assert File.regular?(Path.join([draft.root, "revisions", original_revision, "metadata.yaml"]))
    assert File.regular?(Path.join([draft.root, "revisions", original_revision, "manifest.yaml"]))

    assert Enum.map(draft.repair_history, & &1["role"]) ==
             ~w[planner author trial_author critic planner critic repair]

    assert {:ok, manifest} = MetadataStore.get_manifest("repair_gap")

    assert Enum.map(get_in(manifest, ["generation", "roles"]), & &1["role"]) ==
             ~w[planner critic repair]

    assert :ok = MetadataStore.verify_source_hashes(draft)
  end

  test "workflow requests, gates, integrates, runs, and rolls back a generated action" do
    enable_dynamic_codegen!("local", sandbox?: true, live_loader?: true)

    assert {:ok, result} =
             DynamicPlugins.request_draft_with_gate(
               %{
                 slug: "full_loop_gap",
                 summary: "Need a read-only action that formats name, score, and tags",
                 source: "operator",
                 target_shapes: ["action"]
               },
               context(),
               workflow_opts(CompletingDocker)
             )

    assert result.status == :gate_passed
    assert result.repair_count == 0
    assert result.trial.status == :completed
    assert result.gate.status == :completed

    assert result.trusted_validation.modules == [
             "AllbertAssist.DynamicPlugins.Generated.FullLoopGap.Action"
           ]

    assert result.draft.tier == "gate_passed"

    assert {:ok, %{status: :needs_confirmation, confirmation_id: integration_id}} =
             Runner.run("integrate_dynamic_draft", %{slug: result.slug}, context())

    assert {:ok, %{status: :completed}} =
             Runner.run(
               "approve_confirmation",
               %{id: integration_id, reason: "reviewed generated full loop"},
               context()
             )

    assert {:ok,
            %{
              status: :completed,
              message: "Ada: high score=10 tags=MATH, CODE",
              actions: []
            }} =
             Runner.run(
               "dynamic_full_loop_gap",
               %{name: " Ada ", score: 8, tags: ["math", "code"]},
               context()
             )

    assert {:ok, %{status: :needs_confirmation, confirmation_id: rollback_id}} =
             Runner.run("rollback_dynamic_integration", %{slug: result.slug}, context())

    assert {:ok, %{status: :completed}} =
             Runner.run(
               "approve_confirmation",
               %{id: rollback_id, reason: "rollback generated full loop"},
               context()
             )

    assert {:error, {:unknown_action, "dynamic_full_loop_gap"}} =
             Registry.resolve("dynamic_full_loop_gap")
  end

  test "workflow stops instead of repeatedly repairing identical sandbox evidence" do
    enable_dynamic_codegen!("local", sandbox?: true)

    assert {:error,
            {:dynamic_codegen_repair_impasse,
             %{
               "reason" => "repeated_identical_failure",
               "stage" => "trial",
               "iterations_used" => 1
             }}} =
             DynamicPlugins.request_draft_with_gate(
               %{
                 slug: "repeated_gate_failure",
                 summary: "Need a read-only action that formats name, score, and tags",
                 source: "operator",
                 target_shapes: ["action"]
               },
               context(),
               workflow_opts(FailingDocker)
             )
  end

  defp enable_dynamic_codegen!(profile \\ nil, opts \\ []) do
    settings =
      %{"dynamic_codegen" => %{"enabled" => true}}
      |> maybe_put_profile(profile)
      |> maybe_enable_sandbox(opts)
      |> maybe_enable_live_loader(opts)

    assert {:ok, _settings} = Settings.write_user_settings(settings)
  end

  defp maybe_put_profile(settings, nil), do: settings

  defp maybe_put_profile(settings, profile) do
    put_in(settings, ["dynamic_codegen", "provider_profile"], profile)
  end

  defp maybe_enable_sandbox(settings, opts) do
    if Keyword.get(opts, :sandbox?, false) do
      Map.put(settings, "sandbox", %{
        "elixir" => %{"enabled" => true, "backend" => "docker", "image" => "fixture:local"}
      })
    else
      settings
    end
  end

  defp maybe_enable_live_loader(settings, opts) do
    if Keyword.get(opts, :live_loader?, false) do
      put_in(settings, ["dynamic_codegen", "live_loader_enabled"], true)
    else
      settings
    end
  end

  defp context do
    %{actor: "local", channel: :cli, surface: "cli", explicit_generation?: true}
  end

  defp project_root, do: Path.expand("../../../../..", __DIR__)

  defp workflow_opts(backend) do
    [
      project_root: project_root(),
      project_paths: [
        "mix.exs",
        "mix.lock",
        ".formatter.exs",
        "apps/allbert_assist/mix.exs",
        "apps/allbert_assist/lib",
        "apps/allbert_assist/test/support"
      ],
      profiles: [:compile],
      backends: [backend],
      host: %Host{os: :linux, arch: :x86_64}
    ]
  end

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
