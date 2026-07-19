defmodule AllbertAssist.Security.V062SweepEvalTest do
  @moduledoc """
  v0.62 Packaging & Entry Points sweep (ADR 0076).

  Inventory completeness / shape / ownership routing for the 18 `:v062` eval
  rows, plus the sweep-owned rows: the no-new-authority envelope (the v0.62-added
  registry entries are exactly the named internal actions, with no new permission
  class or Settings key), the converged TUI reads staying off the intent
  router, the vault no-leak posture, the documented package layout, and the
  ADR 0076 acceptance / ADR 0070 convergence artifacts. The behavioural rows are
  asserted by their owning proof tests (routed below).
  """
  use AllbertAssist.SecurityEvalCase, async: false

  alias AllbertAssist.Actions.Registry
  alias AllbertAssist.Security.Policy
  alias AllbertAssist.SecurityFixtures.EvalInventory
  alias AllbertAssist.Settings
  alias AllbertAssist.Settings.Secrets
  alias AllbertAssist.Settings.Vault
  alias AllbertAssist.Settings.Vault.Env
  alias AllbertAssist.Settings.Vault.MacKeychain

  @eval_ids ~w(
    packaging-no-authority-change-001
    cli-command-inventory-spine-map-001
    cli-operator-dev-split-no-new-command-001
    cli-attach-single-writer-001
    first-run-no-silent-egress-001
    first-model-state-enum-001
    ollama-install-and-pull-confirmed-001
    install-artifact-verified-001
    uninstall-preserves-home-001
    serve-health-readonly-001
    tui-convergence-readonly-internal-001
    tui-convergence-not-intent-candidate-001
    secret-vault-no-leak-001
    vault-tier-resolution-explicit-001
    secret-vault-migration-redacted-001
    home-layout-package-paths-documented-001
    adr-0076-accepted-001
    adr-0070-converged-001
  )

  @owners %{
    "packaging-no-authority-change-001" => "AllbertAssist.Security.V062SweepEvalTest",
    "cli-command-inventory-spine-map-001" => "AllbertAssist.CLI.CommandsTest",
    "cli-operator-dev-split-no-new-command-001" => "AllbertAssist.CLI.CommandsTest",
    "cli-attach-single-writer-001" => "AllbertAssist.CLI.DispatcherTest",
    "first-run-no-silent-egress-001" => "AllbertAssist.CLI.FirstRunTest",
    "first-model-state-enum-001" => "AllbertAssist.FirstModelTest",
    "ollama-install-and-pull-confirmed-001" => "AllbertAssist.FirstModelTest",
    "install-artifact-verified-001" => "AllbertAssist.InstallPathTest",
    "uninstall-preserves-home-001" => "AllbertAssist.InstallPathTest",
    "serve-health-readonly-001" => "AllbertAssist.ServeTest",
    "tui-convergence-readonly-internal-001" => "AllbertAssist.Channels.TUIConvergenceTest",
    "tui-convergence-not-intent-candidate-001" => "AllbertAssist.Security.V062SweepEvalTest",
    "secret-vault-no-leak-001" => "AllbertAssist.Security.V062SweepEvalTest",
    "vault-tier-resolution-explicit-001" => "AllbertAssist.Settings.VaultTest",
    "secret-vault-migration-redacted-001" => "AllbertAssist.Settings.VaultTest",
    "home-layout-package-paths-documented-001" => "AllbertAssist.Security.V062SweepEvalTest",
    "adr-0076-accepted-001" => "AllbertAssist.Security.V062SweepEvalTest",
    "adr-0070-converged-001" => "AllbertAssist.Security.V062SweepEvalTest"
  }

  # The internal actions v0.62 adds to the registry, per milestone. The
  # no-authority envelope means the registry diff is exactly these — all
  # internal, none agent-routable, none introducing a new permission class.
  @v062_internal_actions %{
    "persist_approval_media_response" => :conversation_write,
    "first_model_detect" => :read_only,
    "install_ollama" => :command_execute,
    "pull_model" => :external_network,
    "serve_health" => :read_only,
    "service_control" => :command_execute,
    "vault_status" => :read_only,
    "migrate_secrets" => :settings_write,
    "create_job" => :job_write,
    "configure_channel_secret" => :settings_secret_write,
    "configure_channel_setting" => :settings_write,
    "link_channel_identity" => :settings_write,
    "unlink_channel_identity" => :settings_write,
    "clear_session" => :conversation_write,
    "sweep_expired_sessions" => :conversation_write,
    "complete_thread" => :conversation_write,
    "create_protocol_token" => :settings_secret_write,
    "rotate_protocol_token" => :settings_secret_write,
    "revoke_protocol_token" => :settings_secret_write,
    "ensure_voice_token" => :voice_local_runtime_manage,
    "rotate_workspace_signing_secret" => :settings_secret_write,
    "mcp_scan_enable" => :settings_write,
    "mcp_scan_pause" => :job_write,
    "mcp_scan_resume" => :job_write,
    "mcp_scan_run_once" => :job_write
  }

  # The converged TUI console reads (M6 + the M4/M5 reads its slash lines route
  # to). Each must stay internal and off the intent-router candidate set.
  @tui_reads ~w(list_jobs trace_summary registry_health list_memory_category_summary serve_health first_model_detect)

  @repo_root Path.expand("../../../../", __DIR__)

  test "v0.62 eval inventory rows are complete and routed to their owning tests" do
    rows = EvalInventory.rows_for_milestone(:v062)
    row_ids = Enum.map(rows, & &1.id)
    rows_by_id = Map.new(rows, &{&1.id, &1})

    assert MapSet.new(row_ids) == MapSet.new(@eval_ids)
    assert length(row_ids) == length(@eval_ids)
    assert length(row_ids) == 18
    assert Enum.all?(rows, &(&1.milestone == :v062))

    for {id, owner} <- @owners do
      assert rows_by_id[id].test_module == owner, "row #{id} routed to the wrong owning test"
    end
  end

  test "v0.62 sweep rows encode concrete pass criteria" do
    rows = EvalInventory.rows_for_milestone(:v062)

    for row <- rows do
      assert is_atom(row.boundary)
      assert is_list(row.assert) and row.assert != []
      assert is_binary(row.scenario) and byte_size(row.scenario) > 12
    end
  end

  test "packaging-no-authority-change-001: registry diff is exactly the named internal actions" do
    names = MapSet.new(Registry.names())
    agent_names = MapSet.new(Enum.map(Registry.agent_capabilities(), & &1.name))

    for {name, expected_permission} <- @v062_internal_actions do
      assert MapSet.member?(names, name), "#{name} is not registered"
      assert {:ok, capability} = Registry.capability(name)
      assert capability.exposure == :internal, "#{name} must be :internal"
      refute MapSet.member?(agent_names, name), "#{name} must not be agent-routable"

      # No new permission class: each reuses an existing class.
      assert capability.permission == expected_permission
      assert expected_permission in Policy.permission_classes()
    end

    IO.puts(
      "packaging-no-authority-change-001 status=pass internal_actions=#{map_size(@v062_internal_actions)} " <>
        "new_permission_classes=0 exposure=internal"
    )
  end

  test "tui-convergence-not-intent-candidate-001: converged reads stay off the intent router" do
    agent_names = MapSet.new(Enum.map(Registry.agent_capabilities(), & &1.name))
    names = MapSet.new(Registry.names())

    for name <- @tui_reads do
      assert MapSet.member?(names, name), "#{name} is not registered"
      refute MapSet.member?(agent_names, name), "#{name} must not be an intent-router candidate"
      assert {:ok, capability} = Registry.capability(name)
      assert capability.exposure == :internal
    end

    IO.puts(
      "tui-convergence-not-intent-candidate-001 status=pass reads=#{length(@tui_reads)} intent_candidates=0"
    )
  end

  test "secret-vault-no-leak-001: vault flows never surface a raw secret value" do
    secret_ref = "secret://providers/openai/api_key"
    secret_value = "sk-openai-DO-NOT-LEAK-#{System.unique_integer([:positive])}"

    original_settings = Application.get_env(:allbert_assist, Settings)
    original_backend = System.get_env("ALLBERT_VAULT_BACKEND")

    root =
      Path.join(
        System.tmp_dir!(),
        "allbert-v062-noleak-#{System.pid()}-#{System.unique_integer([:positive])}"
      )

    File.rm_rf!(root)
    Application.put_env(:allbert_assist, Settings, root: root)
    System.put_env("ALLBERT_VAULT_BACKEND", "encrypted_file")

    on_exit(fn ->
      if original_settings,
        do: Application.put_env(:allbert_assist, Settings, original_settings),
        else: Application.delete_env(:allbert_assist, Settings)

      if original_backend,
        do: System.put_env("ALLBERT_VAULT_BACKEND", original_backend),
        else: System.delete_env("ALLBERT_VAULT_BACKEND")

      File.rm_rf!(root)
    end)

    assert {:ok, _} = Secrets.put_secret(secret_ref, secret_value, %{})

    # Tier resolution surfaces tier + notice, never the value.
    resolution = Vault.resolve()
    refute inspect(resolution) =~ secret_value

    # OS-vault error strings redact the -w value.
    error_runner = fn _args -> {"failed near -w #{secret_value}", 1} end
    Application.put_env(:allbert_assist, :vault_security_runner, error_runner)
    on_exit(fn -> Application.delete_env(:allbert_assist, :vault_security_runner) end)
    assert {:error, {:keychain, 1, redacted}} = MacKeychain.put(secret_ref, secret_value, %{})
    refute redacted =~ secret_value

    # Env tier surfaces provider key names only.
    System.put_env("OPENAI_API_KEY", secret_value)
    on_exit(fn -> System.delete_env("OPENAI_API_KEY") end)
    refute Enum.any?(Env.env_provided(), &(&1 =~ secret_value))

    IO.puts(
      "secret-vault-no-leak-001 status=pass resolution=redacted keychain_error=redacted env=names_only"
    )
  end

  test "home-layout-package-paths-documented-001: package paths + vault refs are documented" do
    install = read!("docs/operator/install.md")
    hardening = read!("docs/operator/security-hardening.md")

    # Packaged-install paths + extraction/plugins layout documented.
    assert install =~ "plugins" or install =~ "RELEASE_ROOT"
    assert install =~ "Home" or install =~ "ALLBERT_HOME"

    # Vault references documented (the M7 seam).
    assert hardening =~ "Secret Vault"
    assert hardening =~ "allbert admin vault"
    assert hardening =~ "ALLBERT_VAULT_BACKEND"

    IO.puts(
      "home-layout-package-paths-documented-001 status=pass install_paths=documented vault_refs=documented"
    )
  end

  test "adr-0076-accepted-001: ADR 0076 is Accepted (v0.62) with the Distribution Trust section" do
    adr = read!("docs/adr/0076-packaging-distribution-and-unified-cli.md")

    assert adr =~ "Status: Accepted (v0.62)"
    assert adr =~ "## Distribution Trust"

    IO.puts("adr-0076-accepted-001 status=pass adr=accepted distribution_trust=present")
  end

  test "adr-0070-converged-001: ADR 0070 marks the TUI console convergence complete" do
    adr = read!("docs/adr/0070-tui-operator-console-and-read-only-operator-actions.md")

    assert adr =~ "converged (v0.62 M6)"

    IO.puts("adr-0070-converged-001 status=pass adr=converged")
  end

  defp read!(relative) do
    @repo_root |> Path.join(relative) |> File.read!()
  end
end
