defmodule AllbertAssist.Security.V064SweepEvalTest do
  @moduledoc """
  v0.64 Trusted Install And Non-Developer First Run sweep.

  The behavioural rows are owned by focused proof suites. This sweep owns the
  row inventory, docs-handoff rows, cross-surface repair contract, and the static
  binding check that keeps `assert:` atoms attached to real assertions.
  """
  use AllbertAssist.SecurityEvalCase, async: false

  import ExUnit.CaptureIO

  alias AllbertAssist.CLI.FirstRun
  alias AllbertAssist.CLI.Tui
  alias AllbertAssist.Onboarding
  alias AllbertAssist.Paths
  alias AllbertAssist.SecurityFixtures.AssertBinding
  alias AllbertAssist.SecurityFixtures.EvalInventory

  @eval_ids ~w(
    trusted-install-artifact-verification-001
    trusted-install-guided-verifier-bootstrap-001
    trusted-install-rollback-restore-001
    first-run-no-raw-mix-required-001
    first-run-blocked-state-repairable-001
    first-model-guided-runtime-install-no-cli-001
    first-model-consumer-oneclick-download-progress-no-key-001
    first-model-advanced-byok-or-custom-001
    first-run-conversational-routing-no-misroute-001
    first-run-persistent-service-no-repeat-serve-001
    first-run-trust-spine-no-authority-001
    first-run-secrets-redacted-001
    first-run-v065-handoff-current-001
  )

  @owners %{
    "trusted-install-artifact-verification-001" => "AllbertAssist.InstallPathTest",
    "trusted-install-guided-verifier-bootstrap-001" => "AllbertAssist.InstallPathTest",
    "trusted-install-rollback-restore-001" => "AllbertAssist.DatabaseBackupTest",
    "first-run-no-raw-mix-required-001" => "AllbertAssist.Security.V064SweepEvalTest",
    "first-run-blocked-state-repairable-001" => "AllbertAssist.Security.V064SweepEvalTest",
    "first-model-guided-runtime-install-no-cli-001" => "AllbertAssist.CLI.Areas.OnboardingTest",
    "first-model-consumer-oneclick-download-progress-no-key-001" =>
      "AllbertAssist.FirstModelTest",
    "first-model-advanced-byok-or-custom-001" => "AllbertAssist.Onboarding.FlowEvalTest",
    "first-run-conversational-routing-no-misroute-001" => "AllbertAssist.Agents.IntentAgentTest",
    "first-run-persistent-service-no-repeat-serve-001" => "AllbertAssist.CLI.DispatcherTest",
    "first-run-trust-spine-no-authority-001" => "AllbertAssist.Onboarding.FlowEvalTest",
    "first-run-secrets-redacted-001" => "AllbertAssist.Onboarding.SecurityEvalTest",
    "first-run-v065-handoff-current-001" => "AllbertAssist.Security.V064SweepEvalTest"
  }

  @owner_files %{
    "AllbertAssist.InstallPathTest" =>
      "apps/allbert_assist/test/allbert_assist/install_path_test.exs",
    "AllbertAssist.DatabaseBackupTest" =>
      "apps/allbert_assist/test/allbert_assist/database_backup_test.exs",
    "AllbertAssist.Security.V064SweepEvalTest" =>
      "apps/allbert_assist/test/security/v064_sweep_eval_test.exs",
    "AllbertAssist.CLI.Areas.OnboardingTest" =>
      "apps/allbert_assist/test/allbert_assist/cli/areas/onboarding_test.exs",
    "AllbertAssist.FirstModelTest" =>
      "apps/allbert_assist/test/allbert_assist/first_model/first_model_test.exs",
    "AllbertAssist.Onboarding.FlowEvalTest" =>
      "apps/allbert_assist/test/security/onboarding_flow_eval_test.exs",
    "AllbertAssist.Agents.IntentAgentTest" =>
      "apps/allbert_assist/test/allbert_assist/agents/intent_agent_test.exs",
    "AllbertAssist.CLI.DispatcherTest" =>
      "apps/allbert_assist/test/allbert_assist/cli/dispatcher_test.exs",
    "AllbertAssist.Onboarding.SecurityEvalTest" =>
      "apps/allbert_assist/test/security/onboarding_security_eval_test.exs"
  }

  @repo_root Path.expand("../../../../", __DIR__)

  setup do
    original_paths_config = Application.get_env(:allbert_assist, Paths)
    original_override = Application.get_env(:allbert_assist, :first_model_state_override)

    provider_env_keys =
      ~w(ANTHROPIC_API_KEY OPENAI_API_KEY OPENROUTER_API_KEY GOOGLE_API_KEY GEMINI_API_KEY)

    saved_provider_env = Map.new(provider_env_keys, &{&1, System.get_env(&1)})
    saved_ollama_host = System.get_env("OLLAMA_HOST")

    on_exit(fn ->
      restore_app_env(Paths, original_paths_config)
      restore_app_env(:first_model_state_override, original_override)

      Enum.each(saved_provider_env, fn
        {key, nil} -> System.delete_env(key)
        {key, value} -> System.put_env(key, value)
      end)

      if saved_ollama_host,
        do: System.put_env("OLLAMA_HOST", saved_ollama_host),
        else: System.delete_env("OLLAMA_HOST")
    end)

    :ok
  end

  test "v0.64 eval inventory rows are complete and routed to their owning tests" do
    rows = EvalInventory.rows_for_milestone(:v064)
    row_ids = Enum.map(rows, & &1.id)
    rows_by_id = Map.new(rows, &{&1.id, &1})

    assert MapSet.new(row_ids) == MapSet.new(@eval_ids)
    assert length(row_ids) == length(@eval_ids)
    assert length(row_ids) == 13
    assert Enum.all?(rows, &(&1.milestone == :v064))

    for {id, owner} <- @owners do
      assert rows_by_id[id].test_module == owner, "row #{id} routed to the wrong owning test"
    end

    IO.puts("v064-inventory-complete status=pass rows=13 owners=routed")
  end

  test "v0.64 rows encode concrete pass criteria" do
    rows = EvalInventory.rows_for_milestone(:v064)

    for row <- rows do
      assert is_atom(row.boundary)
      assert is_list(row.assert) and row.assert != []
      assert is_binary(row.scenario) and byte_size(row.scenario) > 12
    end
  end

  test "first-run-no-raw-mix-required-001: operator docs are package-first" do
    onboarding_doc = read!("docs/operator/onboarding.md")

    assert onboarding_doc =~ "Install the packaged binary first"

    assert onboarding_doc =~
             "Source checkout (`mix setup`,\n`mix phx.server`) is for contributors"

    assert onboarding_doc =~
             "Foreground `allbert serve --open` is a diagnostic or repair fallback"

    IO.puts("first-run-no-raw-mix-required-001 status=pass docs=package_first")

    AssertBinding.check!("first-run-no-raw-mix-required-001", [
      :package_first_docs,
      :source_checkout_diagnostic_only,
      :serve_is_fallback
    ])
  end

  test "first-run-blocked-state-repairable-001: web, CLI copy, and TUI guard repair blocks" do
    web_first_run = read!("apps/allbert_assist_web/lib/allbert_assist_web/workspace/first_run.ex")

    assert web_first_run =~ "model_repair_destination"
    assert web_first_run =~ ~s("workspace:models")

    for probe <-
          ~w(runtime_missing runtime_unhealthy model_missing below_hardware_floor)a,
        track <- [:quickstart, :advanced] do
      guidance = Onboarding.model_path_guidance(first_model_state: probe, track: track)
      blob = guidance.headline <> " " <> guidance.next_action

      assert guidance.repairable?
      assert guidance.action in [:install_runtime, :pull_model, :choose_provider]
      assert guidance.next_action =~ ~r/\S/

      for raw <- ~w(runtime_missing runtime_unhealthy model_missing below_hardware_floor) do
        refute blob =~ raw
      end
    end

    root =
      Path.join(
        System.tmp_dir!(),
        "allbert-v064-tui-#{System.pid()}-#{System.unique_integer([:positive])}"
      )

    File.rm_rf!(root)
    on_exit(fn -> File.rm_rf!(root) end)

    Application.put_env(:allbert_assist, Paths, home: root)
    Application.put_env(:allbert_assist, :first_model_state_override, :runtime_missing)
    clear_provider_env!()
    File.mkdir_p!(Path.join([root, "db"]))
    File.write!(Path.join([root, "db", "allbert.sqlite3"]), "x")
    FirstRun.mark_onboarding_complete()
    FirstRun.mark_profile_reviewed()

    output =
      capture_io(:stderr, fn ->
        assert {:error, {:first_run_not_ready, :first_model_not_ready}} = Tui.readiness_guard()
      end)

    assert output =~ "workspace:models"
    refute output =~ "runtime_missing"

    IO.puts("first-run-blocked-state-repairable-001 status=pass surfaces=web,cli,tui")

    AssertBinding.check!("first-run-blocked-state-repairable-001", [
      :web_routes_model_block_to_models,
      :repair_guidance_has_one_action,
      :tui_guard_no_raw_atom
    ])
  end

  test "first-run-v065-handoff-current-001: local files, notes, and memory handoff is current" do
    v065 = read!("docs/plans/archives/v0.65-plan.md")
    roadmap = read!("docs/plans/archives/1.0-roadmap.md")
    normalized_v065 = String.replace(v065, ~r/\s+/, " ")

    assert v065 =~ "# Allbert v0.65 Local Knowledge: Files, Notes, And Agent Memory"
    assert normalized_v065 =~ "local files/notes plus reviewed agent memory"
    assert v065 =~ "notes/files"
    assert v065 =~ "reviewed memory"
    assert roadmap =~ "v0.65: Local Knowledge: Files, Notes, And Agent Memory"

    IO.puts("first-run-v065-handoff-current-001 status=pass handoff=current")

    AssertBinding.check!("first-run-v065-handoff-current-001", [
      :v065_plan_exists,
      :local_notes_files_named,
      :reviewed_memory_named
    ])
  end

  test "every :v064 row binds its assert atoms in its owning test" do
    sources =
      Map.new(@owner_files, fn {mod, path} -> {mod, read!(path)} end)

    for row <- EvalInventory.rows_for_milestone(:v064) do
      source = Map.fetch!(sources, row.test_module)

      assert source =~ ~s|check!("#{row.id}"|,
             "row #{row.id} has no AssertBinding.check!/2 binding in #{row.test_module}"
    end

    IO.puts("v064-assert-atom-binding status=pass rows=13 unbound=0")
  end

  defp clear_provider_env! do
    ~w(ANTHROPIC_API_KEY OPENAI_API_KEY OPENROUTER_API_KEY GOOGLE_API_KEY GEMINI_API_KEY)
    |> Enum.each(&System.delete_env/1)

    System.put_env("OLLAMA_HOST", "https://example.invalid")
  end

  defp read!(relative) do
    @repo_root |> Path.join(relative) |> File.read!()
  end

  defp restore_app_env(key, nil), do: Application.delete_env(:allbert_assist, key)
  defp restore_app_env(key, value), do: Application.put_env(:allbert_assist, key, value)
end
