defmodule AllbertAssist.Settings.VaultTest do
  @moduledoc """
  v0.62 M7 — three-tier secret vault (signed Locked Decision 12).

  Proves the contract the milestone is built on: tier resolution is explicit
  and surfaced (never silent), the OS-vault adapters shell out only through an
  injected runner (no real Keychain / Secret Service touched), the encrypted
  file remains the headless-safe fallback, the env tier is read-only, and the
  migrate-secrets action moves values without ever surfacing a secret in its
  output (redaction sweep). These back eval rows `secret-vault-no-leak-001`,
  `vault-tier-resolution-explicit-001`, `secret-vault-migration-redacted-001`.
  """
  use AllbertAssist.DataCase, async: false

  alias AllbertAssist.Actions.Runner
  alias AllbertAssist.Actions.Settings.MigrateSecrets
  alias AllbertAssist.Actions.Settings.VaultStatus
  alias AllbertAssist.Settings
  alias AllbertAssist.Settings.Secrets
  alias AllbertAssist.Settings.Vault
  alias AllbertAssist.Settings.Vault.EncryptedFile
  alias AllbertAssist.Settings.Vault.Env
  alias AllbertAssist.Settings.Vault.LinuxSecretService
  alias AllbertAssist.Settings.Vault.MacKeychain

  @secret_ref "secret://providers/anthropic/api_key"
  @secret_value "sk-ant-SUPER-SECRET-VALUE-do-not-leak"

  setup do
    original_settings = Application.get_env(:allbert_assist, Settings)
    original_backend = System.get_env("ALLBERT_VAULT_BACKEND")

    root =
      Path.join(System.tmp_dir!(), "allbert-vault-#{System.unique_integer([:positive])}")

    Application.put_env(:allbert_assist, Settings, root: root)

    on_exit(fn ->
      if original_settings,
        do: Application.put_env(:allbert_assist, Settings, original_settings),
        else: Application.delete_env(:allbert_assist, Settings)

      if original_backend,
        do: System.put_env("ALLBERT_VAULT_BACKEND", original_backend),
        else: System.delete_env("ALLBERT_VAULT_BACKEND")

      Application.delete_env(:allbert_assist, :vault_security_runner)
      Application.delete_env(:allbert_assist, :vault_secret_tool_runner)
      File.rm_rf!(root)
    end)

    :ok
  end

  describe "tier resolution (never silent)" do
    test "resolve/0 always names the active tier and why" do
      System.delete_env("ALLBERT_VAULT_BACKEND")
      resolution = Vault.resolve()

      assert resolution.tier in [:os, :encrypted_file, :env]
      assert is_binary(resolution.notice) and resolution.notice != ""
      assert is_atom(resolution.backend)
    end

    test "ALLBERT_VAULT_BACKEND override is honored and surfaced" do
      System.put_env("ALLBERT_VAULT_BACKEND", "encrypted_file")
      resolution = Vault.resolve()

      assert resolution.tier == :encrypted_file
      assert resolution.backend == EncryptedFile
      assert resolution.notice =~ "override"
    end

    test "a vault-absent host falls to the encrypted file with a notice, not silently" do
      System.put_env("ALLBERT_VAULT_BACKEND", "encrypted_file")
      resolution = Vault.resolve()

      # Explicit fallback tier + explanatory notice — never an empty/implicit one.
      assert resolution.tier == :encrypted_file
      assert resolution.notice != ""
    end
  end

  describe "EncryptedFile tier (tier 2, the stable fallback)" do
    test "round-trips through Settings.Secrets unchanged" do
      assert {:ok, _} = EncryptedFile.put(@secret_ref, @secret_value, %{})
      assert {:ok, @secret_value} = EncryptedFile.get(@secret_ref, %{})
    end
  end

  describe "MacKeychain tier (tier 1 macOS, injected runner)" do
    test "put/get shell out via the injected runner; errors redact -w values" do
      test_pid = self()

      runner = fn args ->
        send(test_pid, {:security, args})

        cond do
          "add-generic-password" in args -> {"", 0}
          "find-generic-password" in args -> {@secret_value, 0}
          true -> {"", 1}
        end
      end

      Application.put_env(:allbert_assist, :vault_security_runner, runner)

      assert {:ok, %{tier: :os}} = MacKeychain.put(@secret_ref, @secret_value, %{})
      assert {:ok, @secret_value} = MacKeychain.get(@secret_ref, %{})

      # The put argv carried the value; confirm the module redacts it on error paths.
      error_runner = fn _args -> {"error near -w #{@secret_value}", 1} end
      Application.put_env(:allbert_assist, :vault_security_runner, error_runner)
      assert {:error, {:keychain, 1, redacted}} = MacKeychain.put(@secret_ref, @secret_value, %{})
      refute redacted =~ @secret_value
      assert redacted =~ "[redacted]"
    end
  end

  describe "LinuxSecretService tier (tier 1 Linux, injected runner)" do
    test "put pipes the value over stdin; get looks it up" do
      test_pid = self()

      runner = fn args, stdin ->
        send(test_pid, {:secret_tool, args, stdin})

        cond do
          "store" in args -> {"", 0}
          "lookup" in args -> {@secret_value <> "\n", 0}
          true -> {"", 1}
        end
      end

      Application.put_env(:allbert_assist, :vault_secret_tool_runner, runner)

      assert {:ok, %{tier: :os}} = LinuxSecretService.put(@secret_ref, @secret_value, %{})
      assert_received {:secret_tool, ["store" | _], @secret_value}
      assert {:ok, @secret_value} = LinuxSecretService.get(@secret_ref, %{})
    end
  end

  describe "Env tier (tier 3, read-only)" do
    test "writes are refused and env-provided keys are surfaced by name only" do
      assert {:error, :env_tier_is_read_only} = Env.put(@secret_ref, @secret_value, %{})
      assert {:error, :env_tier_is_read_only} = Env.delete(@secret_ref, %{})

      System.put_env("ANTHROPIC_API_KEY", @secret_value)
      on_exit(fn -> System.delete_env("ANTHROPIC_API_KEY") end)

      provided = Env.env_provided()
      assert "ANTHROPIC_API_KEY" in provided
      # Names only — the value never appears in the surfaced list.
      refute Enum.any?(provided, &(&1 =~ @secret_value))
    end
  end

  describe "vault_status action (read-only)" do
    test "reports the resolved tier + posture without secret values" do
      System.put_env("ALLBERT_VAULT_BACKEND", "encrypted_file")

      assert {:ok, response} = VaultStatus.run(%{}, %{user_id: "local"})
      assert response.status == :completed
      assert response.vault.tier == :encrypted_file
      assert is_boolean(response.vault.os_vault_available)
      refute inspect(response) =~ @secret_value
    end
  end

  describe "migrate_secrets action" do
    test "dry_run previews the reference set without moving anything" do
      assert {:ok, %{status: :completed, migration: migration}} =
               MigrateSecrets.run(%{dry_run: true}, %{user_id: "local"})

      assert migration.executed == false
      assert is_list(migration.refs)
    end

    test "the first call is confirmation-gated and executes NOTHING (M8.8)" do
      # v0.62 M8.8: migrate_secrets carries a settings_write needs_confirmation
      # floor (Policy.safety_floor). Through the Runner (the only real path) the
      # first invocation must return needs_confirmation and move no secret.
      assert {:ok, _} = Secrets.put_secret(@secret_ref, @secret_value, %{})
      System.put_env("ALLBERT_VAULT_BACKEND", "os")

      test_pid = self()

      runner = fn args ->
        if "add-generic-password" in args, do: send(test_pid, {:migrated, args})
        {"", 0}
      end

      Application.put_env(:allbert_assist, :vault_security_runner, runner)

      assert {:ok, response} = Runner.run("migrate_secrets", %{}, %{user_id: "local"})

      assert response.status == :needs_confirmation
      refute_received {:migrated, _args}
      refute inspect(response) =~ @secret_value
    end

    test "an approved resume round-trips into the OS vault and never surfaces a secret" do
      assert {:ok, _} = Secrets.put_secret(@secret_ref, @secret_value, %{})
      System.put_env("ALLBERT_VAULT_BACKEND", "os")

      test_pid = self()

      runner = fn args ->
        if "add-generic-password" in args, do: send(test_pid, {:migrated, args})
        {"", 0}
      end

      Application.put_env(:allbert_assist, :vault_security_runner, runner)

      # A durable approved confirmation resumes the action with an approved
      # context (the confirmation subsystem sets this server-side, never params).
      approved = %{user_id: "local", confirmation: %{approved?: true}}
      assert {:ok, response} = Runner.run("migrate_secrets", %{}, approved)

      assert response.status in [:completed, :error]
      assert_received {:migrated, _args}
      refute inspect(response) =~ @secret_value
    end

    test "the durable confirmation record round-trips create → list → approve → migrate (M8.14)" do
      # v0.62 M8.14: the M8.8 needs_confirmation floor was non-completable — the
      # action never persisted a Confirmations record, so `admin confirmations
      # approve <id>` had nothing to resume. This proves the REAL operator path:
      # the gate creates a durable record, it shows up in the list, and approving
      # it (not an injected `approved?` stub) resumes the migration.
      assert {:ok, _} = Secrets.put_secret(@secret_ref, @secret_value, %{})
      System.put_env("ALLBERT_VAULT_BACKEND", "os")

      test_pid = self()

      runner = fn args ->
        if "add-generic-password" in args, do: send(test_pid, {:migrated, args})
        {"", 0}
      end

      Application.put_env(:allbert_assist, :vault_security_runner, runner)

      assert {:ok, gated} =
               Runner.run("migrate_secrets", %{}, %{actor: "local", channel: :cli})

      assert gated.status == :needs_confirmation
      confirmation_id = gated.confirmation_id
      assert is_binary(confirmation_id)
      refute_received {:migrated, _args}

      assert {:ok, listed} =
               Runner.run("list_confirmations", %{}, %{actor: "local", channel: :cli})

      assert Enum.any?(listed.confirmations, &(&1["id"] == confirmation_id))

      assert {:ok, approved} =
               Runner.run("approve_confirmation", %{id: confirmation_id}, %{
                 actor: "local",
                 channel: :cli,
                 surface: "mix allbert.confirmations"
               })

      assert approved.status == :completed
      assert_received {:migrated, _args}
      refute inspect(approved) =~ @secret_value
    end

    test "a confirmation key smuggled into PARAMS does not authorize (M8.10)" do
      # The approval flag lives in server-derived context, never params. A
      # caller-supplied `confirmation` param is not in the action schema, so the
      # strict param contract rejects it outright (it can never reach
      # approval_resume?) — the migration does NOT run. Proves the params/context
      # trust boundary the security audit named.
      assert {:ok, _} = Secrets.put_secret(@secret_ref, @secret_value, %{})
      System.put_env("ALLBERT_VAULT_BACKEND", "os")

      test_pid = self()

      runner = fn args ->
        if "add-generic-password" in args, do: send(test_pid, {:migrated, args})
        {"", 0}
      end

      Application.put_env(:allbert_assist, :vault_security_runner, runner)

      spoofed = %{"confirmation" => %{"approved?" => true}, "dry_run" => false}
      assert {:ok, response} = Runner.run("migrate_secrets", spoofed, %{user_id: "local"})

      # Not completed (rejected/gated), and — the real invariant — nothing moved.
      refute response.status == :completed
      refute_received {:migrated, _args}
    end
  end
end
