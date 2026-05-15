defmodule AllbertAssist.SettingsTest do
  use ExUnit.Case, async: false

  alias AllbertAssist.App.Registry, as: AppRegistry
  alias AllbertAssist.Paths
  alias AllbertAssist.Plugin.Entry, as: PluginEntry
  alias AllbertAssist.Plugin.Registry, as: PluginRegistry
  alias AllbertAssist.Settings
  alias AllbertAssist.Settings.Secrets

  @env_vars [
    "ALLBERT_HOME",
    "ALLBERT_HOME_DIR",
    "ALLBERT_SETTINGS_ROOT",
    "ALLBERT_SETTINGS_MASTER_KEY"
  ]

  defmodule AppSettingsFixture do
    use AllbertAssist.App

    @impl true
    def app_id, do: :settings_fixture_app

    @impl true
    def display_name, do: "Settings Fixture"

    @impl true
    def version, do: "0.18.0"

    @impl true
    def validate(_opts), do: :ok

    @impl true
    def settings_schema do
      [
        %{
          key: "apps.settings_fixture_app.enabled",
          type: :boolean,
          default: false,
          description: "Enable settings fixture.",
          secret?: false
        }
      ]
    end
  end

  setup do
    original_env = Map.new(@env_vars, &{&1, System.get_env(&1)})
    original_paths_config = Application.get_env(:allbert_assist, Paths)
    original_settings_config = Application.get_env(:allbert_assist, Settings)

    Enum.each(@env_vars, &System.delete_env/1)
    Application.delete_env(:allbert_assist, Paths)
    Application.delete_env(:allbert_assist, Settings)

    home = temp_path("home")
    System.put_env("ALLBERT_HOME", home)

    on_exit(fn ->
      AppRegistry.unregister(:settings_fixture_app)
      PluginRegistry.clear()
      PluginRegistry.register_module(AllbertAssist.Plugins.Telegram)
      PluginRegistry.register_module(AllbertAssist.Plugins.Email)
      File.rm_rf!(home)
      restore_env(original_env)
      restore_app_env(Paths, original_paths_config)
      restore_app_env(Settings, original_settings_config)
    end)

    {:ok, home: home}
  end

  test "root derives from Allbert Home and creates settings folders", %{home: home} do
    assert Settings.root() == Path.join(home, "settings")
    assert Settings.ensure_root!() == Path.join(home, "settings")
    assert File.dir?(Path.join([home, "settings", "audit"]))
  end

  test "missing settings file resolves defaults" do
    assert {:ok, "America/Los_Angeles"} = Settings.get("operator.timezone")
    assert {:ok, resolved} = Settings.explain("operator.timezone")
    assert resolved.source == :default
    assert resolved.writable?
  end

  test "safe write stores only operator override and survives reread", %{home: home} do
    assert {:ok, resolved} =
             Settings.put("operator.communication_style", "detailed", %{
               actor: "local",
               channel: :test
             })

    assert resolved.source == :operator
    assert [%{source: :settings_audit, audit_path: audit_path}] = resolved.diagnostics
    assert {:ok, "detailed"} = Settings.get("operator.communication_style")
    assert File.exists?(audit_path)

    assert {:ok, yaml} = File.read(Path.join([home, "settings", "settings.yml"]))
    assert yaml =~ "communication_style: detailed"
    refute yaml =~ "model_profiles:"

    audit = File.read!(audit_path)
    assert audit =~ "operator.communication_style"
    assert audit =~ "old: concise"
    assert audit =~ "new: detailed"
  end

  test "invalid yaml returns a structured parse error", %{home: home} do
    settings_path = Path.join([home, "settings", "settings.yml"])
    File.mkdir_p!(Path.dirname(settings_path))
    File.write!(settings_path, "operator: [")

    assert {:error, {:settings_parse_failed, _reason}} = Settings.get("operator.timezone")
  end

  test "invalid values and read-only keys are rejected" do
    assert {:error, {:invalid_setting, "operator.communication_style", _reason}} =
             Settings.put("operator.communication_style", "purple", %{})

    assert {:error, {:read_only_setting, "agents.primary_intent.module"}} =
             Settings.put("agents.primary_intent.module", "Other.Module", %{})

    assert {:error, {:unknown_setting, "nope.value"}} =
             Settings.put("nope.value", "x", %{})
  end

  test "skill registry settings are writable and validated", %{home: home} do
    scan_path = Path.join(home, "extra-skills")

    assert {:ok, resolved} =
             Settings.put("skills.scan_paths", [scan_path], %{audit?: false})

    assert resolved.value == [scan_path]
    assert resolved.writable?
    assert {:ok, [^scan_path]} = Settings.get("skills.scan_paths")

    assert {:ok, policy} =
             Settings.put("skills.imported_cache_policy", "enabled_manual_trust", %{audit?: false})

    assert policy.value == "enabled_manual_trust"

    assert {:error, {:invalid_setting, "skills.enabled", _reason}} =
             Settings.put("skills.enabled", ["ok", 123], %{})

    assert {:error, {:invalid_setting, "skills.imported_cache_policy", _reason}} =
             Settings.put("skills.imported_cache_policy", "auto", %{})
  end

  test "plugin settings are writable and validated", %{home: home} do
    assert {:ok, ["./plugins", "<ALLBERT_HOME>/plugins"]} = Settings.get("plugins.scan_paths")
    assert {:ok, "shipped_and_skill_only"} = Settings.get("plugins.load_policy")

    project_plugins = Path.join(home, "plugins")

    assert {:ok, resolved} =
             Settings.put("plugins.scan_paths", [project_plugins], %{audit?: false})

    assert resolved.value == [project_plugins]
    assert {:ok, [^project_plugins]} = Settings.get("plugins.scan_paths")

    assert {:ok, disabled} =
             Settings.put("plugins.disabled", ["example.disabled"], %{audit?: false})

    assert disabled.value == ["example.disabled"]

    assert {:ok, policy} =
             Settings.put("plugins.load_policy", "shipped_only", %{audit?: false})

    assert policy.value == "shipped_only"

    assert {:error, {:invalid_setting, "plugins.load_policy", _reason}} =
             Settings.put("plugins.load_policy", "load_everything", %{})

    assert {:error, {:invalid_setting, "plugins.enabled", _reason}} =
             Settings.put("plugins.enabled", ["ok", 123], %{})
  end

  test "plugin-contributed settings schema participates in Settings Central" do
    PluginRegistry.clear()

    assert {:ok, "example.settings"} =
             PluginRegistry.register_entry(%PluginEntry{
               plugin_id: "example.settings",
               display_name: "Example Settings",
               version: "0.1.0",
               kind: "settings",
               source: :project,
               status: :enabled,
               trust_status: :trusted,
               settings_schema: [
                 %{
                   key: "plugins.example.settings.enabled",
                   type: :boolean,
                   default: false,
                   writable?: true,
                   sensitive?: false
                 },
                 %{
                   key: "plugins.example.settings.mode",
                   type: :enum,
                   default: "safe",
                   writable?: true,
                   sensitive?: false,
                   allowed_values: ["safe", "fast"]
                 }
               ]
             })

    assert {:ok, false} = Settings.get("plugins.example.settings.enabled")
    assert {:ok, "safe"} = Settings.get("plugins.example.settings.mode")
    assert "plugins.example.settings.enabled" in Settings.safe_write_keys()

    assert {:ok, resolved} =
             Settings.put("plugins.example.settings.enabled", true, %{audit?: false})

    assert resolved.value == true
    assert {:ok, true} = Settings.get("plugins.example.settings.enabled")

    assert {:error, {:invalid_setting, "plugins.example.settings.mode", _reason}} =
             Settings.put("plugins.example.settings.mode", "reckless", %{audit?: false})
  end

  test "app-contributed settings schema participates in Settings Central" do
    assert {:ok, :settings_fixture_app} = AppRegistry.register(AppSettingsFixture)

    assert {:ok, false} = Settings.get("apps.settings_fixture_app.enabled")
    assert "apps.settings_fixture_app.enabled" in Settings.safe_write_keys()

    assert {:ok, resolved} =
             Settings.put("apps.settings_fixture_app.enabled", true, %{audit?: false})

    assert resolved.value == true
    assert {:ok, true} = Settings.get("apps.settings_fixture_app.enabled")
  end

  test "confirmation settings are writable and validated" do
    assert {:ok, resolved} =
             Settings.put("confirmations.default_ttl_minutes", 30, %{audit?: false})

    assert resolved.value == 30
    assert {:ok, 30} = Settings.get("confirmations.default_ttl_minutes")

    assert {:ok, approval} =
             Settings.put("confirmations.allow_cross_channel_approval", false, %{audit?: false})

    assert approval.value == false

    assert {:ok, policy} =
             Settings.put("permissions.confirmation_decide", "denied", %{audit?: false})

    assert policy.value == "denied"

    assert {:error, {:invalid_setting, "confirmations.default_ttl_minutes", _reason}} =
             Settings.put("confirmations.default_ttl_minutes", 0, %{})

    assert {:error, {:invalid_setting, "confirmations.allow_cli_approval", _reason}} =
             Settings.put("confirmations.allow_cli_approval", "yes", %{})
  end

  test "session scratchpad ttl setting is writable and bounded" do
    assert {:ok, 30} = Settings.get("sessions.scratchpad_ttl_minutes")

    assert {:ok, resolved} =
             Settings.put("sessions.scratchpad_ttl_minutes", 60, %{audit?: false})

    assert resolved.value == 60
    assert {:ok, 60} = Settings.get("sessions.scratchpad_ttl_minutes")

    assert {:error, {:invalid_setting, "sessions.scratchpad_ttl_minutes", _reason}} =
             Settings.put("sessions.scratchpad_ttl_minutes", 0, %{})

    assert {:error, {:invalid_setting, "sessions.scratchpad_ttl_minutes", _reason}} =
             Settings.put("sessions.scratchpad_ttl_minutes", 1441, %{})
  end

  test "v0.16 channel settings are writable and validated" do
    assert {:ok, false} = Settings.get("channels.telegram.enabled")
    assert {:ok, false} = Settings.get("channels.email.enabled")

    assert Settings.defaults()
           |> get_in(["channels", "telegram", "bot_token_ref"]) ==
             "secret://channels/telegram/bot_token"

    assert {:ok, redacted_ref} = Settings.get("channels.telegram.bot_token_ref")
    assert redacted_ref == "[REDACTED]"

    telegram_map = [
      %{
        "external_user_id" => "123",
        "user_id" => "alice",
        "display_name" => "Alice",
        "enabled" => true
      }
    ]

    assert {:ok, resolved} =
             Settings.put("channels.telegram.identity_map", telegram_map, %{audit?: false})

    assert resolved.value == telegram_map

    assert {:ok, _enabled} =
             Settings.put("channels.telegram.enabled", true, %{audit?: false})

    assert {:ok, _chats} =
             Settings.put("channels.telegram.allowed_chat_ids", ["456"], %{audit?: false})

    assert {:ok, _interval} =
             Settings.put("channels.telegram.poll_interval_ms", 5000, %{audit?: false})

    assert {:error, {:invalid_setting, "channels.telegram.identity_map", _reason}} =
             Settings.put(
               "channels.telegram.identity_map",
               [
                 %{"external_user_id" => "123", "user_id" => "alice"},
                 %{"external_user_id" => "123", "user_id" => "bob"}
               ],
               %{}
             )

    assert {:error, {:invalid_setting, "channels.telegram.poll_timeout_seconds", _reason}} =
             Settings.put("channels.telegram.poll_timeout_seconds", 0, %{})

    assert {:ok, _imap_host} =
             Settings.put("channels.email.imap_host", "imap.example.com", %{audit?: false})

    assert {:ok, _smtp_host} =
             Settings.put("channels.email.smtp_host", "smtp.example.com", %{audit?: false})

    assert {:ok, _imap_user} =
             Settings.put("channels.email.imap_username", "alice", %{audit?: false})

    assert {:ok, _smtp_user} =
             Settings.put("channels.email.smtp_username", "alice", %{audit?: false})

    assert {:ok, _from} =
             Settings.put("channels.email.from_address", "allbert@example.com", %{audit?: false})

    assert {:ok, _enabled} = Settings.put("channels.email.enabled", true, %{audit?: false})

    assert {:error, {:invalid_setting, "channels.email.from_address", _reason}} =
             Settings.put("channels.email.from_address", "not-email", %{})

    assert {:error, {:invalid_setting, "channels.email.imap_ssl", _reason}} =
             Settings.put("channels.email.imap_ssl", false, %{})
  end

  test "skill script execution settings are writable and validated" do
    assert {:ok, policy} =
             Settings.put("permissions.skill_script_execute", "allowed", %{audit?: false})

    assert policy.value == "allowed"

    assert {:ok, enabled} =
             Settings.put("execution.skill_scripts.enabled", true, %{audit?: false})

    assert enabled.value == true

    profile = %{
      "sh" => %{
        "executable" => "/bin/sh",
        "allowed_extensions" => [".sh"],
        "args_prefix" => [],
        "command_class" => "developer",
        "timeout_ms" => 5_000,
        "max_output_bytes" => 4096,
        "require_confirmation" => true
      }
    }

    assert {:ok, profiles} =
             Settings.put("execution.skill_scripts.interpreter_profiles", profile, %{
               audit?: false
             })

    assert profiles.value == profile

    assert {:error, {:invalid_setting, "permissions.skill_script_execute", _reason}} =
             Settings.put("permissions.skill_script_execute", "auto", %{})

    invalid_profile = %{"sh" => %{"executable" => "/bin/sh"}}

    assert {:error, {:invalid_setting, "execution.skill_scripts.interpreter_profiles", _reason}} =
             Settings.put("execution.skill_scripts.interpreter_profiles", invalid_profile, %{})
  end

  test "v0.10 external, package, and online skill settings are writable and validated", %{
    home: home
  } do
    assert {:ok, package_policy} =
             Settings.put("permissions.package_install", "needs_confirmation", %{audit?: false})

    assert package_policy.value == "needs_confirmation"

    assert {:ok, import_policy} =
             Settings.put("permissions.online_skill_import", "denied", %{audit?: false})

    assert import_policy.value == "denied"

    assert {:ok, enabled} =
             Settings.put("external_services.enabled", true, %{audit?: false})

    assert enabled.value == true

    assert {:ok, hosts} =
             Settings.put("external_services.allowed_hosts", ["example.com"], %{audit?: false})

    assert hosts.value == ["example.com"]

    assert {:ok, paths} =
             Settings.put("external_services.allowed_paths", ["/status"], %{audit?: false})

    assert paths.value == ["/status"]

    assert {:ok, methods} =
             Settings.put("external_services.allowed_methods", ["GET", "HEAD"], %{audit?: false})

    assert methods.value == ["GET", "HEAD"]

    external_profile = %{
      "test_echo" => %{
        "enabled" => true,
        "base_url" => "https://example.com",
        "allowed_hosts" => ["example.com"],
        "allowed_paths" => ["/status"],
        "allowed_methods" => ["GET"],
        "default_timeout_ms" => 5_000,
        "max_timeout_ms" => 30_000,
        "max_response_bytes" => 4096,
        "allow_redirects" => false,
        "max_redirects" => 0,
        "retry_policy" => "none",
        "redact_request_headers" => ["authorization"],
        "redact_response_headers" => ["set-cookie"]
      }
    }

    assert {:ok, external_profiles} =
             Settings.put("external_services.profiles", external_profile, %{audit?: false})

    assert external_profiles.value == external_profile

    manager_profile = %{
      "npm" => %{
        "executable" => "npm",
        "install_args" => ["install"],
        "allowed_roots" => [home],
        "timeout_ms" => 30_000,
        "max_output_bytes" => 65_536,
        "require_confirmation" => true,
        "lifecycle_scripts_allowed" => false,
        "git_dependencies_allowed" => false,
        "global_installs_allowed" => false
      }
    }

    assert {:ok, profiles} =
             Settings.put("package_installs.manager_profiles", manager_profile, %{audit?: false})

    assert profiles.value == manager_profile

    assert {:ok, source_enabled} =
             Settings.put("skills.online_import.sources.skills_sh.enabled", true, %{
               audit?: false
             })

    assert source_enabled.value == true

    assert {:ok, max_download} =
             Settings.put("skills.online_import.max_download_bytes", 1_048_576, %{audit?: false})

    assert max_download.value == 1_048_576

    assert {:error, {:invalid_setting, "external_services.allowed_methods", _reason}} =
             Settings.put("external_services.allowed_methods", ["TRACE"], %{})

    assert {:error, {:invalid_setting, "external_services.profiles", _reason}} =
             Settings.put(
               "external_services.profiles",
               %{"bad" => %{"base_url" => "file:///tmp"}},
               %{}
             )

    assert {:error, {:invalid_setting, "package_installs.manager_profiles", _reason}} =
             Settings.put(
               "package_installs.manager_profiles",
               %{"npm" => %{"install_args" => []}},
               %{}
             )

    assert {:error, {:invalid_setting, "skills.online_import.trust_after_import", _reason}} =
             Settings.put("skills.online_import.trust_after_import", "yes", %{})
  end

  test "provider and model profiles resolve with redacted credential status" do
    assert {:ok, providers} = Settings.list_provider_profiles()
    assert Enum.any?(providers, &(&1.name == "openai" and &1.credential_status == :missing))

    assert {:ok, profile} = Settings.resolve_model_profile("fast")
    assert profile.provider == "openai"
    assert profile.credential_status == :missing
    refute Map.has_key?(profile, :api_key)
  end

  test "secret writes encrypt raw value and store only secret ref in settings", %{home: home} do
    assert {:ok, %{status: :configured, diagnostics: [%{audit_path: audit_path}]}} =
             Secrets.put_secret("secret://providers/openai/api_key", "test-key", %{
               actor: "local",
               channel: :test
             })

    assert {:ok, "test-key"} = Secrets.get_secret("secret://providers/openai/api_key")
    assert {:ok, providers} = Settings.list_provider_profiles()
    openai = Enum.find(providers, &(&1.name == "openai"))
    assert openai.credential_status == :configured

    settings_yaml = File.read!(Path.join([home, "settings", "settings.yml"]))
    secrets_yaml = File.read!(Path.join([home, "settings", "secrets.yml.enc"]))

    assert settings_yaml =~ "secret://providers/openai/api_key"
    assert secrets_yaml =~ "aes-256-gcm"
    refute settings_yaml =~ "test-key"
    refute secrets_yaml =~ "test-key"

    audit = File.read!(audit_path)
    assert audit =~ "secret://providers/openai/api_key"
    assert audit =~ "old: missing"
    assert audit =~ "new: configured"
    refute audit =~ "test-key"
  end

  test "channel secret writes encrypt values without provider settings side effects" do
    assert {:ok, %{status: :configured}} =
             Secrets.put_secret("secret://channels/telegram/bot_token", "bot-token", %{
               actor: "local",
               channel: :test
             })

    assert {:ok, "bot-token"} = Secrets.get_secret("secret://channels/telegram/bot_token")
    assert Secrets.status("secret://channels/telegram/bot_token") == :configured

    assert {:ok, statuses} = Secrets.list_secret_status("secret://channels")
    assert [%{secret_ref: "secret://channels/telegram/bot_token", status: :configured}] = statuses
  end

  test "audit write failure is returned as a diagnostic" do
    original_audit_config = Application.get_env(:allbert_assist, AllbertAssist.Settings.Audit)

    Application.put_env(:allbert_assist, AllbertAssist.Settings.Audit,
      writer: fn _path, _body -> {:error, :disk_full} end
    )

    on_exit(fn ->
      restore_app_env(AllbertAssist.Settings.Audit, original_audit_config)
    end)

    assert {:ok, resolved} =
             Settings.put("operator.communication_style", "balanced", %{
               actor: "local",
               channel: :test
             })

    assert [%{source: :settings_audit, error: error}] = resolved.diagnostics
    assert error =~ "disk_full"
  end

  test "bad secret refs and corrupt encrypted payloads return structured errors", %{home: home} do
    assert {:error, {:invalid_secret_ref, "secret://bad"}} =
             Secrets.put_secret("secret://bad", "test-key", %{})

    secrets_path = Path.join([home, "settings", "secrets.yml.enc"])
    File.mkdir_p!(Path.dirname(secrets_path))
    File.write!(secrets_path, "not: valid-envelope\n")

    assert {:error, {:secret_decrypt_failed, _reason}} =
             Secrets.get_secret("secret://providers/openai/api_key")
  end

  test "invalid master key source does not create encrypted file", %{home: home} do
    System.put_env("ALLBERT_SETTINGS_MASTER_KEY", Base.encode64("too-short"))

    assert {:error, {:invalid_settings_master_key, :env}} =
             Secrets.put_secret("secret://providers/openai/api_key", "test-key", %{})

    refute File.exists?(Path.join([home, "settings", "secrets.yml.enc"]))
  end

  test "ALLBERT_SETTINGS_ROOT overrides the derived settings root" do
    settings_root = temp_path("settings")
    System.put_env("ALLBERT_SETTINGS_ROOT", settings_root)

    assert Settings.root() == settings_root
  end

  defp temp_path(name) do
    Path.join(System.tmp_dir!(), "allbert-settings-#{name}-#{System.unique_integer([:positive])}")
  end

  defp restore_env(original_env) do
    Enum.each(original_env, fn
      {key, nil} -> System.delete_env(key)
      {key, value} -> System.put_env(key, value)
    end)
  end

  defp restore_app_env(module, nil), do: Application.delete_env(:allbert_assist, module)
  defp restore_app_env(module, value), do: Application.put_env(:allbert_assist, module, value)
end
