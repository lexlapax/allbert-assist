defmodule AllbertAssist.SettingsTest do
  use ExUnit.Case, async: false

  alias AllbertAssist.App.Registry, as: AppRegistry
  alias AllbertAssist.Paths
  alias AllbertAssist.Plugin.Entry, as: PluginEntry
  alias AllbertAssist.Plugin.Registry, as: PluginRegistry
  alias AllbertAssist.Settings
  alias AllbertAssist.Settings.Fragments
  alias AllbertAssist.Settings.ModelRuntime
  alias AllbertAssist.Settings.ProviderCatalog
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

  test "intent enrichment settings resolve defaults and validate writes" do
    assert {:ok, false} = Settings.get("intent.model_assist_enabled")
    assert {:ok, "local"} = Settings.get("intent.model_profile")
    assert Settings.schema()["intent.model_profile"].default == "local"
    assert {:ok, 3000} = Settings.get("intent.model_timeout_ms")
    assert {:ok, 0.72} = Settings.get("intent.model_min_confidence")
    assert {:ok, 80} = Settings.get("intent.max_candidates")
    assert {:ok, true} = Settings.get("intent.trace_rejected_candidates")
    assert {:ok, true} = Settings.get("intent.descriptors_enabled")
    assert {:ok, 0.6} = Settings.get("intent.handoff_threshold")
    assert {:ok, 0.15} = Settings.get("intent.handoff_margin")
    assert {:ok, 0.3} = Settings.get("intent.clarify_floor")
    assert {:ok, "local"} = Settings.get("intent.direct_answer_model_profile")
    assert Settings.schema()["intent.direct_answer_model_profile"].default == "local"
    assert {:ok, true} = Settings.get("active_memory.enabled")
    assert {:ok, 5} = Settings.get("active_memory.top_k")
    assert {:ok, 2048} = Settings.get("active_memory.chunk_max_bytes")
    assert {:ok, 30} = Settings.get("active_memory.score_weights.recency_half_life_days")
    assert {:ok, 1.0} = Settings.get("active_memory.score_weights.thread_affinity.same_thread")
    assert {:ok, 0.6} = Settings.get("active_memory.score_weights.thread_affinity.same_app")
    assert {:ok, 0.3} = Settings.get("active_memory.score_weights.thread_affinity.general")
    assert {:ok, 1.5} = Settings.get("active_memory.score_weights.identity_inclusion")

    assert {:ok, resolved} =
             Settings.put("intent.max_candidates", 120, %{audit?: false})

    assert resolved.value == 120
    assert {:ok, 120} = Settings.get("intent.max_candidates")

    assert {:ok, resolved} =
             Settings.put("active_memory.score_weights.identity_inclusion", 2.0, %{
               audit?: false
             })

    assert resolved.value == 2.0

    assert {:error, {:invalid_setting, "intent.model_min_confidence", _reason}} =
             Settings.put("intent.model_min_confidence", 1.5, %{audit?: false})

    assert {:error, {:invalid_setting, "intent.handoff_threshold", _reason}} =
             Settings.put("intent.handoff_threshold", 1.5, %{audit?: false})

    assert {:error, {:invalid_setting, "intent.max_candidates", _reason}} =
             Settings.put("intent.max_candidates", 0, %{audit?: false})

    assert {:error, {:invalid_setting, "active_memory.top_k", _reason}} =
             Settings.put("active_memory.top_k", 0, %{audit?: false})

    assert {:error, {:invalid_setting, "active_memory.score_weights.identity_inclusion", _reason}} =
             Settings.put("active_memory.score_weights.identity_inclusion", 0.0, %{
               audit?: false
             })
  end

  test "provider catalog supplies model defaults and generated Jido aliases" do
    assert ProviderCatalog.model_profiles()["anthropic_fast"]["model"] ==
             "claude-haiku-4-5-20251001"

    assert {:ok, "claude-haiku-4-5-20251001"} =
             Settings.get("model_profiles.anthropic_fast.model")

    assert {:ok, ["claude-haiku-4-5"]} =
             Settings.get("model_profiles.anthropic_fast.aliases")

    assert ProviderCatalog.equivalent_model_ids("anthropic", "claude-haiku-4-5") == [
             "claude-haiku-4-5",
             "claude-haiku-4-5-20251001"
           ]

    catalog_aliases = ProviderCatalog.jido_model_aliases()

    assert catalog_aliases.local == "openai:llama3.2:3b"
    assert catalog_aliases.coding_local == "openai:qwen2.5-coder:7b"
    assert catalog_aliases.fast == "openai:gpt-4o-mini"
    assert catalog_aliases.coding == "google:gemini-3.5-flash"
    assert catalog_aliases.anthropic_fast == "anthropic:claude-haiku-4-5-20251001"
    assert catalog_aliases.openrouter_fast == "openrouter:openai/gpt-4o-mini"
    assert catalog_aliases.capable == "anthropic:claude-sonnet-4-6"
    assert catalog_aliases.slow == "anthropic:claude-sonnet-4-6"
    assert catalog_aliases.thinking == "anthropic:claude-opus-4-8"

    assert Application.fetch_env!(:jido_ai, :model_aliases) == catalog_aliases
    assert Jido.AI.resolve_model(:local) == "openai:llama3.2:3b"
    assert Jido.AI.resolve_model(:coding) == "google:gemini-3.5-flash"
    assert Jido.AI.resolve_model(:coding_local) == "openai:qwen2.5-coder:7b"
    assert Jido.AI.resolve_model(:thinking) == "anthropic:claude-opus-4-8"
  end

  test "objective runtime settings resolve defaults and validate writes" do
    assert {:ok, true} = Settings.get("objectives.enabled")
    assert {:ok, 3} = Settings.get("objectives.max_steps_per_turn")
    assert {:ok, 5} = Settings.get("objectives.max_loop_count")
    assert {:ok, "operator"} = Settings.get("objectives.trace_detail")

    assert {:ok, resolved} = Settings.put("objectives.enabled", false, %{audit?: false})
    assert resolved.value == false

    assert {:ok, resolved} = Settings.put("objectives.max_steps_per_turn", 8, %{audit?: false})
    assert resolved.value == 8

    assert {:ok, resolved} = Settings.put("objectives.max_loop_count", 12, %{audit?: false})
    assert resolved.value == 12

    assert {:ok, resolved} = Settings.put("objectives.trace_detail", "debug", %{audit?: false})
    assert resolved.value == "debug"

    assert {:error, {:invalid_setting, "objectives.max_steps_per_turn", _reason}} =
             Settings.put("objectives.max_steps_per_turn", 0, %{audit?: false})

    assert {:error, {:invalid_setting, "objectives.max_loop_count", _reason}} =
             Settings.put("objectives.max_loop_count", 33, %{audit?: false})

    assert {:error, {:invalid_setting, "objectives.trace_detail", _reason}} =
             Settings.put("objectives.trace_detail", "verbose", %{audit?: false})
  end

  test "sandbox settings resolve defaults and validate writes" do
    assert {:ok, false} = Settings.get("sandbox.elixir.enabled")
    assert {:ok, "auto"} = Settings.get("sandbox.elixir.backend")
    assert {:ok, "allbert-elixir-otp:local"} = Settings.get("sandbox.elixir.image")
    assert {:ok, "none"} = Settings.get("sandbox.elixir.network")
    assert {:ok, 1.0} = Settings.get("sandbox.elixir.cpu_limit")
    assert {:ok, 1024} = Settings.get("sandbox.elixir.memory_mb")
    assert {:ok, 120_000} = Settings.get("sandbox.elixir.timeout_ms")
    assert {:ok, 65_536} = Settings.get("sandbox.elixir.output_bytes")
    assert {:ok, "allowed"} = Settings.get("permissions.sandbox_trial")
    assert {:ok, "needs_confirmation"} = Settings.get("permissions.dynamic_integration")
    assert {:ok, "allowed"} = Settings.get("permissions.dynamic_codegen_request")
    assert {:ok, "allowed"} = Settings.get("permissions.dynamic_codegen_discard")

    assert {:ok, enabled} = Settings.put("sandbox.elixir.enabled", true, %{audit?: false})
    assert enabled.value == true

    assert {:ok, backend} =
             Settings.put("sandbox.elixir.backend", "docker_runsc", %{audit?: false})

    assert backend.value == "docker_runsc"

    assert {:ok, image} =
             Settings.put("sandbox.elixir.image", "allbert-elixir-otp@sha256:abc", %{
               audit?: false
             })

    assert image.value == "allbert-elixir-otp@sha256:abc"

    assert {:ok, cpu} = Settings.put("sandbox.elixir.cpu_limit", 2.5, %{audit?: false})
    assert cpu.value == 2.5

    assert {:ok, memory} = Settings.put("sandbox.elixir.memory_mb", 2048, %{audit?: false})
    assert memory.value == 2048

    assert {:ok, timeout} = Settings.put("sandbox.elixir.timeout_ms", 60_000, %{audit?: false})
    assert timeout.value == 60_000

    assert {:ok, output} = Settings.put("sandbox.elixir.output_bytes", 131_072, %{audit?: false})
    assert output.value == 131_072

    assert {:ok, sandbox_trial} =
             Settings.put("permissions.sandbox_trial", "denied", %{audit?: false})

    assert sandbox_trial.value == "denied"

    assert {:error, {:invalid_setting, "sandbox.elixir.backend", _reason}} =
             Settings.put("sandbox.elixir.backend", "firecracker", %{audit?: false})

    assert {:error, {:invalid_setting, "sandbox.elixir.network", _reason}} =
             Settings.put("sandbox.elixir.network", "host", %{audit?: false})

    assert {:error, {:invalid_setting, "sandbox.elixir.cpu_limit", _reason}} =
             Settings.put("sandbox.elixir.cpu_limit", 99.0, %{audit?: false})

    assert {:error, {:invalid_setting, "sandbox.elixir.memory_mb", _reason}} =
             Settings.put("sandbox.elixir.memory_mb", 64, %{audit?: false})

    assert {:error, {:invalid_setting, "permissions.sandbox_trial", _reason}} =
             Settings.put("permissions.sandbox_trial", "needs_confirmation", %{audit?: false})

    assert {:ok, dynamic_integration} =
             Settings.put("permissions.dynamic_integration", "denied", %{audit?: false})

    assert dynamic_integration.value == "denied"

    assert {:error, {:invalid_setting, "permissions.dynamic_integration", _reason}} =
             Settings.put("permissions.dynamic_integration", "allowed", %{audit?: false})

    assert {:ok, dynamic_codegen_request} =
             Settings.put("permissions.dynamic_codegen_request", "denied", %{audit?: false})

    assert dynamic_codegen_request.value == "denied"

    assert {:ok, dynamic_codegen_discard} =
             Settings.put("permissions.dynamic_codegen_discard", "denied", %{audit?: false})

    assert dynamic_codegen_discard.value == "denied"
  end

  test "dynamic codegen settings resolve defaults and validate writes" do
    assert {:ok, false} = Settings.get("dynamic_codegen.enabled")
    assert {:ok, nil} = Settings.get("dynamic_codegen.provider_profile")
    assert {:ok, 2} = Settings.get("dynamic_codegen.max_repair_iterations")
    assert {:ok, 8} = Settings.get("dynamic_codegen.max_provider_calls_per_gap")
    assert {:ok, 20_000} = Settings.get("dynamic_codegen.max_provider_usage_units_per_gap")
    assert {:ok, 32} = Settings.get("dynamic_codegen.max_files")
    assert {:ok, 262_144} = Settings.get("dynamic_codegen.max_bytes")

    assert {:ok, ["action"]} = Settings.get("dynamic_codegen.allowed_targets")

    assert {:ok, ["read_only"]} = Settings.get("dynamic_codegen.allowed_action_permissions")
    assert {:ok, []} = Settings.get("dynamic_codegen.allowed_facades")
    assert {:ok, false} = Settings.get("dynamic_codegen.live_loader_enabled")

    assert {:ok, ["cli", "liveview"]} =
             Settings.get("dynamic_codegen.integration_approval_surfaces")

    assert {:ok, 30} = Settings.get("dynamic_codegen.retention_days")

    assert {:ok, enabled} = Settings.put("dynamic_codegen.enabled", true, %{audit?: false})
    assert enabled.value == true

    assert {:ok, provider_profile} =
             Settings.put("dynamic_codegen.provider_profile", "local", %{audit?: false})

    assert provider_profile.value == "local"

    assert {:ok, surfaces} =
             Settings.put("dynamic_codegen.integration_approval_surfaces", ["cli"], %{
               audit?: false
             })

    assert surfaces.value == ["cli"]

    assert {:ok, action_permissions} =
             Settings.put(
               "dynamic_codegen.allowed_action_permissions",
               ["read_only", "memory_write", "external_network"],
               %{audit?: false}
             )

    assert action_permissions.value == ["read_only", "memory_write", "external_network"]

    assert {:ok, facades} =
             Settings.put(
               "dynamic_codegen.allowed_facades",
               ["append_memory", "external_network_request"],
               %{audit?: false}
             )

    assert facades.value == ["append_memory", "external_network_request"]

    assert {:error, {:invalid_setting, "dynamic_codegen.allowed_action_permissions", _reason}} =
             Settings.put("dynamic_codegen.allowed_action_permissions", ["command_execute"], %{
               audit?: false
             })

    assert {:error, {:invalid_setting, "dynamic_codegen.allowed_facades", _reason}} =
             Settings.put("dynamic_codegen.allowed_facades", ["run_shell_command"], %{
               audit?: false
             })

    assert {:error, {:invalid_setting, "dynamic_codegen.integration_approval_surfaces", _reason}} =
             Settings.put("dynamic_codegen.integration_approval_surfaces", ["telegram"], %{
               audit?: false
             })

    assert {:error, {:invalid_setting, "dynamic_codegen.allowed_targets", _reason}} =
             Settings.put("dynamic_codegen.allowed_targets", ["route"], %{audit?: false})

    assert {:error, {:invalid_setting, "dynamic_codegen.allowed_targets", _reason}} =
             Settings.put("dynamic_codegen.allowed_targets", ["panel"], %{audit?: false})

    assert {:error, {:invalid_setting, "dynamic_codegen.max_files", _reason}} =
             Settings.put("dynamic_codegen.max_files", 0, %{audit?: false})
  end

  test "template creation settings resolve defaults and validate writes" do
    assert {:ok, false} = Settings.get("templates.create.enabled")

    assert {:ok, ["plugin", "app", "llm_tool", "flow", "objective"]} =
             Settings.get("templates.allowed_patterns")

    assert {:ok, enabled} =
             Settings.put("templates.create.enabled", true, %{audit?: false})

    assert enabled.value == true

    assert {:ok, allowed_patterns} =
             Settings.put("templates.allowed_patterns", ["llm_tool", "plugin"], %{
               audit?: false
             })

    assert allowed_patterns.value == ["llm_tool", "plugin"]

    assert {:ok, no_patterns} =
             Settings.put("templates.allowed_patterns", [], %{audit?: false})

    assert no_patterns.value == []

    assert {:error, {:invalid_setting, "templates.allowed_patterns", _reason}} =
             Settings.put("templates.allowed_patterns", ["route_page"], %{audit?: false})

    assert {:error, {:invalid_setting, "templates.allowed_patterns", _reason}} =
             Settings.put("templates.allowed_patterns", "llm_tool", %{audit?: false})
  end

  test "legacy dynamic codegen future-scope settings normalize to shipped scope" do
    assert {:ok, _settings} =
             Settings.write_user_settings(%{
               "dynamic_codegen" => %{
                 "allowed_targets" => ["action", "panel", "settings_fragment"],
                 "allowed_action_permissions" => ["read_only", "memory_write"],
                 "allowed_facades" => [
                   "append_memory",
                   "run_shell_command",
                   "external_network_request"
                 ]
               }
             })

    assert {:ok, ["action"]} = Settings.get("dynamic_codegen.allowed_targets")

    assert {:ok, ["read_only", "memory_write"]} =
             Settings.get("dynamic_codegen.allowed_action_permissions")

    assert {:ok, ["append_memory", "external_network_request"]} =
             Settings.get("dynamic_codegen.allowed_facades")
  end

  test "workspace settings resolve defaults and validate writes" do
    assert {:ok, "system"} = Settings.get("workspace.theme.mode")
    assert {:ok, "system"} = Settings.get("workspace.theme")
    assert {:ok, nil} = Settings.get("workspace.theme.active")
    assert {:ok, false} = Settings.get("workspace.theme.snippets_enabled")
    assert {:ok, []} = Settings.get("workspace.theme.enabled_snippets")
    assert {:ok, false} = Settings.get("workspace.layout.override_enabled")
    assert {:ok, 64} = Settings.get("workspace.canvas.max_tiles_per_thread")
    assert {:ok, 65_536} = Settings.get("workspace.canvas.tile_body_max_bytes")
    assert {:ok, 16} = Settings.get("workspace.ephemeral.max_active_per_thread")
    assert {:ok, "[REDACTED]"} = Settings.get("workspace.fragment.signing_secret")
    assert {:ok, 10} = Settings.get("workspace.fragment.rate_limit_per_second")
    assert {:ok, 10} = Settings.get("workspace.fragment.receiver_rate_limit_per_second")
    assert {:ok, 65_536} = Settings.get("workspace.fragment.payload_max_bytes")
    assert {:ok, true} = Settings.get("workspace.offline.enabled")
    assert {:ok, 32} = Settings.get("workspace.offline.indexeddb_quota_mb")
    assert {:ok, false} = Settings.get("workspace.accessibility.high_contrast")
    assert {:ok, false} = Settings.get("workspace.accessibility.reduce_motion")
    assert {:ok, 768} = Settings.get("workspace.mobile.breakpoint_px")
    assert {:ok, true} = Settings.get("workspace.agui_bridge.enabled")
    assert {:ok, true} = Settings.get("workspace.signal_bridge.log_dropped_fragments")

    assert {:ok, theme} = Settings.put("workspace.theme.mode", "dark", %{audit?: false})
    assert theme.value == "dark"
    assert theme.key == "workspace.theme.mode"

    assert {:ok, legacy_theme} = Settings.put("workspace.theme", "light", %{audit?: false})
    assert legacy_theme.value == "light"
    assert legacy_theme.key == "workspace.theme.mode"

    assert {:ok, active_theme} =
             Settings.put("workspace.theme.active", "midnight", %{audit?: false})

    assert active_theme.value == "midnight"

    assert {:ok, snippets_enabled} =
             Settings.put("workspace.theme.snippets_enabled", true, %{audit?: false})

    assert snippets_enabled.value == true

    assert {:ok, enabled_snippets} =
             Settings.put("workspace.theme.enabled_snippets", ["compact"], %{audit?: false})

    assert enabled_snippets.value == ["compact"]

    assert {:ok, layout_enabled} =
             Settings.put("workspace.layout.override_enabled", true, %{audit?: false})

    assert layout_enabled.value == true

    assert {:ok, max_tiles} =
             Settings.put("workspace.canvas.max_tiles_per_thread", 3, %{audit?: false})

    assert max_tiles.value == 3

    assert {:ok, high_contrast} =
             Settings.put("workspace.accessibility.high_contrast", true, %{audit?: false})

    assert high_contrast.value == true

    assert {:ok, breakpoint} = Settings.explain("workspace.mobile.breakpoint_px")
    refute breakpoint.writable?
    assert Settings.schema()["workspace.mobile.breakpoint_px"].type == :positive_integer
    refute Map.has_key?(Settings.schema()["workspace.mobile.breakpoint_px"], :min)
    refute Map.has_key?(Settings.schema()["workspace.mobile.breakpoint_px"], :max)

    assert {:ok, receiver_rate_limit} =
             Settings.put("workspace.fragment.receiver_rate_limit_per_second", 3, %{
               audit?: false
             })

    assert receiver_rate_limit.value == 3

    assert {:error, {:read_only_setting, "workspace.mobile.breakpoint_px"}} =
             Settings.put("workspace.mobile.breakpoint_px", 640, %{audit?: false})

    assert {:ok, signing_secret} = Settings.explain("workspace.fragment.signing_secret")
    refute signing_secret.writable?
    assert signing_secret.sensitive?
    assert signing_secret.layers == [%{source: :default, value: nil}]

    assert {:error, {:read_only_setting, "workspace.fragment.signing_secret"}} =
             Settings.put("workspace.fragment.signing_secret", String.duplicate("a", 64), %{
               audit?: false
             })

    assert {:error, {:invalid_setting, "workspace.theme.mode", _reason}} =
             Settings.put("workspace.theme.mode", "sepia", %{audit?: false})

    assert {:error, {:invalid_setting, "workspace.canvas.max_tiles_per_thread", _reason}} =
             Settings.put("workspace.canvas.max_tiles_per_thread", 0, %{audit?: false})

    assert {:error, {:read_only_setting, "workspace.mobile.breakpoint_px"}} =
             Settings.put("workspace.mobile.breakpoint_px", 200, %{audit?: false})
  end

  test "legacy workspace.theme stored value is normalized to workspace.theme.mode" do
    assert {:ok, _settings} =
             Settings.write_user_settings(%{
               "workspace" => %{
                 "theme" => "dark"
               }
             })

    assert {:ok, "dark"} = Settings.get("workspace.theme.mode")
    assert {:ok, "dark"} = Settings.get("workspace.theme")

    assert {:ok, settings} = Settings.read_user_settings()
    assert get_in(settings, ["workspace", "theme", "mode"]) == "dark"
  end

  test "core settings schema is assembled from fragments" do
    schema = Settings.schema()
    fragments = Fragments.registered_fragments()
    fragment_schema = Fragments.schema()
    fragment_keys = fragments |> Enum.flat_map(&Map.keys(&1.schema)) |> MapSet.new()

    assert fragment_schema == schema
    assert map_size(fragment_schema) == map_size(schema)
    assert MapSet.new(Map.keys(schema)) == fragment_keys

    workspace = Enum.find(fragments, &(&1.id == "core:workspace"))
    assert workspace.source == :core
    assert Map.has_key?(workspace.schema, "workspace.theme.mode")
    assert "workspace.theme.mode" in workspace.safe_write_keys
    assert "workspace.theme.active" in workspace.safe_write_keys
    assert "workspace.theme.snippets_enabled" in workspace.safe_write_keys
    assert "workspace.theme.enabled_snippets" in workspace.safe_write_keys
    assert "workspace.layout.override_enabled" in workspace.safe_write_keys
    assert get_in(workspace.defaults, ["workspace", "theme", "mode"]) == "system"

    assert {:ok, ^workspace} = Fragments.fragment_for_key("workspace.theme.mode")
  end

  test "memory review settings are writable and validate bounds" do
    assert {:ok, "manual"} = Settings.get("memory.review_cadence")
    assert {:ok, false} = Settings.get("memory.auto_promote_sensitive_entries")
    assert {:ok, "preserve_markdown"} = Settings.get("memory.retention_policy")
    assert {:ok, true} = Settings.get("memory.delete_requires_confirmation")
    assert {:ok, true} = Settings.get("memory.prune_requires_confirmation")
    assert {:ok, true} = Settings.get("memory.promotion_requires_confirmation")
    assert {:ok, 500} = Settings.get("memory.max_entries_per_category")
    assert {:ok, true} = Settings.get("memory.index_enabled")
    assert {:ok, 1000} = Settings.get("memory.max_index_entries")

    assert {:ok, cadence} =
             Settings.put("memory.review_cadence", "weekly", %{audit?: false})

    assert cadence.value == "weekly"

    assert {:ok, retention} =
             Settings.put("memory.retention_policy", "prune_traces_after_30d", %{audit?: false})

    assert retention.value == "prune_traces_after_30d"

    assert {:ok, prune_confirmation} =
             Settings.put("memory.prune_requires_confirmation", false, %{audit?: false})

    assert prune_confirmation.value == false

    assert {:ok, max_entries} =
             Settings.put("memory.max_entries_per_category", 10, %{audit?: false})

    assert max_entries.value == 10

    assert {:error, {:invalid_setting, "memory.review_cadence", _reason}} =
             Settings.put("memory.review_cadence", "hourly", %{audit?: false})

    assert {:error, {:invalid_setting, "memory.max_index_entries", _reason}} =
             Settings.put("memory.max_index_entries", 0, %{audit?: false})
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

    assert {:ok, plugin_fragment} =
             Fragments.fragment_for_key("plugins.example.settings.enabled")

    assert plugin_fragment.id == "plugin:example.settings"
    assert plugin_fragment.source == :plugin
    assert "plugins.example.settings.enabled" in plugin_fragment.safe_write_keys

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

    assert {:ok, app_fragment} = Fragments.fragment_for_key("apps.settings_fixture_app.enabled")
    assert app_fragment.id == "app:settings_fixture_app"
    assert app_fragment.source == :app

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

    assert Enum.any?(
             providers,
             &(&1.name == "local_ollama" and &1.endpoint_kind == "local_endpoint")
           )

    assert Enum.any?(
             providers,
             &(&1.name == "openai" and &1.endpoint_kind == "credentialed_remote" and
                 &1.credential_status == :missing)
           )

    assert Enum.any?(providers, &(&1.name == "anthropic" and &1.credential_status == :missing))
    assert Enum.any?(providers, &(&1.name == "openrouter" and &1.credential_status == :missing))
    assert Enum.any?(providers, &(&1.name == "gemini" and &1.type == "google"))

    assert {:ok, local} = Settings.resolve_model_profile("local")
    assert local.provider == "local_ollama"
    assert local.provider_endpoint_kind == "local_endpoint"
    assert local.model == "llama3.2:3b"

    assert {:ok, profile} = Settings.resolve_model_profile("fast")
    assert profile.provider == "openai"
    assert profile.provider_endpoint_kind == "credentialed_remote"
    assert profile.credential_status == :missing
    refute Map.has_key?(profile, :api_key)

    assert {:ok, anthropic} = Settings.resolve_model_profile("anthropic_fast")
    assert anthropic.provider == "anthropic"
    assert anthropic.provider_type == "anthropic"

    assert {:ok, openrouter} = Settings.resolve_model_profile("openrouter_fast")
    assert openrouter.provider == "openrouter"
    assert openrouter.provider_type == "openrouter"

    assert {:ok, coding} = Settings.resolve_model_profile("coding")
    assert coding.provider == "gemini"
    assert coding.provider_type == "google"
    assert coding.model == "gemini-3.5-flash"
    assert coding.provider_api_key_ref == "secret://providers/gemini/api_key"

    assert {:ok, coding_local} = Settings.resolve_model_profile("coding_local")
    assert coding_local.provider == "local_ollama"
    assert coding_local.model == "qwen2.5-coder:7b"
    assert coding_local.aliases == ["qwen2.5-coder"]

    assert "providers.*.endpoint_kind" in Settings.safe_write_keys()

    assert {:ok, setting} =
             Settings.put("providers.local_ollama.endpoint_kind", "credentialed_remote", %{
               audit?: false
             })

    assert setting.value == "credentialed_remote"
  end

  test "model runtime passes Settings Central credentials as per-request ReqLLM options" do
    assert {:ok, _secret} =
             Secrets.put_secret("secret://providers/gemini/api_key", "AIza-test-runtime-key", %{
               actor: "local",
               channel: :test
             })

    assert {:ok, coding} = Settings.resolve_model_profile("coding")
    assert {:ok, %{provider: :google, id: "gemini-3.5-flash"}} = ModelRuntime.model_spec(coding)
    assert {:ok, "google:gemini-3.5-flash"} = ModelRuntime.model_string(coding)

    opts = ModelRuntime.request_opts(coding)
    assert Keyword.fetch!(opts, :api_key) == "AIza-test-runtime-key"
    refute inspect(opts) =~ "secret://providers/gemini/api_key"
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
