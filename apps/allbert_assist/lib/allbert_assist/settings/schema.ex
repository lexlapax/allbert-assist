defmodule AllbertAssist.Settings.Schema do
  @moduledoc """
  Settings Central schema compatibility facade.

  v0.31 M8 assembles schema, defaults, and safe-write keys from registered
  `AllbertAssist.Settings.Fragment` owners while preserving the pre-M8 public
  API for callers.
  """

  require Logger

  alias AllbertAssist.App.Registry, as: AppRegistry
  alias AllbertAssist.Plugin.Registry, as: PluginRegistry
  alias AllbertAssist.PublicProtocol.ExposureFilter
  alias AllbertAssist.PublicProtocol.TokenAuth
  alias AllbertAssist.Resources.OperationClass
  alias AllbertAssist.Resources.ResourceURI
  alias AllbertAssist.Resources.Scope
  alias AllbertAssist.Settings.Fragments
  alias AllbertAssist.Settings.ProviderCatalog

  @safe_write_keys [
    "operator.display_name",
    "operator.timezone",
    "operator.communication_style",
    "operator.handoff_detail",
    "allbert.jido.debug_trace",
    "objectives.enabled",
    "objectives.max_steps_per_turn",
    "objectives.max_loop_count",
    "objectives.trace_detail",
    "conversations.unified_history.include_e2ee_origin",
    "runtime.trace_default",
    "runtime.diagnostics_verbosity",
    "intent.model_assist_enabled",
    "intent.model_profile",
    "intent.model_timeout_ms",
    "intent.model_min_confidence",
    "intent.max_candidates",
    "intent.trace_rejected_candidates",
    "intent.descriptors_enabled",
    "intent.handoff_threshold",
    "intent.handoff_margin",
    "intent.clarify_floor",
    "intent.direct_answer_model_enabled",
    "intent.direct_answer_model_profile",
    "intent.router_strategy",
    "intent.router_embedding_profile",
    "intent.router_model_profile",
    "intent.router_escalation_profile",
    "intent.router_top_k",
    "intent.router_min_confidence",
    "intent.router_model_timeout_ms",
    "intent.reindex_on_registration_signal",
    "intent.calendar_mcp_server",
    "intent.multiturn_enabled",
    "intent.context_window",
    "intent.disambiguation_margin",
    "intent.pending_clarification_ttl_ms",
    "intent.descriptor_autoaccept",
    "model_preferences.primary",
    "model_preferences.tasks.*",
    "model_preferences.capabilities.*",
    "active_memory.enabled",
    "active_memory.top_k",
    "active_memory.chunk_max_bytes",
    "active_memory.score_weights.recency_half_life_days",
    "active_memory.score_weights.thread_affinity.same_thread",
    "active_memory.score_weights.thread_affinity.same_app",
    "active_memory.score_weights.thread_affinity.general",
    "active_memory.score_weights.identity_inclusion",
    "providers.*.enabled",
    "providers.*.endpoint_kind",
    "providers.*.base_url",
    "providers.*.api_key_ref",
    "mcp.stdio.allowed_launchers",
    "mcp.discovery.enabled",
    "mcp.discovery.sources.official.enabled",
    "mcp.discovery.sources.pulsemcp.enabled",
    "mcp.discovery.sources.pulsemcp.api_key_ref",
    "mcp.discovery.sources.pulsemcp.tenant_ref",
    "mcp.discovery.scan.schedule",
    "mcp.discovery.scan.max_results",
    "mcp.discovery.registry_allowlist",
    "mcp.discovery.registry_denylist",
    "mcp.servers.*.enabled",
    "mcp.servers.*.transport",
    "mcp.servers.*.command",
    "mcp.servers.*.args",
    "mcp.servers.*.env",
    "mcp.servers.*.base_url",
    "mcp.servers.*.headers",
    "mcp.servers.*.auth_ref",
    "mcp.servers.*.tool_allowlist",
    "mcp.servers.*.tool_denylist",
    "mcp.servers.*.confirmation",
    "model_profiles.*.provider",
    "model_profiles.*.model",
    "model_profiles.*.aliases",
    "model_profiles.*.capabilities",
    "model_profiles.*.media",
    "model_profiles.*.temperature",
    "model_profiles.*.max_tokens",
    "model_profiles.*.timeout_ms",
    "skills.scan_paths",
    "skills.trusted_project_roots",
    "skills.enabled",
    "skills.disabled",
    "skills.imported_cache_policy",
    "permissions.memory_write",
    "permissions.command_plan",
    "permissions.command_execute",
    "permissions.external_network",
    "permissions.package_install",
    "permissions.online_skill_import",
    "permissions.settings_write",
    "permissions.skill_write",
    "permissions.dynamic_codegen_request",
    "permissions.dynamic_codegen_discard",
    "permissions.skill_script_execute",
    "permissions.confirmation_decide",
    "permissions.objective_write",
    "permissions.workspace_canvas_write",
    "permissions.sandbox_trial",
    "permissions.dynamic_integration",
    "permissions.stocksage_write",
    "permissions.stocksage_analyze",
    "permissions.stocksage_evidence_fetch",
    "permissions.notes_file_write",
    "permissions.microphone_capture",
    "permissions.voice_transcribe",
    "permissions.voice_synthesize",
    "permissions.voice_local_runtime_manage",
    "permissions.image_input",
    "permissions.image_generate",
    "permissions.artifact_read",
    "permissions.artifact_write",
    "permissions.artifact_delete",
    "permissions.tool_discovery",
    "permissions.mcp_server_connect",
    "permissions.mcp_tool_call",
    "permissions.mcp_resource_read",
    "permissions.public_surface_call_inbound",
    "permissions.channel_message_inbound",
    "mcp_server.schema_version",
    "mcp_server.enabled",
    "mcp_server.stdio.enabled",
    "mcp_server.streamable_http.enabled",
    "mcp_server.streamable_http.bind_host",
    "mcp_server.streamable_http.port",
    "mcp_server.tools_enabled",
    "mcp_server.memory_namespaces_enabled",
    "mcp_server.clients",
    "mcp_server.clients.*.enabled",
    "mcp_server.clients.*.token_ref",
    "mcp_server.clients.*.rate_limit.limit",
    "mcp_server.clients.*.rate_limit.period_ms",
    "mcp_server.clients.*.rate_limit.burst",
    "openai_api.schema_version",
    "openai_api.enabled",
    "openai_api.path_prefix",
    "openai_api.models_enabled",
    "openai_api.tools_enabled",
    "openai_api.memory_namespaces_enabled",
    "openai_api.clients",
    "openai_api.clients.*.enabled",
    "openai_api.clients.*.token_ref",
    "openai_api.clients.*.rate_limit.limit",
    "openai_api.clients.*.rate_limit.period_ms",
    "openai_api.clients.*.rate_limit.burst",
    "public_protocol.schema_version",
    "public_protocol.result_readback_ttl_ms",
    "public_protocol.result_readback_sweep_interval_ms",
    "public_protocol.max_body_bytes",
    "acp_server.schema_version",
    "acp_server.enabled",
    "acp_server.stdio.enabled",
    "acp_server.tools_enabled",
    "acp_server.memory_namespaces_enabled",
    "acp_server.session.load_enabled",
    "acp_server.session.resume_enabled",
    "acp_server.session.additional_directories_enabled",
    "permissions.browser_session_start",
    "permissions.browser_navigate",
    "permissions.browser_extract",
    "permissions.browser_screenshot",
    "permissions.browser_interact",
    "permissions.browser_form_fill",
    "permissions.browser_download",
    "permissions.workflow_read",
    "permissions.workflow_run_start",
    "permissions.plan_cancel",
    "permissions.marketplace_install",
    "permissions.email_send",
    "permissions.channel_message_send",
    "permissions.calendar_write",
    "workflows.enabled",
    "workflows.max_steps_per_workflow",
    "workflows.max_workflows_loaded_per_request",
    "workflows.max_param_bytes_per_step",
    "workflows.max_yaml_bytes_per_file",
    "plan.preview.show_estimated_cost",
    "plan.preview.show_failure_blast_radius",
    "plan.preview.show_confidence_tier",
    "plan.preview.auto_proceed_green_tier",
    "plan.run.cancel_grace_ms",
    "voice.enabled",
    "voice.audio.max_bytes",
    "voice.audio.max_duration_ms",
    "voice.audio.retention_enabled",
    "voice.audio.retention_root",
    "voice.trace.redact_audio",
    "voice.local_runtime.enabled",
    "voice.local_runtime.port",
    "voice.local_runtime.ollama_base_url",
    "voice.local_runtime.ollama_stt_model",
    "voice.local_runtime.stt_model_alias",
    "voice.local_runtime.tts_model_alias",
    "voice.local_runtime.stt_backend",
    "voice.local_runtime.tts_backend",
    "voice.local_runtime.max_text_bytes",
    "vision.enabled",
    "vision.media.max_bytes",
    "vision.media.max_pixels",
    "vision.media.retention_enabled",
    "vision.media.retention_root",
    "vision.trace.redact_images",
    "image.enabled",
    "image.generation.max_bytes",
    "image.generation.max_pixels",
    "image.generation.retention_enabled",
    "image.generation.retention_root",
    "image.trace.redact_images",
    "artifacts.enabled",
    "artifacts.root",
    "artifacts.retention_enabled",
    "artifacts.max_bytes",
    "artifacts.allowed_mime",
    "artifacts.allowed_types",
    "artifacts.gc.enabled",
    "artifacts.gc.delete_orphans",
    "artifacts.trace.redact_bytes",
    "marketplace.enabled",
    "marketplace.catalog.cache_path",
    "marketplace.install.target_dir_skills",
    "marketplace.install.target_dir_templates",
    "marketplace.installed_state_path",
    "self_improvement.enabled",
    "self_improvement.trace_index.enabled",
    "self_improvement.trace_index.max_indexed_entries",
    "self_improvement.trace_index.min_repetitions",
    "self_improvement.suggestions.max_open",
    "self_improvement.suggestions.ttl_days",
    "self_improvement.drafts.max_open",
    "execution.local.enabled",
    "execution.local.allowed_roots",
    "execution.local.allowed_commands",
    "execution.local.command_profiles",
    "execution.local.blocked_arg_patterns",
    "execution.local.require_path_operands_in_allowed_roots",
    "execution.local.default_timeout_ms",
    "execution.local.max_timeout_ms",
    "execution.local.max_output_bytes",
    "execution.local.env_allowlist",
    "execution.local.require_confirmation",
    "execution.skill_scripts.enabled",
    "execution.skill_scripts.require_confirmation",
    "execution.skill_scripts.interpreter_profiles",
    "external_services.enabled",
    "external_services.allowed_hosts",
    "external_services.blocked_hosts",
    "external_services.allowed_paths",
    "external_services.allowed_methods",
    "external_services.default_timeout_ms",
    "external_services.max_timeout_ms",
    "external_services.max_response_bytes",
    "external_services.allow_redirects",
    "external_services.max_redirects",
    "external_services.retry_policy",
    "external_services.redact_request_headers",
    "external_services.redact_response_headers",
    "external_services.profiles",
    "package_installs.enabled",
    "package_installs.require_confirmation",
    "package_installs.allowed_roots",
    "package_installs.allowed_managers",
    "package_installs.default_timeout_ms",
    "package_installs.max_timeout_ms",
    "package_installs.max_output_bytes",
    "package_installs.lifecycle_scripts_allowed",
    "package_installs.git_dependencies_allowed",
    "package_installs.global_installs_allowed",
    "package_installs.manager_profiles",
    "sandbox.elixir.enabled",
    "sandbox.elixir.backend",
    "sandbox.elixir.image",
    "sandbox.elixir.network",
    "sandbox.elixir.cpu_limit",
    "sandbox.elixir.memory_mb",
    "sandbox.elixir.timeout_ms",
    "sandbox.elixir.output_bytes",
    "dynamic_codegen.enabled",
    "dynamic_codegen.provider_profile",
    "dynamic_codegen.max_repair_iterations",
    "dynamic_codegen.max_provider_calls_per_gap",
    "dynamic_codegen.max_provider_usage_units_per_gap",
    "dynamic_codegen.max_files",
    "dynamic_codegen.max_bytes",
    "dynamic_codegen.allowed_targets",
    "dynamic_codegen.allowed_action_permissions",
    "dynamic_codegen.allowed_facades",
    "dynamic_codegen.live_loader_enabled",
    "dynamic_codegen.integration_approval_surfaces",
    "dynamic_codegen.retention_days",
    "templates.create.enabled",
    "templates.allowed_patterns",
    "resource_grants.remembered",
    "skills.online_import.enabled",
    "skills.online_import.require_confirmation",
    "skills.online_import.allowed_sources",
    "skills.online_import.max_listing_results",
    "skills.online_import.max_download_bytes",
    "skills.online_import.trust_after_import",
    "skills.online_import.sources.skills_sh.enabled",
    "skills.online_import.sources.skills_sh.base_url",
    "skills.online_import.sources.skills_sh.api_url",
    "skills.online_import.sources.skills_sh.cache_ttl_seconds",
    "plugins.enabled",
    "plugins.disabled",
    "plugins.scan_paths",
    "plugins.trusted_project_roots",
    "plugins.load_policy",
    "plugins.registration_enabled",
    "app_registry.registration_enabled",
    "confirmations.default_ttl_minutes",
    "confirmations.auto_expire_on_startup",
    "confirmations.require_reason_for_denial",
    "confirmations.show_redacted_params",
    "confirmations.allow_cli_approval",
    "confirmations.allow_liveview_approval",
    "confirmations.allow_cross_channel_approval",
    "jobs.timezone",
    "jobs.default_state",
    "jobs.schedule_policy",
    "sessions.scratchpad_ttl_minutes",
    "channels.cli.response_style",
    "channels.live_view.response_style",
    "channels.telegram.enabled",
    "channels.telegram.response_style",
    "channels.telegram.bot_token_ref",
    "channels.telegram.identity_map",
    "channels.telegram.allowed_chat_ids",
    "channels.telegram.allow_group_chats",
    "channels.telegram.poll_interval_ms",
    "channels.telegram.poll_timeout_seconds",
    "channels.telegram.max_text_bytes",
    "channels.telegram.render_approval_buttons",
    "channels.telegram.allow_confirmation_callbacks",
    "channels.email.enabled",
    "channels.email.response_style",
    "channels.email.imap_host",
    "channels.email.imap_port",
    "channels.email.imap_ssl",
    "channels.email.imap_username",
    "channels.email.imap_password_ref",
    "channels.email.imap_mailbox",
    "channels.email.imap_poll_interval_ms",
    "channels.email.smtp_host",
    "channels.email.smtp_port",
    "channels.email.smtp_tls",
    "channels.email.smtp_username",
    "channels.email.smtp_password_ref",
    "channels.email.from_address",
    "channels.email.from_name",
    "channels.email.identity_map",
    "channels.email.max_body_bytes",
    "channels.email.allow_html_replies",
    "channels.whatsapp.webhook_enabled",
    "channels.whatsapp.phone_number_id",
    "channels.whatsapp.waba_id",
    "channels.whatsapp.app_secret_ref",
    "channels.whatsapp.webhook_verify_token_ref",
    "channels.whatsapp.webhook_rate_limit.limit",
    "channels.whatsapp.webhook_rate_limit.period_ms",
    "channels.whatsapp.webhook_rate_limit.burst",
    "memory.review_cadence",
    "memory.auto_promote_sensitive_entries",
    "memory.retention_policy",
    "memory.delete_requires_confirmation",
    "memory.prune_requires_confirmation",
    "memory.promotion_requires_confirmation",
    "memory.max_entries_per_category",
    "memory.index_enabled",
    "memory.max_index_entries",
    "workspace.theme.mode",
    "workspace.theme.active",
    "workspace.theme.snippets_enabled",
    "workspace.theme.enabled_snippets",
    "workspace.layout.override_enabled",
    "workspace.canvas.max_tiles_per_thread",
    "workspace.canvas.tile_body_max_bytes",
    "workspace.ephemeral.max_active_per_thread",
    "workspace.fragment.emission_enabled",
    "workspace.fragment.rate_limit_per_second",
    "workspace.fragment.receiver_rate_limit_per_second",
    "workspace.fragment.payload_max_bytes",
    "workspace.offline.enabled",
    "workspace.offline.indexeddb_quota_mb",
    "workspace.accessibility.high_contrast",
    "workspace.accessibility.reduce_motion",
    "workspace.agui_bridge.enabled",
    "workspace.signal_bridge.log_dropped_fragments"
  ]

  @resource_grant_required_keys ~w[
    id
    resource_uri
    origin_kind
    scope
    operation_class
    access_mode
    created_at
  ]

  @resource_grant_allowed_keys ~w[
    id
    resource_uri
    origin_kind
    scope
    operation_class
    access_mode
    downstream_consumer
    action_permission
    origin_channel
    resolver_channel
    created_at
    expires_at
    revoked_at
    audit_path
    reason
    metadata
  ]

  @resource_grant_atom_keys Map.new(@resource_grant_allowed_keys, &{&1, String.to_atom(&1)})

  @schema %{
    "operator.display_name" => %{
      type: :string,
      default: "local",
      writable?: true,
      sensitive?: false
    },
    "operator.timezone" => %{
      type: :timezone,
      default: "America/Los_Angeles",
      writable?: true,
      sensitive?: false
    },
    "operator.communication_style" => %{
      type: :enum,
      default: "concise",
      writable?: true,
      sensitive?: false,
      allowed_values: ["concise", "balanced", "detailed"]
    },
    "operator.handoff_detail" => %{
      type: :enum,
      default: "concrete_next_steps",
      writable?: true,
      sensitive?: false,
      allowed_values: ["brief", "concrete_next_steps", "full_context"]
    },
    "allbert.jido.debug_trace" => %{
      type: :boolean,
      default: false,
      writable?: true,
      sensitive?: false
    },
    "objectives.enabled" => %{
      type: :boolean,
      default: true,
      writable?: true,
      sensitive?: false
    },
    "objectives.max_steps_per_turn" => %{
      type: :bounded_integer,
      default: 3,
      writable?: true,
      sensitive?: false,
      min: 1,
      max: 16
    },
    "objectives.max_loop_count" => %{
      type: :bounded_integer,
      default: 5,
      writable?: true,
      sensitive?: false,
      min: 1,
      max: 32
    },
    "objectives.trace_detail" => %{
      type: :enum,
      default: "operator",
      writable?: true,
      sensitive?: false,
      allowed_values: ["operator", "debug"]
    },
    "conversations.unified_history.include_e2ee_origin" => %{
      type: :boolean,
      default: false,
      writable?: true,
      sensitive?: false
    },
    "runtime.trace_default" => %{
      type: :enum,
      default: "disabled",
      writable?: true,
      sensitive?: false,
      allowed_values: ["disabled", "enabled", "denied_only"]
    },
    "runtime.diagnostics_verbosity" => %{
      type: :enum,
      default: "normal",
      writable?: true,
      sensitive?: false,
      allowed_values: ["quiet", "normal", "verbose"]
    },
    "runtime.model_alias" => %{
      type: :profile_ref,
      default: "local",
      writable?: false,
      sensitive?: false
    },
    "runtime.cost_visibility" => %{
      type: :enum,
      default: "summary",
      writable?: false,
      sensitive?: false,
      allowed_values: ["hidden", "summary", "detailed"]
    },
    "intent.model_assist_enabled" => %{
      type: :boolean,
      default: false,
      writable?: true,
      sensitive?: false
    },
    "intent.model_profile" => %{
      type: :profile_ref,
      default: "local",
      writable?: true,
      sensitive?: false
    },
    "intent.model_timeout_ms" => %{
      type: :timeout_ms,
      default: 3000,
      writable?: true,
      sensitive?: false
    },
    "intent.model_min_confidence" => %{
      type: :bounded_float,
      default: 0.72,
      writable?: true,
      sensitive?: false,
      min: 0.0,
      max: 1.0
    },
    "intent.max_candidates" => %{
      type: :bounded_integer,
      default: 80,
      writable?: true,
      sensitive?: false,
      min: 1,
      max: 500
    },
    "intent.trace_rejected_candidates" => %{
      type: :boolean,
      default: true,
      writable?: true,
      sensitive?: false
    },
    "intent.descriptors_enabled" => %{
      type: :boolean,
      default: true,
      writable?: true,
      sensitive?: false
    },
    "intent.handoff_threshold" => %{
      type: :bounded_float,
      default: 0.6,
      writable?: true,
      sensitive?: false,
      min: 0.0,
      max: 1.0
    },
    "intent.handoff_margin" => %{
      type: :bounded_float,
      default: 0.15,
      writable?: true,
      sensitive?: false,
      min: 0.0,
      max: 1.0
    },
    "intent.clarify_floor" => %{
      type: :bounded_float,
      default: 0.3,
      writable?: true,
      sensitive?: false,
      min: 0.0,
      max: 1.0
    },
    "intent.direct_answer_model_enabled" => %{
      type: :boolean,
      default: false,
      writable?: true,
      sensitive?: false
    },
    "intent.direct_answer_model_profile" => %{
      type: :profile_ref,
      default: "local",
      writable?: true,
      sensitive?: false
    },
    "intent.router_strategy" => %{
      type: :enum,
      default: "two_stage_local",
      writable?: true,
      sensitive?: false,
      allowed_values: ["deterministic", "two_stage_local"]
    },
    "intent.router_embedding_profile" => %{
      type: :profile_ref,
      default: "embedding_local",
      writable?: true,
      sensitive?: false
    },
    "intent.router_model_profile" => %{
      type: :profile_ref,
      default: "router_local",
      writable?: true,
      sensitive?: false
    },
    "intent.router_escalation_profile" => %{
      type: :string_or_empty,
      default: "router_escalation_local",
      writable?: true,
      sensitive?: false
    },
    "intent.router_top_k" => %{
      type: :bounded_integer,
      default: 5,
      writable?: true,
      sensitive?: false,
      min: 1,
      max: 20
    },
    "intent.router_min_confidence" => %{
      type: :bounded_float,
      default: 0.6,
      writable?: true,
      sensitive?: false,
      min: 0.0,
      max: 1.0
    },
    "intent.router_model_timeout_ms" => %{
      type: :bounded_integer,
      default: 20_000,
      writable?: true,
      sensitive?: false,
      min: 250,
      max: 60_000
    },
    "intent.reindex_on_registration_signal" => %{
      type: :boolean,
      default: true,
      writable?: true,
      sensitive?: false
    },
    "intent.calendar_mcp_server" => %{
      type: :string_or_empty,
      default: "calendar",
      writable?: true,
      sensitive?: false
    },
    "intent.multiturn_enabled" => %{
      type: :boolean,
      default: false,
      writable?: true,
      sensitive?: false
    },
    "intent.descriptor_autoaccept" => %{
      type: :boolean,
      default: false,
      writable?: true,
      sensitive?: false
    },
    "intent.context_window" => %{
      type: :bounded_integer,
      default: 6,
      writable?: true,
      sensitive?: false,
      min: 0,
      max: 24
    },
    "intent.disambiguation_margin" => %{
      type: :bounded_float,
      default: 0.12,
      writable?: true,
      sensitive?: false,
      min: 0.0,
      max: 1.0
    },
    "intent.pending_clarification_ttl_ms" => %{
      type: :bounded_integer,
      default: 120_000,
      writable?: true,
      sensitive?: false,
      min: 1000,
      max: 3_600_000
    },
    "model_preferences.schema_version" => %{
      type: :bounded_integer,
      default: 1,
      writable?: false,
      sensitive?: false,
      min: 1,
      max: 1
    },
    "model_preferences.primary" => %{
      type: :profile_ref,
      default: "local",
      writable?: true,
      sensitive?: false
    },
    "active_memory.enabled" => %{
      type: :boolean,
      default: true,
      writable?: true,
      sensitive?: false
    },
    "active_memory.top_k" => %{
      type: :bounded_integer,
      default: 5,
      writable?: true,
      sensitive?: false,
      min: 1,
      max: 20
    },
    "active_memory.chunk_max_bytes" => %{
      type: :bounded_integer,
      default: 2048,
      writable?: true,
      sensitive?: false,
      min: 128,
      max: 8192
    },
    "active_memory.score_weights.recency_half_life_days" => %{
      type: :bounded_integer,
      default: 30,
      writable?: true,
      sensitive?: false,
      min: 1,
      max: 3650
    },
    "active_memory.score_weights.thread_affinity.same_thread" => %{
      type: :bounded_float,
      default: 1.0,
      writable?: true,
      sensitive?: false,
      min: 0.000001,
      max: 10.0
    },
    "active_memory.score_weights.thread_affinity.same_app" => %{
      type: :bounded_float,
      default: 0.6,
      writable?: true,
      sensitive?: false,
      min: 0.000001,
      max: 10.0
    },
    "active_memory.score_weights.thread_affinity.general" => %{
      type: :bounded_float,
      default: 0.3,
      writable?: true,
      sensitive?: false,
      min: 0.000001,
      max: 10.0
    },
    "active_memory.score_weights.identity_inclusion" => %{
      type: :bounded_float,
      default: 1.5,
      writable?: true,
      sensitive?: false,
      min: 0.000001,
      max: 10.0
    },
    "channels.cli.response_style" => %{
      type: :enum,
      default: "concise",
      writable?: true,
      sensitive?: false,
      allowed_values: ["concise", "balanced", "detailed"]
    },
    "channels.live_view.response_style" => %{
      type: :enum,
      default: "concise",
      writable?: true,
      sensitive?: false,
      allowed_values: ["concise", "balanced", "detailed"]
    },
    "channels.telegram.enabled" => %{
      type: :boolean,
      default: false,
      writable?: true,
      sensitive?: false
    },
    "channels.telegram.response_style" => %{
      type: :enum,
      default: "concise",
      writable?: true,
      sensitive?: false,
      allowed_values: ["concise", "balanced", "detailed"]
    },
    "channels.telegram.bot_token_ref" => %{
      type: :channel_secret_ref,
      default: "secret://channels/telegram/bot_token",
      writable?: true,
      sensitive?: true
    },
    "channels.telegram.identity_map" => %{
      type: :channel_identity_map,
      default: [],
      writable?: true,
      sensitive?: false
    },
    "channels.telegram.allowed_chat_ids" => %{
      type: :string_list,
      default: [],
      writable?: true,
      sensitive?: false
    },
    "channels.telegram.allow_group_chats" => %{
      type: :boolean,
      default: false,
      writable?: true,
      sensitive?: false
    },
    "channels.telegram.poll_interval_ms" => %{
      type: :bounded_integer,
      default: 2000,
      writable?: true,
      sensitive?: false,
      min: 250,
      max: 60_000
    },
    "channels.telegram.poll_timeout_seconds" => %{
      type: :bounded_integer,
      default: 25,
      writable?: true,
      sensitive?: false,
      min: 1,
      max: 50
    },
    "channels.telegram.max_text_bytes" => %{
      type: :bounded_integer,
      default: 4096,
      writable?: true,
      sensitive?: false,
      min: 1,
      max: 65_536
    },
    "channels.telegram.render_approval_buttons" => %{
      type: :boolean,
      default: true,
      writable?: true,
      sensitive?: false
    },
    "channels.telegram.allow_confirmation_callbacks" => %{
      type: :boolean,
      default: true,
      writable?: true,
      sensitive?: false
    },
    "channels.email.enabled" => %{
      type: :boolean,
      default: false,
      writable?: true,
      sensitive?: false
    },
    "channels.email.response_style" => %{
      type: :enum,
      default: "standard",
      writable?: true,
      sensitive?: false,
      allowed_values: ["standard", "concise", "detailed"]
    },
    "channels.email.imap_host" => %{
      type: :string_or_empty,
      default: "",
      writable?: true,
      sensitive?: false
    },
    "channels.email.imap_port" => %{
      type: :bounded_integer,
      default: 993,
      writable?: true,
      sensitive?: false,
      min: 1,
      max: 65_535
    },
    "channels.email.imap_ssl" => %{
      type: :boolean,
      default: true,
      writable?: true,
      sensitive?: false
    },
    "channels.email.imap_username" => %{
      type: :string_or_empty,
      default: "",
      writable?: true,
      sensitive?: false
    },
    "channels.email.imap_password_ref" => %{
      type: :channel_secret_ref,
      default: "secret://channels/email/imap_password",
      writable?: true,
      sensitive?: true
    },
    "channels.email.imap_mailbox" => %{
      type: :string,
      default: "INBOX",
      writable?: true,
      sensitive?: false
    },
    "channels.email.imap_poll_interval_ms" => %{
      type: :bounded_integer,
      default: 60_000,
      writable?: true,
      sensitive?: false,
      min: 1000,
      max: 3_600_000
    },
    "channels.email.smtp_host" => %{
      type: :string_or_empty,
      default: "",
      writable?: true,
      sensitive?: false
    },
    "channels.email.smtp_port" => %{
      type: :bounded_integer,
      default: 587,
      writable?: true,
      sensitive?: false,
      min: 1,
      max: 65_535
    },
    "channels.email.smtp_tls" => %{
      type: :boolean,
      default: true,
      writable?: true,
      sensitive?: false
    },
    "channels.email.smtp_username" => %{
      type: :string_or_empty,
      default: "",
      writable?: true,
      sensitive?: false
    },
    "channels.email.smtp_password_ref" => %{
      type: :channel_secret_ref,
      default: "secret://channels/email/smtp_password",
      writable?: true,
      sensitive?: true
    },
    "channels.email.from_address" => %{
      type: :email_or_empty,
      default: "",
      writable?: true,
      sensitive?: false
    },
    "channels.email.from_name" => %{
      type: :string,
      default: "Allbert",
      writable?: true,
      sensitive?: false
    },
    "channels.email.identity_map" => %{
      type: :channel_identity_map,
      default: [],
      writable?: true,
      sensitive?: false
    },
    "channels.email.max_body_bytes" => %{
      type: :bounded_integer,
      default: 65_536,
      writable?: true,
      sensitive?: false,
      min: 1,
      max: 1_048_576
    },
    "channels.email.allow_html_replies" => %{
      type: :boolean,
      default: false,
      writable?: true,
      sensitive?: false
    },
    "channels.whatsapp.webhook_enabled" => %{
      type: :boolean,
      default: false,
      writable?: true,
      sensitive?: false
    },
    "channels.whatsapp.phone_number_id" => %{
      type: :string_or_empty,
      default: "",
      writable?: true,
      sensitive?: false
    },
    "channels.whatsapp.waba_id" => %{
      type: :string_or_empty,
      default: "",
      writable?: true,
      sensitive?: false
    },
    "channels.whatsapp.app_secret_ref" => %{
      type: :channel_secret_ref,
      default: "secret://channels/whatsapp/app_secret",
      writable?: true,
      sensitive?: true
    },
    "channels.whatsapp.webhook_verify_token_ref" => %{
      type: :channel_secret_ref,
      default: "secret://channels/whatsapp/webhook_verify_token",
      writable?: true,
      sensitive?: true
    },
    "channels.whatsapp.webhook_rate_limit.limit" => %{
      type: :bounded_integer,
      default: 60,
      writable?: true,
      sensitive?: false,
      min: 1,
      max: 10_000
    },
    "channels.whatsapp.webhook_rate_limit.period_ms" => %{
      type: :bounded_integer,
      default: 60_000,
      writable?: true,
      sensitive?: false,
      min: 100,
      max: 86_400_000
    },
    "channels.whatsapp.webhook_rate_limit.burst" => %{
      type: :bounded_integer,
      default: 10,
      writable?: true,
      sensitive?: false,
      min: 0,
      max: 10_000
    },
    "skills.scan_paths" => %{
      type: :string_list,
      default: [],
      writable?: true,
      sensitive?: false
    },
    "skills.trusted_project_roots" => %{
      type: :string_list,
      default: [],
      writable?: true,
      sensitive?: false
    },
    "skills.enabled" => %{
      type: :string_list,
      default: [],
      writable?: true,
      sensitive?: false
    },
    "skills.disabled" => %{
      type: :string_list,
      default: [],
      writable?: true,
      sensitive?: false
    },
    "skills.imported_cache_policy" => %{
      type: :enum,
      default: "disabled",
      writable?: true,
      sensitive?: false,
      allowed_values: ["disabled", "enabled_manual_trust"]
    },
    "skills.online_import.enabled" => %{
      type: :boolean,
      default: false,
      writable?: true,
      sensitive?: false
    },
    "skills.online_import.require_confirmation" => %{
      type: :boolean,
      default: true,
      writable?: true,
      sensitive?: false
    },
    "skills.online_import.allowed_sources" => %{
      type: :string_list,
      default: ["skills_sh"],
      writable?: true,
      sensitive?: false
    },
    "skills.online_import.max_listing_results" => %{
      type: :positive_integer,
      default: 25,
      writable?: true,
      sensitive?: false
    },
    "skills.online_import.max_download_bytes" => %{
      type: :positive_integer,
      default: 1_048_576,
      writable?: true,
      sensitive?: false
    },
    "skills.online_import.trust_after_import" => %{
      type: :boolean,
      default: false,
      writable?: true,
      sensitive?: false
    },
    "skills.online_import.sources.skills_sh.enabled" => %{
      type: :boolean,
      default: false,
      writable?: true,
      sensitive?: false
    },
    "skills.online_import.sources.skills_sh.base_url" => %{
      type: :url_or_nil,
      default: "https://skills.sh",
      writable?: true,
      sensitive?: false
    },
    "skills.online_import.sources.skills_sh.api_url" => %{
      type: :url_or_nil,
      default: "https://skills.sh/api",
      writable?: true,
      sensitive?: false
    },
    "skills.online_import.sources.skills_sh.cache_ttl_seconds" => %{
      type: :positive_integer,
      default: 3600,
      writable?: true,
      sensitive?: false
    },
    "plugins.enabled" => %{
      type: :string_list,
      default: [],
      writable?: true,
      sensitive?: false
    },
    "plugins.disabled" => %{
      type: :string_list,
      default: [],
      writable?: true,
      sensitive?: false
    },
    "plugins.scan_paths" => %{
      type: :string_list,
      default: ["./plugins", "<ALLBERT_HOME>/plugins"],
      writable?: true,
      sensitive?: false
    },
    "plugins.trusted_project_roots" => %{
      type: :string_list,
      default: [],
      writable?: true,
      sensitive?: false
    },
    "plugins.load_policy" => %{
      type: :enum,
      default: "shipped_and_skill_only",
      writable?: true,
      sensitive?: false,
      allowed_values: ["shipped_and_skill_only", "shipped_only"]
    },
    "plugins.registration_enabled" => %{
      type: :boolean,
      default: true,
      writable?: true,
      sensitive?: false
    },
    "app_registry.registration_enabled" => %{
      type: :boolean,
      default: true,
      writable?: true,
      sensitive?: false
    },
    "mcp_server.schema_version" => %{
      type: :bounded_integer,
      default: 1,
      writable?: true,
      sensitive?: false,
      min: 1,
      max: 1
    },
    "mcp_server.enabled" => %{
      type: :boolean,
      default: false,
      writable?: true,
      sensitive?: false
    },
    "mcp_server.stdio.enabled" => %{
      type: :boolean,
      default: false,
      writable?: true,
      sensitive?: false
    },
    "mcp_server.streamable_http.enabled" => %{
      type: :boolean,
      default: false,
      writable?: true,
      sensitive?: false
    },
    "mcp_server.streamable_http.bind_host" => %{
      type: :loopback_bind_host,
      default: "127.0.0.1",
      writable?: true,
      sensitive?: false
    },
    "mcp_server.streamable_http.port" => %{
      type: :port_or_nil,
      default: nil,
      writable?: true,
      sensitive?: false
    },
    "mcp_server.tools_enabled" => %{
      type: :public_tool_list,
      default: [],
      writable?: true,
      sensitive?: false
    },
    "mcp_server.memory_namespaces_enabled" => %{
      type: :public_memory_namespace_list,
      default: [],
      writable?: true,
      sensitive?: false
    },
    "mcp_server.clients" => %{
      type: :public_protocol_clients,
      default: %{},
      writable?: true,
      sensitive?: true,
      surface: "mcp_http"
    },
    "openai_api.schema_version" => %{
      type: :bounded_integer,
      default: 1,
      writable?: true,
      sensitive?: false,
      min: 1,
      max: 1
    },
    "openai_api.enabled" => %{
      type: :boolean,
      default: false,
      writable?: true,
      sensitive?: false
    },
    "openai_api.path_prefix" => %{
      type: :public_api_path_prefix,
      default: "/v1",
      writable?: true,
      sensitive?: false
    },
    "openai_api.models_enabled" => %{
      type: :profile_ref_list,
      default: [],
      writable?: true,
      sensitive?: false
    },
    "openai_api.tools_enabled" => %{
      type: :public_tool_list,
      default: [],
      writable?: true,
      sensitive?: false
    },
    "openai_api.memory_namespaces_enabled" => %{
      type: :public_memory_namespace_list,
      default: [],
      writable?: true,
      sensitive?: false
    },
    "openai_api.clients" => %{
      type: :public_protocol_clients,
      default: %{},
      writable?: true,
      sensitive?: true,
      surface: "openai_api"
    },
    "public_protocol.schema_version" => %{
      type: :bounded_integer,
      default: 1,
      writable?: true,
      sensitive?: false,
      min: 1,
      max: 1
    },
    "public_protocol.result_readback_ttl_ms" => %{
      type: :bounded_integer,
      default: 3_600_000,
      writable?: true,
      sensitive?: false,
      min: 60_000,
      max: 86_400_000
    },
    "public_protocol.result_readback_sweep_interval_ms" => %{
      type: :bounded_integer,
      default: 60_000,
      writable?: true,
      sensitive?: false,
      min: 1_000,
      max: 86_400_000
    },
    "public_protocol.max_body_bytes" => %{
      type: :bounded_integer,
      default: 1_048_576,
      writable?: true,
      sensitive?: false,
      min: 1024,
      max: 10_485_760
    },
    "acp_server.schema_version" => %{
      type: :bounded_integer,
      default: 1,
      writable?: true,
      sensitive?: false,
      min: 1,
      max: 1
    },
    "acp_server.enabled" => %{
      type: :boolean,
      default: false,
      writable?: true,
      sensitive?: false
    },
    "acp_server.stdio.enabled" => %{
      type: :boolean,
      default: false,
      writable?: true,
      sensitive?: false
    },
    "acp_server.tools_enabled" => %{
      type: :public_tool_list,
      default: [],
      writable?: true,
      sensitive?: false
    },
    "acp_server.memory_namespaces_enabled" => %{
      type: :public_memory_namespace_list,
      default: [],
      writable?: true,
      sensitive?: false
    },
    "acp_server.session.load_enabled" => %{
      type: :boolean,
      default: false,
      writable?: true,
      sensitive?: false
    },
    "acp_server.session.resume_enabled" => %{
      type: :boolean,
      default: false,
      writable?: true,
      sensitive?: false
    },
    "acp_server.session.additional_directories_enabled" => %{
      type: :boolean,
      default: false,
      writable?: true,
      sensitive?: false
    },
    "workspace.theme.mode" => %{
      type: :enum,
      default: "system",
      writable?: true,
      sensitive?: false,
      allowed_values: ["light", "dark", "system"]
    },
    "workspace.theme.active" => %{
      type: :string_or_nil,
      default: nil,
      writable?: true,
      sensitive?: false
    },
    "workspace.theme.snippets_enabled" => %{
      type: :boolean,
      default: false,
      writable?: true,
      sensitive?: false
    },
    "workspace.theme.enabled_snippets" => %{
      type: :string_list,
      default: [],
      writable?: true,
      sensitive?: false
    },
    "workspace.layout.override_enabled" => %{
      type: :boolean,
      default: false,
      writable?: true,
      sensitive?: false
    },
    "workspace.canvas.max_tiles_per_thread" => %{
      type: :bounded_integer,
      default: 64,
      writable?: true,
      sensitive?: false,
      min: 1,
      max: 256
    },
    "workspace.canvas.tile_body_max_bytes" => %{
      type: :bounded_integer,
      default: 65_536,
      writable?: true,
      sensitive?: false,
      min: 1024,
      max: 262_144
    },
    "workspace.ephemeral.max_active_per_thread" => %{
      type: :bounded_integer,
      default: 16,
      writable?: true,
      sensitive?: false,
      min: 1,
      max: 64
    },
    "workspace.fragment.signing_secret" => %{
      type: :hex_secret_or_nil,
      default: nil,
      writable?: false,
      sensitive?: true
    },
    "workspace.fragment.emission_enabled" => %{
      type: :boolean,
      default: true,
      writable?: true,
      sensitive?: false
    },
    "workspace.fragment.rate_limit_per_second" => %{
      type: :bounded_integer,
      default: 10,
      writable?: true,
      sensitive?: false,
      min: 1,
      max: 1000
    },
    "workspace.fragment.receiver_rate_limit_per_second" => %{
      type: :bounded_integer,
      default: 10,
      writable?: true,
      sensitive?: false,
      min: 1,
      max: 1000
    },
    "workspace.fragment.payload_max_bytes" => %{
      type: :bounded_integer,
      default: 65_536,
      writable?: true,
      sensitive?: false,
      min: 1024,
      max: 262_144
    },
    "workspace.offline.enabled" => %{
      type: :boolean,
      default: true,
      writable?: true,
      sensitive?: false
    },
    "workspace.offline.indexeddb_quota_mb" => %{
      type: :bounded_integer,
      default: 32,
      writable?: true,
      sensitive?: false,
      min: 1,
      max: 256
    },
    "workspace.accessibility.high_contrast" => %{
      type: :boolean,
      default: false,
      writable?: true,
      sensitive?: false
    },
    "workspace.accessibility.reduce_motion" => %{
      type: :boolean,
      default: false,
      writable?: true,
      sensitive?: false
    },
    "workspace.mobile.breakpoint_px" => %{
      type: :positive_integer,
      default: 768,
      writable?: false,
      sensitive?: false
    },
    "workspace.agui_bridge.enabled" => %{
      type: :boolean,
      default: true,
      writable?: true,
      sensitive?: false
    },
    "workspace.signal_bridge.log_dropped_fragments" => %{
      type: :boolean,
      default: true,
      writable?: true,
      sensitive?: false
    },
    "workflows.enabled" => %{
      type: :boolean,
      default: true,
      writable?: true,
      sensitive?: false
    },
    "workflows.dir" => %{
      type: :string,
      default: "<ALLBERT_HOME>/workflows",
      writable?: false,
      sensitive?: false
    },
    "workflows.id_pattern" => %{
      type: :string,
      default: "^[a-z0-9][a-z0-9_-]*$",
      writable?: false,
      sensitive?: false
    },
    "workflows.max_steps_per_workflow" => %{
      type: :bounded_integer,
      default: 3,
      writable?: true,
      sensitive?: false,
      min: 1,
      max: 10
    },
    "workflows.max_workflows_loaded_per_request" => %{
      type: :bounded_integer,
      default: 8,
      writable?: true,
      sensitive?: false,
      min: 1,
      max: 8
    },
    "workflows.max_param_bytes_per_step" => %{
      type: :bounded_integer,
      default: 65_536,
      writable?: true,
      sensitive?: false,
      min: 1,
      max: 1_048_576
    },
    "workflows.max_yaml_bytes_per_file" => %{
      type: :bounded_integer,
      default: 262_144,
      writable?: true,
      sensitive?: false,
      min: 1,
      max: 1_048_576
    },
    "workflows.schema_version" => %{
      type: :bounded_integer,
      default: 1,
      writable?: false,
      sensitive?: false,
      min: 1,
      max: 1
    },
    "workflows.expression_grammar" => %{
      type: :enum,
      default: "closed_v1",
      writable?: false,
      sensitive?: false,
      allowed_values: ["closed_v1"]
    },
    "plan.preview.show_estimated_cost" => %{
      type: :boolean,
      default: true,
      writable?: true,
      sensitive?: false
    },
    "plan.preview.show_failure_blast_radius" => %{
      type: :boolean,
      default: true,
      writable?: true,
      sensitive?: false
    },
    "plan.preview.show_confidence_tier" => %{
      type: :boolean,
      default: true,
      writable?: true,
      sensitive?: false
    },
    "plan.preview.confidence_tier_engine" => %{
      type: :enum,
      default: "deterministic_v1",
      writable?: false,
      sensitive?: false,
      allowed_values: ["deterministic_v1"]
    },
    "plan.preview.auto_proceed_green_tier" => %{
      type: :boolean,
      default: false,
      writable?: true,
      sensitive?: false
    },
    "plan.run.default_concurrency" => %{
      type: :bounded_integer,
      default: 1,
      writable?: false,
      sensitive?: false,
      min: 1,
      max: 1
    },
    "plan.run.cancel_grace_ms" => %{
      type: :bounded_integer,
      default: 5000,
      writable?: true,
      sensitive?: false,
      min: 0,
      max: 30_000
    },
    "plan.run.plan_start_gate" => %{
      type: :enum,
      default: "required",
      writable?: false,
      sensitive?: false,
      allowed_values: ["required"]
    },
    "plan.subagent.delegation_visibility" => %{
      type: :enum,
      default: "expanded_inline",
      writable?: false,
      sensitive?: false,
      allowed_values: ["expanded_inline"]
    },
    "voice.schema_version" => %{
      type: :bounded_integer,
      default: 1,
      writable?: false,
      sensitive?: false,
      min: 1,
      max: 1
    },
    "voice.enabled" => %{
      type: :boolean,
      default: false,
      writable?: true,
      sensitive?: false
    },
    "voice.audio.max_bytes" => %{
      type: :bounded_integer,
      default: 10_485_760,
      writable?: true,
      sensitive?: false,
      min: 1,
      max: 104_857_600
    },
    "voice.audio.max_duration_ms" => %{
      type: :bounded_integer,
      default: 300_000,
      writable?: true,
      sensitive?: false,
      min: 1,
      max: 3_600_000
    },
    "voice.audio.retention_enabled" => %{
      type: :boolean,
      default: false,
      writable?: true,
      sensitive?: false
    },
    "voice.audio.retention_root" => %{
      type: :string,
      default: "<ALLBERT_HOME>/audio",
      writable?: true,
      sensitive?: false
    },
    "voice.trace.redact_audio" => %{
      type: :boolean,
      default: true,
      writable?: true,
      sensitive?: false
    },
    "voice.local_runtime.enabled" => %{
      type: :boolean,
      default: false,
      writable?: true,
      sensitive?: false
    },
    "voice.local_runtime.port" => %{
      type: :bounded_integer,
      default: 5050,
      writable?: true,
      sensitive?: false,
      min: 1024,
      max: 65_535
    },
    "voice.local_runtime.ollama_base_url" => %{
      type: :loopback_http_base_url,
      default: "http://127.0.0.1:11434/v1",
      writable?: true,
      sensitive?: false
    },
    "voice.local_runtime.ollama_stt_model" => %{
      type: :string,
      default: "gemma4:e2b",
      writable?: true,
      sensitive?: false
    },
    "voice.local_runtime.stt_model_alias" => %{
      type: :string,
      default: "whisper-local",
      writable?: true,
      sensitive?: false
    },
    "voice.local_runtime.tts_model_alias" => %{
      type: :string,
      default: "tts-local",
      writable?: true,
      sensitive?: false
    },
    "voice.local_runtime.stt_backend" => %{
      type: :enum,
      default: "ollama",
      writable?: true,
      sensitive?: false,
      allowed_values: ["ollama"]
    },
    "voice.local_runtime.tts_backend" => %{
      type: :enum,
      default: "macos_say",
      writable?: true,
      sensitive?: false,
      allowed_values: ["macos_say"]
    },
    "voice.local_runtime.max_text_bytes" => %{
      type: :bounded_integer,
      default: 16_384,
      writable?: true,
      sensitive?: false,
      min: 1,
      max: 262_144
    },
    "vision.schema_version" => %{
      type: :bounded_integer,
      default: 1,
      writable?: false,
      sensitive?: false,
      min: 1,
      max: 1
    },
    "vision.enabled" => %{
      type: :boolean,
      default: false,
      writable?: true,
      sensitive?: false
    },
    "vision.media.max_bytes" => %{
      type: :bounded_integer,
      default: 20_971_520,
      writable?: true,
      sensitive?: false,
      min: 1,
      max: 104_857_600
    },
    "vision.media.max_pixels" => %{
      type: :bounded_integer,
      default: 33_177_600,
      writable?: true,
      sensitive?: false,
      min: 1,
      max: 536_870_912
    },
    "vision.media.retention_enabled" => %{
      type: :boolean,
      default: false,
      writable?: true,
      sensitive?: false
    },
    "vision.media.retention_root" => %{
      type: :string,
      default: "<ALLBERT_HOME>/images",
      writable?: true,
      sensitive?: false
    },
    "vision.trace.redact_images" => %{
      type: :boolean,
      default: true,
      writable?: true,
      sensitive?: false
    },
    "image.schema_version" => %{
      type: :bounded_integer,
      default: 1,
      writable?: false,
      sensitive?: false,
      min: 1,
      max: 1
    },
    "image.enabled" => %{
      type: :boolean,
      default: false,
      writable?: true,
      sensitive?: false
    },
    "image.generation.max_bytes" => %{
      type: :bounded_integer,
      default: 20_971_520,
      writable?: true,
      sensitive?: false,
      min: 1,
      max: 104_857_600
    },
    "image.generation.max_pixels" => %{
      type: :bounded_integer,
      default: 33_177_600,
      writable?: true,
      sensitive?: false,
      min: 1,
      max: 536_870_912
    },
    "image.generation.retention_enabled" => %{
      type: :boolean,
      default: false,
      writable?: true,
      sensitive?: false
    },
    "image.generation.retention_root" => %{
      type: :string,
      default: "<ALLBERT_HOME>/generated_images",
      writable?: true,
      sensitive?: false
    },
    "image.trace.redact_images" => %{
      type: :boolean,
      default: true,
      writable?: true,
      sensitive?: false
    },
    "artifacts.schema_version" => %{
      type: :bounded_integer,
      default: 1,
      writable?: false,
      sensitive?: false,
      min: 1,
      max: 1
    },
    "artifacts.enabled" => %{
      type: :boolean,
      default: false,
      writable?: true,
      sensitive?: false
    },
    "artifacts.root" => %{
      type: :string,
      default: "<ALLBERT_HOME>/artifacts",
      writable?: true,
      sensitive?: false
    },
    "artifacts.retention_enabled" => %{
      type: :boolean,
      default: false,
      writable?: true,
      sensitive?: false
    },
    "artifacts.max_bytes" => %{
      type: :bounded_integer,
      default: 20_971_520,
      writable?: true,
      sensitive?: false,
      min: 1,
      max: 104_857_600
    },
    "artifacts.allowed_mime" => %{
      type: :string_list,
      default: ["*/*"],
      writable?: true,
      sensitive?: false
    },
    "artifacts.allowed_types" => %{
      type: :string_list,
      default: ["*"],
      writable?: true,
      sensitive?: false
    },
    "artifacts.dedup" => %{
      type: :enum,
      default: "content_sha256",
      writable?: false,
      sensitive?: false,
      allowed_values: ["content_sha256"]
    },
    "artifacts.gc.mode" => %{
      type: :enum,
      default: "on_demand",
      writable?: false,
      sensitive?: false,
      allowed_values: ["on_demand"]
    },
    "artifacts.gc.enabled" => %{
      type: :boolean,
      default: false,
      writable?: true,
      sensitive?: false
    },
    "artifacts.gc.delete_orphans" => %{
      type: :boolean,
      default: true,
      writable?: true,
      sensitive?: false
    },
    "artifacts.trace.redact_bytes" => %{
      type: :boolean,
      default: true,
      writable?: true,
      sensitive?: false
    },
    "marketplace.schema_version" => %{
      type: :bounded_integer,
      default: 1,
      writable?: false,
      sensitive?: false,
      min: 1,
      max: 1
    },
    "marketplace.enabled" => %{
      type: :boolean,
      default: true,
      writable?: true,
      sensitive?: false
    },
    "marketplace.catalog.source" => %{
      type: :enum,
      default: "shipped",
      writable?: false,
      sensitive?: false,
      allowed_values: ["shipped"]
    },
    "marketplace.catalog.cache_path" => %{
      type: :string,
      default: "<ALLBERT_HOME>/marketplace/cache",
      writable?: true,
      sensitive?: false
    },
    "marketplace.catalog.mirror_on_first_action" => %{
      type: :boolean,
      default: true,
      writable?: false,
      sensitive?: false
    },
    "marketplace.install.default_state" => %{
      type: :enum,
      default: "disabled_untrusted",
      writable?: false,
      sensitive?: false,
      allowed_values: ["disabled_untrusted"]
    },
    "marketplace.install.target_dir_skills" => %{
      type: :string,
      default: "<ALLBERT_HOME>/marketplace/skills",
      writable?: true,
      sensitive?: false
    },
    "marketplace.install.target_dir_templates" => %{
      type: :string,
      default: "<ALLBERT_HOME>/marketplace/templates",
      writable?: true,
      sensitive?: false
    },
    "marketplace.provenance.hash_algorithm" => %{
      type: :enum,
      default: "sha256",
      writable?: false,
      sensitive?: false,
      allowed_values: ["sha256"]
    },
    "marketplace.provenance.require_hash_match" => %{
      type: :boolean,
      default: true,
      writable?: false,
      sensitive?: false
    },
    "marketplace.installed_state_path" => %{
      type: :string,
      default: "<ALLBERT_HOME>/marketplace/installed.json",
      writable?: true,
      sensitive?: false
    },
    "self_improvement.schema_version" => %{
      type: :bounded_integer,
      default: 1,
      writable?: false,
      sensitive?: false,
      min: 1,
      max: 1
    },
    "self_improvement.enabled" => %{
      type: :boolean,
      default: false,
      writable?: true,
      sensitive?: false
    },
    "self_improvement.trace_index.enabled" => %{
      type: :boolean,
      default: false,
      writable?: true,
      sensitive?: false
    },
    "self_improvement.trace_index.max_indexed_entries" => %{
      type: :bounded_integer,
      default: 5000,
      writable?: true,
      sensitive?: false,
      min: 1,
      max: 50_000
    },
    "self_improvement.trace_index.min_repetitions" => %{
      type: :bounded_integer,
      default: 3,
      writable?: true,
      sensitive?: false,
      min: 2,
      max: 100
    },
    "self_improvement.suggestions.max_open" => %{
      type: :bounded_integer,
      default: 25,
      writable?: true,
      sensitive?: false,
      min: 1,
      max: 200
    },
    "self_improvement.suggestions.ttl_days" => %{
      type: :bounded_integer,
      default: 14,
      writable?: true,
      sensitive?: false,
      min: 1,
      max: 365
    },
    "self_improvement.drafts.max_open" => %{
      type: :bounded_integer,
      default: 50,
      writable?: true,
      sensitive?: false,
      min: 1,
      max: 500
    },
    "permissions.memory_write" => %{
      type: :enum,
      default: "allowed",
      writable?: true,
      sensitive?: false,
      allowed_values: ["allowed", "needs_confirmation", "denied"]
    },
    "permissions.command_plan" => %{
      type: :enum,
      default: "allowed",
      writable?: true,
      sensitive?: false,
      allowed_values: ["allowed", "needs_confirmation", "denied"]
    },
    "permissions.command_execute" => %{
      type: :enum,
      default: "denied",
      writable?: true,
      sensitive?: false,
      allowed_values: ["allowed", "needs_confirmation", "denied"]
    },
    "permissions.external_network" => %{
      type: :enum,
      default: "needs_confirmation",
      writable?: true,
      sensitive?: false,
      allowed_values: ["allowed", "needs_confirmation", "denied"]
    },
    "permissions.package_install" => %{
      type: :enum,
      default: "denied",
      writable?: true,
      sensitive?: false,
      allowed_values: ["allowed", "needs_confirmation", "denied"]
    },
    "permissions.online_skill_import" => %{
      type: :enum,
      default: "denied",
      writable?: true,
      sensitive?: false,
      allowed_values: ["allowed", "needs_confirmation", "denied"]
    },
    "permissions.settings_write" => %{
      type: :enum,
      default: "allowed_safe_keys",
      writable?: true,
      sensitive?: false,
      allowed_values: ["allowed_safe_keys", "needs_confirmation", "denied"]
    },
    "permissions.skill_write" => %{
      type: :enum,
      default: "allowed",
      writable?: true,
      sensitive?: false,
      allowed_values: ["allowed", "needs_confirmation", "denied"]
    },
    "permissions.dynamic_codegen_request" => %{
      type: :enum,
      default: "allowed",
      writable?: true,
      sensitive?: false,
      allowed_values: ["allowed", "needs_confirmation", "denied"]
    },
    "permissions.dynamic_codegen_discard" => %{
      type: :enum,
      default: "allowed",
      writable?: true,
      sensitive?: false,
      allowed_values: ["allowed", "needs_confirmation", "denied"]
    },
    "permissions.skill_script_execute" => %{
      type: :enum,
      default: "denied",
      writable?: true,
      sensitive?: false,
      allowed_values: ["allowed", "needs_confirmation", "denied"]
    },
    "permissions.confirmation_decide" => %{
      type: :enum,
      default: "allowed",
      writable?: true,
      sensitive?: false,
      allowed_values: ["allowed", "denied"]
    },
    "permissions.objective_write" => %{
      type: :enum,
      default: "allowed",
      writable?: true,
      sensitive?: false,
      allowed_values: ["allowed", "needs_confirmation", "denied"]
    },
    "permissions.workspace_canvas_write" => %{
      type: :enum,
      default: "allowed",
      writable?: true,
      sensitive?: false,
      allowed_values: ["allowed", "needs_confirmation", "denied"]
    },
    "permissions.sandbox_trial" => %{
      type: :enum,
      default: "allowed",
      writable?: true,
      sensitive?: false,
      allowed_values: ["allowed", "denied"]
    },
    "permissions.dynamic_integration" => %{
      type: :enum,
      default: "needs_confirmation",
      writable?: true,
      sensitive?: false,
      allowed_values: ["needs_confirmation", "denied"]
    },
    "permissions.stocksage_write" => %{
      type: :enum,
      default: "allowed",
      writable?: true,
      sensitive?: false,
      allowed_values: ["allowed", "needs_confirmation", "denied"]
    },
    "permissions.stocksage_analyze" => %{
      type: :enum,
      default: "needs_confirmation",
      writable?: true,
      sensitive?: false,
      allowed_values: ["needs_confirmation", "denied"]
    },
    "permissions.stocksage_evidence_fetch" => %{
      type: :enum,
      default: "allowed",
      writable?: true,
      sensitive?: false,
      allowed_values: ["allowed", "needs_confirmation", "denied"]
    },
    "permissions.notes_file_write" => %{
      type: :enum,
      default: "needs_confirmation",
      writable?: true,
      sensitive?: false,
      allowed_values: ["needs_confirmation", "denied"]
    },
    "permissions.microphone_capture" => %{
      type: :enum,
      default: "needs_confirmation",
      writable?: true,
      sensitive?: false,
      allowed_values: ["needs_confirmation", "denied"]
    },
    "permissions.voice_transcribe" => %{
      type: :enum,
      default: "allowed",
      writable?: true,
      sensitive?: false,
      allowed_values: ["allowed", "needs_confirmation", "denied"]
    },
    "permissions.voice_synthesize" => %{
      type: :enum,
      default: "allowed",
      writable?: true,
      sensitive?: false,
      allowed_values: ["allowed", "needs_confirmation", "denied"]
    },
    "permissions.voice_local_runtime_manage" => %{
      type: :enum,
      default: "allowed",
      writable?: true,
      sensitive?: false,
      allowed_values: ["allowed", "needs_confirmation", "denied"]
    },
    "permissions.image_input" => %{
      type: :enum,
      default: "allowed",
      writable?: true,
      sensitive?: false,
      allowed_values: ["allowed", "needs_confirmation", "denied"]
    },
    "permissions.image_generate" => %{
      type: :enum,
      default: "allowed",
      writable?: true,
      sensitive?: false,
      allowed_values: ["allowed", "needs_confirmation", "denied"]
    },
    "permissions.artifact_read" => %{
      type: :enum,
      default: "allowed",
      writable?: true,
      sensitive?: false,
      allowed_values: ["allowed", "needs_confirmation", "denied"]
    },
    "permissions.artifact_write" => %{
      type: :enum,
      default: "allowed",
      writable?: true,
      sensitive?: false,
      allowed_values: ["allowed", "needs_confirmation", "denied"]
    },
    "permissions.artifact_delete" => %{
      type: :enum,
      default: "needs_confirmation",
      writable?: true,
      sensitive?: false,
      allowed_values: ["needs_confirmation", "denied"]
    },
    "permissions.tool_discovery" => %{
      type: :enum,
      default: "allowed",
      writable?: true,
      sensitive?: false,
      allowed_values: ["allowed", "denied"]
    },
    "permissions.mcp_server_connect" => %{
      type: :enum,
      default: "needs_confirmation",
      writable?: true,
      sensitive?: false,
      allowed_values: ["needs_confirmation", "denied"]
    },
    "permissions.mcp_tool_call" => %{
      type: :enum,
      default: "needs_confirmation",
      writable?: true,
      sensitive?: false,
      allowed_values: ["needs_confirmation", "denied"]
    },
    "permissions.mcp_resource_read" => %{
      type: :enum,
      default: "allowed",
      writable?: true,
      sensitive?: false,
      allowed_values: ["allowed", "needs_confirmation", "denied"]
    },
    "permissions.public_surface_call_inbound" => %{
      type: :enum,
      default: "needs_confirmation",
      writable?: true,
      sensitive?: false,
      allowed_values: ["needs_confirmation", "denied"]
    },
    "permissions.channel_message_inbound" => %{
      type: :enum,
      default: "needs_confirmation",
      writable?: true,
      sensitive?: false,
      allowed_values: ["needs_confirmation", "denied"]
    },
    "permissions.browser_session_start" => %{
      type: :enum,
      default: "needs_confirmation",
      writable?: true,
      sensitive?: false,
      allowed_values: ["needs_confirmation", "denied"]
    },
    "permissions.browser_navigate" => %{
      type: :enum,
      default: "needs_confirmation",
      writable?: true,
      sensitive?: false,
      allowed_values: ["needs_confirmation", "denied"]
    },
    "permissions.browser_extract" => %{
      type: :enum,
      default: "allowed",
      writable?: true,
      sensitive?: false,
      allowed_values: ["allowed", "needs_confirmation", "denied"]
    },
    "permissions.browser_screenshot" => %{
      type: :enum,
      default: "allowed",
      writable?: true,
      sensitive?: false,
      allowed_values: ["allowed", "needs_confirmation", "denied"]
    },
    "permissions.browser_interact" => %{
      type: :enum,
      default: "needs_confirmation",
      writable?: true,
      sensitive?: false,
      allowed_values: ["needs_confirmation", "denied"]
    },
    "permissions.browser_form_fill" => %{
      type: :enum,
      default: "denied",
      writable?: true,
      sensitive?: false,
      allowed_values: ["needs_confirmation", "denied"]
    },
    "permissions.browser_download" => %{
      type: :enum,
      default: "denied",
      writable?: true,
      sensitive?: false,
      allowed_values: ["needs_confirmation", "denied"]
    },
    "permissions.workflow_read" => %{
      type: :enum,
      default: "allowed",
      writable?: true,
      sensitive?: false,
      allowed_values: ["allowed", "needs_confirmation", "denied"]
    },
    "permissions.workflow_run_start" => %{
      type: :enum,
      default: "needs_confirmation",
      writable?: true,
      sensitive?: false,
      allowed_values: ["needs_confirmation", "denied"]
    },
    "permissions.plan_cancel" => %{
      type: :enum,
      default: "allowed",
      writable?: true,
      sensitive?: false,
      allowed_values: ["allowed", "needs_confirmation", "denied"]
    },
    "permissions.marketplace_install" => %{
      type: :enum,
      default: "allowed",
      writable?: true,
      sensitive?: false,
      allowed_values: ["allowed", "needs_confirmation", "denied"]
    },
    "permissions.email_send" => %{
      type: :enum,
      default: "needs_confirmation",
      writable?: true,
      sensitive?: false,
      allowed_values: ["allowed", "needs_confirmation", "denied"]
    },
    "permissions.channel_message_send" => %{
      type: :enum,
      default: "needs_confirmation",
      writable?: true,
      sensitive?: false,
      allowed_values: ["allowed", "needs_confirmation", "denied"]
    },
    "permissions.calendar_write" => %{
      type: :enum,
      default: "needs_confirmation",
      writable?: true,
      sensitive?: false,
      allowed_values: ["allowed", "needs_confirmation", "denied"]
    },
    "execution.local.enabled" => %{
      type: :boolean,
      default: false,
      writable?: true,
      sensitive?: false
    },
    "execution.local.allowed_roots" => %{
      type: :string_list,
      default: [],
      writable?: true,
      sensitive?: false
    },
    "execution.local.allowed_commands" => %{
      type: :string_list,
      default: ["pwd", "ls", "find", "rg", "cat", "sed", "head", "tail", "wc"],
      writable?: true,
      sensitive?: false
    },
    "execution.local.command_profiles" => %{
      type: :command_profiles,
      default: %{},
      writable?: true,
      sensitive?: false
    },
    "execution.local.blocked_arg_patterns" => %{
      type: :string_list,
      default: [
        "-i",
        "--in-place",
        "-delete",
        "-exec",
        "-execdir",
        "-c",
        "-e",
        "--eval",
        "&&",
        "||",
        ";",
        "|",
        ">",
        ">>",
        "<",
        "$(",
        "`",
        "&"
      ],
      writable?: true,
      sensitive?: false
    },
    "execution.local.require_path_operands_in_allowed_roots" => %{
      type: :boolean,
      default: true,
      writable?: true,
      sensitive?: false
    },
    "execution.local.default_timeout_ms" => %{
      type: :timeout_ms,
      default: 5000,
      writable?: true,
      sensitive?: false
    },
    "execution.local.max_timeout_ms" => %{
      type: :timeout_ms,
      default: 30_000,
      writable?: true,
      sensitive?: false
    },
    "execution.local.max_output_bytes" => %{
      type: :positive_integer,
      default: 65_536,
      writable?: true,
      sensitive?: false
    },
    "execution.local.env_allowlist" => %{
      type: :string_list,
      default: ["PATH", "LANG", "LC_ALL", "MIX_ENV"],
      writable?: true,
      sensitive?: false
    },
    "execution.local.require_confirmation" => %{
      type: :boolean,
      default: true,
      writable?: true,
      sensitive?: false
    },
    "execution.skill_scripts.enabled" => %{
      type: :boolean,
      default: false,
      writable?: true,
      sensitive?: false
    },
    "execution.skill_scripts.require_confirmation" => %{
      type: :boolean,
      default: true,
      writable?: true,
      sensitive?: false
    },
    "execution.skill_scripts.interpreter_profiles" => %{
      type: :interpreter_profiles,
      default: %{},
      writable?: true,
      sensitive?: false
    },
    "external_services.enabled" => %{
      type: :boolean,
      default: false,
      writable?: true,
      sensitive?: false
    },
    "external_services.allowed_hosts" => %{
      type: :string_list,
      default: [],
      writable?: true,
      sensitive?: false
    },
    "external_services.blocked_hosts" => %{
      type: :string_list,
      default: [],
      writable?: true,
      sensitive?: false
    },
    "external_services.allowed_paths" => %{
      type: :string_list,
      default: ["/"],
      writable?: true,
      sensitive?: false
    },
    "external_services.allowed_methods" => %{
      type: :http_methods,
      default: ["GET", "HEAD"],
      writable?: true,
      sensitive?: false
    },
    "external_services.default_timeout_ms" => %{
      type: :timeout_ms,
      default: 5000,
      writable?: true,
      sensitive?: false
    },
    "external_services.max_timeout_ms" => %{
      type: :timeout_ms,
      default: 30_000,
      writable?: true,
      sensitive?: false
    },
    "external_services.max_response_bytes" => %{
      type: :positive_integer,
      default: 1_048_576,
      writable?: true,
      sensitive?: false
    },
    "external_services.allow_redirects" => %{
      type: :boolean,
      default: false,
      writable?: true,
      sensitive?: false
    },
    "external_services.max_redirects" => %{
      type: :non_negative_integer,
      default: 0,
      writable?: true,
      sensitive?: false
    },
    "external_services.retry_policy" => %{
      type: :enum,
      default: "none",
      writable?: true,
      sensitive?: false,
      allowed_values: ["none", "safe_idempotent"]
    },
    "external_services.redact_request_headers" => %{
      type: :string_list,
      default: ["authorization", "cookie", "x-api-key"],
      writable?: true,
      sensitive?: false
    },
    "external_services.redact_response_headers" => %{
      type: :string_list,
      default: ["set-cookie", "authorization"],
      writable?: true,
      sensitive?: false
    },
    "external_services.profiles" => %{
      type: :external_service_profiles,
      default: %{},
      writable?: true,
      sensitive?: false
    },
    "package_installs.enabled" => %{
      type: :boolean,
      default: false,
      writable?: true,
      sensitive?: false
    },
    "package_installs.require_confirmation" => %{
      type: :boolean,
      default: true,
      writable?: true,
      sensitive?: false
    },
    "package_installs.allowed_roots" => %{
      type: :string_list,
      default: [],
      writable?: true,
      sensitive?: false
    },
    "package_installs.allowed_managers" => %{
      type: :string_list,
      default: ["npm"],
      writable?: true,
      sensitive?: false
    },
    "package_installs.default_timeout_ms" => %{
      type: :timeout_ms,
      default: 30_000,
      writable?: true,
      sensitive?: false
    },
    "package_installs.max_timeout_ms" => %{
      type: :timeout_ms,
      default: 120_000,
      writable?: true,
      sensitive?: false
    },
    "package_installs.max_output_bytes" => %{
      type: :positive_integer,
      default: 262_144,
      writable?: true,
      sensitive?: false
    },
    "package_installs.lifecycle_scripts_allowed" => %{
      type: :boolean,
      default: false,
      writable?: true,
      sensitive?: false
    },
    "package_installs.git_dependencies_allowed" => %{
      type: :boolean,
      default: false,
      writable?: true,
      sensitive?: false
    },
    "package_installs.global_installs_allowed" => %{
      type: :boolean,
      default: false,
      writable?: true,
      sensitive?: false
    },
    "package_installs.manager_profiles" => %{
      type: :package_manager_profiles,
      default: %{},
      writable?: true,
      sensitive?: false
    },
    "sandbox.elixir.enabled" => %{
      type: :boolean,
      default: false,
      writable?: true,
      sensitive?: false
    },
    "sandbox.elixir.backend" => %{
      type: :enum,
      default: "auto",
      writable?: true,
      sensitive?: false,
      allowed_values: ["auto", "apple_container", "docker", "podman_rootless", "docker_runsc"]
    },
    "sandbox.elixir.image" => %{
      type: :string,
      default: "allbert-elixir-otp:local",
      writable?: true,
      sensitive?: false
    },
    "sandbox.elixir.network" => %{
      type: :enum,
      default: "none",
      writable?: true,
      sensitive?: false,
      allowed_values: ["none"]
    },
    "sandbox.elixir.cpu_limit" => %{
      type: :bounded_float,
      default: 1.0,
      writable?: true,
      sensitive?: false,
      min: 0.25,
      max: 8.0
    },
    "sandbox.elixir.memory_mb" => %{
      type: :bounded_integer,
      default: 1024,
      writable?: true,
      sensitive?: false,
      min: 128,
      max: 8192
    },
    "sandbox.elixir.timeout_ms" => %{
      type: :timeout_ms,
      default: 120_000,
      writable?: true,
      sensitive?: false
    },
    "sandbox.elixir.output_bytes" => %{
      type: :positive_integer,
      default: 65_536,
      writable?: true,
      sensitive?: false
    },
    "dynamic_codegen.enabled" => %{
      type: :boolean,
      default: false,
      writable?: true,
      sensitive?: false
    },
    "dynamic_codegen.provider_profile" => %{
      type: :string_or_nil,
      default: nil,
      writable?: true,
      sensitive?: false
    },
    "dynamic_codegen.max_repair_iterations" => %{
      type: :bounded_integer,
      default: 2,
      writable?: true,
      sensitive?: false,
      min: 0,
      max: 8
    },
    "dynamic_codegen.max_provider_calls_per_gap" => %{
      type: :bounded_integer,
      default: 8,
      writable?: true,
      sensitive?: false,
      min: 1,
      max: 40
    },
    "dynamic_codegen.max_provider_usage_units_per_gap" => %{
      type: :non_negative_integer_or_nil,
      default: 20_000,
      writable?: true,
      sensitive?: false
    },
    "dynamic_codegen.max_files" => %{
      type: :bounded_integer,
      default: 32,
      writable?: true,
      sensitive?: false,
      min: 1,
      max: 200
    },
    "dynamic_codegen.max_bytes" => %{
      type: :bounded_integer,
      default: 262_144,
      writable?: true,
      sensitive?: false,
      min: 1024,
      max: 5_242_880
    },
    "dynamic_codegen.allowed_targets" => %{
      type: :string_list,
      default: ["action"],
      writable?: true,
      sensitive?: false
    },
    "dynamic_codegen.allowed_action_permissions" => %{
      type: :string_list,
      default: ["read_only"],
      writable?: true,
      sensitive?: false
    },
    "dynamic_codegen.allowed_facades" => %{
      type: :string_list,
      default: [],
      writable?: true,
      sensitive?: false
    },
    "dynamic_codegen.live_loader_enabled" => %{
      type: :boolean,
      default: false,
      writable?: true,
      sensitive?: false
    },
    "dynamic_codegen.integration_approval_surfaces" => %{
      type: :string_list,
      default: ["cli", "liveview"],
      writable?: true,
      sensitive?: false
    },
    "dynamic_codegen.retention_days" => %{
      type: :bounded_integer,
      default: 30,
      writable?: true,
      sensitive?: false,
      min: 1,
      max: 365
    },
    "templates.create.enabled" => %{
      type: :boolean,
      default: false,
      writable?: true,
      sensitive?: false
    },
    "templates.allowed_patterns" => %{
      type: :string_list,
      default: ["plugin", "app", "llm_tool", "flow", "objective"],
      writable?: true,
      sensitive?: false
    },
    "resource_grants.remembered" => %{
      type: :resource_grants,
      default: [],
      writable?: true,
      sensitive?: false
    },
    "confirmations.default_ttl_minutes" => %{
      type: :positive_integer,
      default: 1440,
      writable?: true,
      sensitive?: false
    },
    "confirmations.auto_expire_on_startup" => %{
      type: :boolean,
      default: true,
      writable?: true,
      sensitive?: false
    },
    "confirmations.require_reason_for_denial" => %{
      type: :boolean,
      default: false,
      writable?: true,
      sensitive?: false
    },
    "confirmations.show_redacted_params" => %{
      type: :boolean,
      default: true,
      writable?: true,
      sensitive?: false
    },
    "confirmations.allow_cli_approval" => %{
      type: :boolean,
      default: true,
      writable?: true,
      sensitive?: false
    },
    "confirmations.allow_liveview_approval" => %{
      type: :boolean,
      default: true,
      writable?: true,
      sensitive?: false
    },
    "confirmations.allow_cross_channel_approval" => %{
      type: :boolean,
      default: true,
      writable?: true,
      sensitive?: false
    },
    "jobs.timezone" => %{
      type: :timezone,
      default: "America/Los_Angeles",
      writable?: true,
      sensitive?: false
    },
    "jobs.default_state" => %{
      type: :enum,
      default: "paused",
      writable?: true,
      sensitive?: false,
      allowed_values: ["paused", "active"]
    },
    "jobs.schedule_policy" => %{
      type: :enum,
      default: "operator_approved",
      writable?: true,
      sensitive?: false,
      allowed_values: ["operator_approved", "paused"]
    },
    "sessions.scratchpad_ttl_minutes" => %{
      type: :bounded_integer,
      default: 30,
      writable?: true,
      sensitive?: false,
      min: 1,
      max: 1440
    },
    "memory.review_cadence" => %{
      type: :enum,
      default: "manual",
      writable?: true,
      sensitive?: false,
      allowed_values: ["manual", "daily", "weekly"]
    },
    "memory.auto_promote_sensitive_entries" => %{
      type: :boolean,
      default: false,
      writable?: true,
      sensitive?: false
    },
    "memory.retention_policy" => %{
      type: :enum,
      default: "preserve_markdown",
      writable?: true,
      sensitive?: false,
      allowed_values: [
        "preserve_markdown",
        "prune_traces_after_30d",
        "prune_traces_after_90d"
      ]
    },
    "memory.delete_requires_confirmation" => %{
      type: :boolean,
      default: true,
      writable?: true,
      sensitive?: false
    },
    "memory.prune_requires_confirmation" => %{
      type: :boolean,
      default: true,
      writable?: true,
      sensitive?: false
    },
    "memory.promotion_requires_confirmation" => %{
      type: :boolean,
      default: true,
      writable?: true,
      sensitive?: false
    },
    "memory.max_entries_per_category" => %{
      type: :bounded_integer,
      default: 500,
      writable?: true,
      sensitive?: false,
      min: 1,
      max: 100_000
    },
    "memory.index_enabled" => %{
      type: :boolean,
      default: true,
      writable?: true,
      sensitive?: false
    },
    "memory.max_index_entries" => %{
      type: :bounded_integer,
      default: 1000,
      writable?: true,
      sensitive?: false,
      min: 1,
      max: 100_000
    },
    "mcp.stdio.allowed_launchers" => %{
      type: :string_list,
      default: [],
      writable?: true,
      sensitive?: false
    },
    "mcp.discovery.enabled" => %{
      type: :boolean,
      default: false,
      writable?: true,
      sensitive?: false
    },
    "mcp.discovery.sources.official.enabled" => %{
      type: :boolean,
      default: true,
      writable?: true,
      sensitive?: false
    },
    "mcp.discovery.sources.pulsemcp.enabled" => %{
      type: :boolean,
      default: false,
      writable?: true,
      sensitive?: false
    },
    "mcp.discovery.sources.pulsemcp.api_key_ref" => %{
      type: :mcp_secret_ref_or_nil,
      default: nil,
      writable?: true,
      sensitive?: true
    },
    "mcp.discovery.sources.pulsemcp.tenant_ref" => %{
      type: :mcp_secret_ref_or_nil,
      default: nil,
      writable?: true,
      sensitive?: true
    },
    "mcp.discovery.scan.schedule" => %{
      type: :enum,
      default: "paused",
      writable?: true,
      sensitive?: false,
      allowed_values: ["paused", "daily", "weekly"]
    },
    "mcp.discovery.scan.max_results" => %{
      type: :bounded_integer,
      default: 25,
      writable?: true,
      sensitive?: false,
      min: 1,
      max: 100
    },
    "mcp.discovery.registry_allowlist" => %{
      type: :string_list,
      default: [],
      writable?: true,
      sensitive?: false
    },
    "mcp.discovery.registry_denylist" => %{
      type: :string_list,
      default: [],
      writable?: true,
      sensitive?: false
    },
    "mcp.discovery.auto_connect" => %{
      type: :boolean,
      default: false,
      writable?: false,
      sensitive?: false
    }
  }

  @provider_schema %{
    "type" => %{
      type: :enum,
      allowed_values: [
        "openai",
        "openai_compatible",
        "anthropic",
        "openrouter",
        "google",
        "fake_voice",
        "fake_media",
        "local"
      ]
    },
    "enabled" => %{type: :boolean},
    "endpoint_kind" => %{
      type: :enum,
      allowed_values: ["credentialed_remote", "local_endpoint"]
    },
    "base_url" => %{type: :url_or_nil},
    "api_key_ref" => %{type: :secret_ref_or_nil}
  }

  @model_profile_schema %{
    "provider" => %{type: :provider_ref},
    "model" => %{type: :string},
    "aliases" => %{type: :string_list},
    "capabilities" => %{type: :model_capabilities},
    "media" => %{type: :model_media},
    "temperature" => %{type: :temperature},
    "max_tokens" => %{type: :positive_integer},
    "timeout_ms" => %{type: :timeout_ms}
  }

  @mcp_server_schema %{
    "enabled" => %{type: :boolean},
    "transport" => %{type: :enum, allowed_values: ["stdio", "sse", "streamable_http"]},
    "command" => %{type: :string},
    "args" => %{type: :string_list},
    "env" => %{type: :mcp_secret_ref_string_map},
    "base_url" => %{type: :url_or_nil},
    "headers" => %{type: :mcp_secret_ref_string_map},
    "auth_ref" => %{type: :mcp_secret_ref_or_nil},
    "tool_allowlist" => %{type: :string_list},
    "tool_denylist" => %{type: :string_list},
    "confirmation" => %{type: :enum, allowed_values: ["required", "denied"]}
  }

  @public_protocol_client_schema %{
    "enabled" => %{type: :boolean},
    "token_ref" => %{type: :public_protocol_secret_ref},
    "rate_limit.limit" => %{type: :bounded_integer, min: 1, max: 10_000},
    "rate_limit.period_ms" => %{type: :bounded_integer, min: 100, max: 86_400_000},
    "rate_limit.burst" => %{type: :bounded_integer, min: 0, max: 10_000}
  }

  @defaults %{
    "allbert" => %{
      "jido" => %{
        "debug_trace" => false
      }
    },
    "objectives" => %{
      "enabled" => true,
      "max_steps_per_turn" => 3,
      "max_loop_count" => 5,
      "trace_detail" => "operator"
    },
    "operator" => %{
      "display_name" => "local",
      "timezone" => "America/Los_Angeles",
      "communication_style" => "concise",
      "handoff_detail" => "concrete_next_steps"
    },
    "conversations" => %{
      "unified_history" => %{
        "include_e2ee_origin" => false
      }
    },
    "runtime" => %{
      "trace_default" => "disabled",
      "diagnostics_verbosity" => "normal",
      "model_alias" => "local",
      "cost_visibility" => "summary"
    },
    "intent" => %{
      "model_assist_enabled" => false,
      "model_profile" => "local",
      "model_timeout_ms" => 3000,
      "model_min_confidence" => 0.72,
      "max_candidates" => 80,
      "trace_rejected_candidates" => true,
      "descriptors_enabled" => true,
      "handoff_threshold" => 0.6,
      "handoff_margin" => 0.15,
      "clarify_floor" => 0.3,
      "direct_answer_model_enabled" => false,
      "direct_answer_model_profile" => "local",
      "router_strategy" => "two_stage_local",
      "router_embedding_profile" => "embedding_local",
      "router_model_profile" => "router_local",
      "router_escalation_profile" => "router_escalation_local",
      "router_top_k" => 5,
      "router_min_confidence" => 0.6,
      "router_model_timeout_ms" => 20_000,
      "reindex_on_registration_signal" => true,
      "calendar_mcp_server" => "calendar",
      "multiturn_enabled" => false,
      "descriptor_autoaccept" => false,
      "context_window" => 6,
      "disambiguation_margin" => 0.12,
      "pending_clarification_ttl_ms" => 120_000
    },
    "model_preferences" => %{
      "schema_version" => 1,
      "primary" => "local",
      "tasks" => %{
        "coding" => ["coding_local", "coding", "capable", "local"],
        "direct_answer" => ["local"]
      },
      "capabilities" => %{
        "text_generation" => ["local", "fast"],
        "embeddings" => ["embedding_local"],
        "speech_to_text" => ["voice_stt_local", "voice_stt_openai", "voice_stt_gemini"],
        "text_to_speech" => ["voice_tts_local", "voice_tts_openai", "voice_tts_gemini"],
        "vision_input" => ["vision_openai", "vision_gemini"],
        "image_generation" => ["image_openai", "image_gemini"]
      }
    },
    "providers" => %{
      "local_ollama" => %{
        "type" => "openai_compatible",
        "base_url" => "http://localhost:11434/v1",
        "api_key_ref" => nil,
        "endpoint_kind" => "local_endpoint",
        "enabled" => true
      },
      "openai" => %{
        "type" => "openai",
        "api_key_ref" => "secret://providers/openai/api_key",
        "endpoint_kind" => "credentialed_remote",
        "enabled" => false
      },
      "anthropic" => %{
        "type" => "anthropic",
        "api_key_ref" => "secret://providers/anthropic/api_key",
        "endpoint_kind" => "credentialed_remote",
        "enabled" => false
      },
      "openrouter" => %{
        "type" => "openrouter",
        "api_key_ref" => "secret://providers/openrouter/api_key",
        "endpoint_kind" => "credentialed_remote",
        "enabled" => false
      },
      "gemini" => %{
        "type" => "google",
        "api_key_ref" => "secret://providers/gemini/api_key",
        "endpoint_kind" => "credentialed_remote",
        "enabled" => false
      }
    },
    "model_profiles" => %{
      "local" => %{
        "provider" => "local_ollama",
        "model" => "llama3.2:3b",
        "temperature" => 0.2,
        "max_tokens" => 1024,
        "timeout_ms" => 30_000
      },
      "coding_local" => %{
        "provider" => "local_ollama",
        "model" => "qwen2.5-coder:7b",
        "aliases" => ["qwen2.5-coder"],
        "temperature" => 0.1,
        "max_tokens" => 4096,
        "timeout_ms" => 60_000
      },
      "fast" => %{
        "provider" => "openai",
        "model" => "gpt-4o-mini",
        "temperature" => 0.2,
        "max_tokens" => 1024,
        "timeout_ms" => 30_000
      },
      "anthropic_fast" => %{
        "provider" => "anthropic",
        "model" => "claude-haiku-4-5-20251001",
        "temperature" => 0.2,
        "max_tokens" => 4096,
        "timeout_ms" => 45_000
      },
      "openrouter_fast" => %{
        "provider" => "openrouter",
        "model" => "openai/gpt-4o-mini",
        "temperature" => 0.2,
        "max_tokens" => 4096,
        "timeout_ms" => 45_000
      },
      "coding" => %{
        "provider" => "gemini",
        "model" => "gemini-3.5-flash",
        "temperature" => 0.1,
        "max_tokens" => 8192,
        "timeout_ms" => 60_000
      },
      "embedding_local" => %{
        "provider" => "local_ollama",
        "model" => "nomic-embed-text",
        "capabilities" => ["embeddings"],
        "timeout_ms" => 30_000
      },
      "router_local" => %{
        "provider" => "local_ollama",
        "model" => "llama3.1:8b",
        "capabilities" => ["text_generation"],
        "temperature" => 0.0,
        "max_tokens" => 512,
        "timeout_ms" => 45_000
      },
      "router_escalation_local" => %{
        "provider" => "local_ollama",
        "model" => "gemma4:26b",
        "capabilities" => ["text_generation"],
        "temperature" => 0.0,
        "max_tokens" => 512,
        "timeout_ms" => 60_000
      }
    },
    "agents" => %{
      "primary_intent" => %{
        "type" => "code",
        "module" => "AllbertAssist.Agents.IntentAgent",
        "model_profile" => "local",
        "enabled" => true
      }
    },
    "skills" => %{
      "scan_paths" => [],
      "trusted_project_roots" => [],
      "enabled" => [],
      "disabled" => [],
      "imported_cache_policy" => "disabled",
      "online_import" => %{
        "enabled" => false,
        "require_confirmation" => true,
        "allowed_sources" => ["skills_sh"],
        "max_listing_results" => 25,
        "max_download_bytes" => 1_048_576,
        "trust_after_import" => false,
        "sources" => %{
          "skills_sh" => %{
            "enabled" => false,
            "base_url" => "https://skills.sh",
            "api_url" => "https://skills.sh/api",
            "cache_ttl_seconds" => 3600
          }
        }
      }
    },
    "permissions" => %{
      "memory_write" => "allowed",
      "command_plan" => "allowed",
      "command_execute" => "denied",
      "external_network" => "needs_confirmation",
      "package_install" => "denied",
      "online_skill_import" => "denied",
      "settings_write" => "allowed_safe_keys",
      "skill_write" => "allowed",
      "dynamic_codegen_request" => "allowed",
      "dynamic_codegen_discard" => "allowed",
      "skill_script_execute" => "denied",
      "confirmation_decide" => "allowed",
      "objective_write" => "allowed",
      "workspace_canvas_write" => "allowed",
      "sandbox_trial" => "allowed",
      "dynamic_integration" => "needs_confirmation",
      "stocksage_write" => "allowed",
      "stocksage_analyze" => "needs_confirmation",
      "stocksage_evidence_fetch" => "allowed",
      "notes_file_write" => "needs_confirmation",
      "microphone_capture" => "needs_confirmation",
      "voice_transcribe" => "allowed",
      "voice_synthesize" => "allowed",
      "voice_local_runtime_manage" => "allowed",
      "image_input" => "allowed",
      "image_generate" => "allowed",
      "artifact_read" => "allowed",
      "artifact_write" => "allowed",
      "artifact_delete" => "needs_confirmation",
      "tool_discovery" => "allowed",
      "mcp_server_connect" => "needs_confirmation",
      "mcp_tool_call" => "needs_confirmation",
      "mcp_resource_read" => "allowed",
      "public_surface_call_inbound" => "needs_confirmation",
      "channel_message_inbound" => "needs_confirmation",
      "browser_session_start" => "needs_confirmation",
      "browser_navigate" => "needs_confirmation",
      "browser_extract" => "allowed",
      "browser_screenshot" => "allowed",
      "browser_interact" => "needs_confirmation",
      "browser_form_fill" => "denied",
      "browser_download" => "denied",
      "workflow_read" => "allowed",
      "workflow_run_start" => "needs_confirmation",
      "plan_cancel" => "allowed",
      "marketplace_install" => "allowed",
      "email_send" => "needs_confirmation",
      "channel_message_send" => "needs_confirmation",
      "calendar_write" => "needs_confirmation"
    },
    "workflows" => %{
      "enabled" => true,
      "dir" => "<ALLBERT_HOME>/workflows",
      "id_pattern" => "^[a-z0-9][a-z0-9_-]*$",
      "max_steps_per_workflow" => 3,
      "max_workflows_loaded_per_request" => 8,
      "max_param_bytes_per_step" => 65_536,
      "max_yaml_bytes_per_file" => 262_144,
      "schema_version" => 1,
      "expression_grammar" => "closed_v1"
    },
    "plan" => %{
      "preview" => %{
        "show_estimated_cost" => true,
        "show_failure_blast_radius" => true,
        "show_confidence_tier" => true,
        "confidence_tier_engine" => "deterministic_v1",
        "auto_proceed_green_tier" => false
      },
      "run" => %{
        "default_concurrency" => 1,
        "cancel_grace_ms" => 5000,
        "plan_start_gate" => "required"
      },
      "subagent" => %{
        "delegation_visibility" => "expanded_inline"
      }
    },
    "voice" => %{
      "schema_version" => 1,
      "enabled" => false,
      "audio" => %{
        "max_bytes" => 10_485_760,
        "max_duration_ms" => 300_000,
        "retention_enabled" => false,
        "retention_root" => "<ALLBERT_HOME>/audio"
      },
      "trace" => %{
        "redact_audio" => true
      },
      "local_runtime" => %{
        "enabled" => false,
        "port" => 5050,
        "ollama_base_url" => "http://127.0.0.1:11434/v1",
        "ollama_stt_model" => "gemma4:e2b",
        "stt_model_alias" => "whisper-local",
        "tts_model_alias" => "tts-local",
        "stt_backend" => "ollama",
        "tts_backend" => "macos_say",
        "max_text_bytes" => 16_384
      }
    },
    "vision" => %{
      "schema_version" => 1,
      "enabled" => false,
      "media" => %{
        "max_bytes" => 20_971_520,
        "max_pixels" => 33_177_600,
        "retention_enabled" => false,
        "retention_root" => "<ALLBERT_HOME>/images"
      },
      "trace" => %{
        "redact_images" => true
      }
    },
    "image" => %{
      "schema_version" => 1,
      "enabled" => false,
      "generation" => %{
        "max_bytes" => 20_971_520,
        "max_pixels" => 33_177_600,
        "retention_enabled" => false,
        "retention_root" => "<ALLBERT_HOME>/generated_images"
      },
      "trace" => %{
        "redact_images" => true
      }
    },
    "artifacts" => %{
      "schema_version" => 1,
      "enabled" => false,
      "root" => "<ALLBERT_HOME>/artifacts",
      "retention_enabled" => false,
      "max_bytes" => 20_971_520,
      "allowed_mime" => ["*/*"],
      "allowed_types" => ["*"],
      "dedup" => "content_sha256",
      "gc" => %{
        "mode" => "on_demand",
        "enabled" => false,
        "delete_orphans" => true
      },
      "trace" => %{
        "redact_bytes" => true
      }
    },
    "marketplace" => %{
      "schema_version" => 1,
      "enabled" => true,
      "catalog" => %{
        "source" => "shipped",
        "cache_path" => "<ALLBERT_HOME>/marketplace/cache",
        "mirror_on_first_action" => true
      },
      "install" => %{
        "default_state" => "disabled_untrusted",
        "target_dir_skills" => "<ALLBERT_HOME>/marketplace/skills",
        "target_dir_templates" => "<ALLBERT_HOME>/marketplace/templates"
      },
      "provenance" => %{
        "hash_algorithm" => "sha256",
        "require_hash_match" => true
      },
      "installed_state_path" => "<ALLBERT_HOME>/marketplace/installed.json"
    },
    "self_improvement" => %{
      "schema_version" => 1,
      "enabled" => false,
      "trace_index" => %{
        "enabled" => false,
        "max_indexed_entries" => 5000,
        "min_repetitions" => 3
      },
      "suggestions" => %{
        "max_open" => 25,
        "ttl_days" => 14
      },
      "drafts" => %{
        "max_open" => 50
      }
    },
    "mcp" => %{
      "servers" => %{},
      "stdio" => %{
        "allowed_launchers" => []
      },
      "discovery" => %{
        "enabled" => false,
        "sources" => %{
          "official" => %{
            "enabled" => true
          },
          "pulsemcp" => %{
            "enabled" => false,
            "api_key_ref" => nil,
            "tenant_ref" => nil
          }
        },
        "scan" => %{
          "schedule" => "paused",
          "max_results" => 25
        },
        "registry_allowlist" => [],
        "registry_denylist" => [],
        "auto_connect" => false
      }
    },
    "plugins" => %{
      "enabled" => [],
      "disabled" => [],
      "scan_paths" => ["./plugins", "<ALLBERT_HOME>/plugins"],
      "trusted_project_roots" => [],
      "load_policy" => "shipped_and_skill_only",
      "registration_enabled" => true
    },
    "app_registry" => %{
      "registration_enabled" => true
    },
    "mcp_server" => %{
      "schema_version" => 1,
      "enabled" => false,
      "stdio" => %{"enabled" => false},
      "streamable_http" => %{
        "enabled" => false,
        "bind_host" => "127.0.0.1",
        "port" => nil
      },
      "tools_enabled" => [],
      "memory_namespaces_enabled" => [],
      "clients" => %{}
    },
    "openai_api" => %{
      "schema_version" => 1,
      "enabled" => false,
      "path_prefix" => "/v1",
      "models_enabled" => [],
      "tools_enabled" => [],
      "memory_namespaces_enabled" => [],
      "clients" => %{}
    },
    "public_protocol" => %{
      "schema_version" => 1,
      "result_readback_ttl_ms" => 3_600_000,
      "result_readback_sweep_interval_ms" => 60_000,
      "max_body_bytes" => 1_048_576
    },
    "acp_server" => %{
      "schema_version" => 1,
      "enabled" => false,
      "stdio" => %{"enabled" => false},
      "tools_enabled" => [],
      "memory_namespaces_enabled" => [],
      "session" => %{
        "load_enabled" => false,
        "resume_enabled" => false,
        "additional_directories_enabled" => false
      }
    },
    "execution" => %{
      "local" => %{
        "enabled" => false,
        "allowed_roots" => [],
        "allowed_commands" => ["pwd", "ls", "find", "rg", "cat", "sed", "head", "tail", "wc"],
        "command_profiles" => %{},
        "blocked_arg_patterns" => [
          "-i",
          "--in-place",
          "-delete",
          "-exec",
          "-execdir",
          "-c",
          "-e",
          "--eval",
          "&&",
          "||",
          ";",
          "|",
          ">",
          ">>",
          "<",
          "$(",
          "`",
          "&"
        ],
        "require_path_operands_in_allowed_roots" => true,
        "default_timeout_ms" => 5000,
        "max_timeout_ms" => 30_000,
        "max_output_bytes" => 65_536,
        "env_allowlist" => ["PATH", "LANG", "LC_ALL", "MIX_ENV"],
        "require_confirmation" => true
      },
      "skill_scripts" => %{
        "enabled" => false,
        "require_confirmation" => true,
        "interpreter_profiles" => %{}
      }
    },
    "external_services" => %{
      "enabled" => false,
      "allowed_hosts" => [],
      "blocked_hosts" => [],
      "allowed_paths" => ["/"],
      "allowed_methods" => ["GET", "HEAD"],
      "default_timeout_ms" => 5000,
      "max_timeout_ms" => 30_000,
      "max_response_bytes" => 1_048_576,
      "allow_redirects" => false,
      "max_redirects" => 0,
      "retry_policy" => "none",
      "redact_request_headers" => ["authorization", "cookie", "x-api-key"],
      "redact_response_headers" => ["set-cookie", "authorization"],
      "profiles" => %{}
    },
    "package_installs" => %{
      "enabled" => false,
      "require_confirmation" => true,
      "allowed_roots" => [],
      "allowed_managers" => ["npm"],
      "default_timeout_ms" => 30_000,
      "max_timeout_ms" => 120_000,
      "max_output_bytes" => 262_144,
      "lifecycle_scripts_allowed" => false,
      "git_dependencies_allowed" => false,
      "global_installs_allowed" => false,
      "manager_profiles" => %{}
    },
    "sandbox" => %{
      "elixir" => %{
        "enabled" => false,
        "backend" => "auto",
        "image" => "allbert-elixir-otp:local",
        "network" => "none",
        "cpu_limit" => 1.0,
        "memory_mb" => 1024,
        "timeout_ms" => 120_000,
        "output_bytes" => 65_536
      }
    },
    "dynamic_codegen" => %{
      "enabled" => false,
      "provider_profile" => nil,
      "max_repair_iterations" => 2,
      "max_provider_calls_per_gap" => 8,
      "max_provider_usage_units_per_gap" => 20_000,
      "max_files" => 32,
      "max_bytes" => 262_144,
      "allowed_targets" => ["action"],
      "allowed_action_permissions" => ["read_only"],
      "allowed_facades" => [],
      "live_loader_enabled" => false,
      "integration_approval_surfaces" => ["cli", "liveview"],
      "retention_days" => 30
    },
    "templates" => %{
      "create" => %{
        "enabled" => false
      },
      "allowed_patterns" => ["plugin", "app", "llm_tool", "flow", "objective"]
    },
    "resource_grants" => %{
      "remembered" => []
    },
    "confirmations" => %{
      "default_ttl_minutes" => 1440,
      "auto_expire_on_startup" => true,
      "require_reason_for_denial" => false,
      "show_redacted_params" => true,
      "allow_cli_approval" => true,
      "allow_liveview_approval" => true,
      "allow_cross_channel_approval" => true
    },
    "channels" => %{
      "cli" => %{"enabled" => true, "response_style" => "concise"},
      "live_view" => %{"enabled" => true, "response_style" => "concise"},
      "telegram" => %{
        "enabled" => false,
        "response_style" => "concise",
        "bot_token_ref" => "secret://channels/telegram/bot_token",
        "identity_map" => [],
        "allowed_chat_ids" => [],
        "allow_group_chats" => false,
        "poll_interval_ms" => 2000,
        "poll_timeout_seconds" => 25,
        "max_text_bytes" => 4096,
        "render_approval_buttons" => true,
        "allow_confirmation_callbacks" => true
      },
      "email" => %{
        "enabled" => false,
        "response_style" => "standard",
        "imap_host" => "",
        "imap_port" => 993,
        "imap_ssl" => true,
        "imap_username" => "",
        "imap_password_ref" => "secret://channels/email/imap_password",
        "imap_mailbox" => "INBOX",
        "imap_poll_interval_ms" => 60_000,
        "smtp_host" => "",
        "smtp_port" => 587,
        "smtp_tls" => true,
        "smtp_username" => "",
        "smtp_password_ref" => "secret://channels/email/smtp_password",
        "from_address" => "",
        "from_name" => "Allbert",
        "identity_map" => [],
        "max_body_bytes" => 65_536,
        "allow_html_replies" => false
      },
      "whatsapp" => %{
        "webhook_enabled" => false,
        "phone_number_id" => "",
        "waba_id" => "",
        "app_secret_ref" => "secret://channels/whatsapp/app_secret",
        "webhook_verify_token_ref" => "secret://channels/whatsapp/webhook_verify_token",
        "webhook_rate_limit" => %{
          "limit" => 60,
          "period_ms" => 60_000,
          "burst" => 10
        }
      }
    },
    "jobs" => %{
      "timezone" => "America/Los_Angeles",
      "default_state" => "paused",
      "schedule_policy" => "operator_approved"
    },
    "sessions" => %{
      "scratchpad_ttl_minutes" => 30
    },
    "active_memory" => %{
      "enabled" => true,
      "top_k" => 5,
      "chunk_max_bytes" => 2048,
      "score_weights" => %{
        "recency_half_life_days" => 30,
        "thread_affinity" => %{
          "same_thread" => 1.0,
          "same_app" => 0.6,
          "general" => 0.3
        },
        "identity_inclusion" => 1.5
      }
    },
    "memory" => %{
      "review_cadence" => "manual",
      "auto_promote_sensitive_entries" => false,
      "retention_policy" => "preserve_markdown",
      "delete_requires_confirmation" => true,
      "prune_requires_confirmation" => true,
      "promotion_requires_confirmation" => true,
      "max_entries_per_category" => 500,
      "index_enabled" => true,
      "max_index_entries" => 1000
    },
    "workspace" => %{
      "theme" => %{
        "mode" => "system",
        "active" => nil,
        "snippets_enabled" => false,
        "enabled_snippets" => []
      },
      "layout" => %{
        "override_enabled" => false
      },
      "canvas" => %{
        "max_tiles_per_thread" => 64,
        "tile_body_max_bytes" => 65_536
      },
      "ephemeral" => %{
        "max_active_per_thread" => 16
      },
      "fragment" => %{
        "signing_secret" => nil,
        "emission_enabled" => true,
        "rate_limit_per_second" => 10,
        "receiver_rate_limit_per_second" => 10,
        "payload_max_bytes" => 65_536
      },
      "offline" => %{
        "enabled" => true,
        "indexeddb_quota_mb" => 32
      },
      "accessibility" => %{
        "high_contrast" => false,
        "reduce_motion" => false
      },
      "mobile" => %{
        "breakpoint_px" => 768
      },
      "agui_bridge" => %{
        "enabled" => true
      },
      "signal_bridge" => %{
        "log_dropped_fragments" => true
      }
    }
  }

  def defaults, do: Fragments.defaults()

  def runtime_schema, do: schema()

  def schema, do: Fragments.schema()

  def safe_write_keys, do: Fragments.safe_write_keys()

  @doc false
  def core_schema, do: @schema

  @doc false
  def core_defaults, do: ProviderCatalog.merge_defaults(@defaults)

  @doc false
  def core_safe_write_keys, do: @safe_write_keys

  def safe_write_key?(key) when is_binary(key) do
    Enum.any?(safe_write_keys(), &key_matches?(&1, key))
  end

  def safe_write_key?(_key), do: false

  def validate_key_value(key, value, settings \\ defaults()) when is_binary(key) do
    cond do
      not known_key?(key) ->
        {:error, {:unknown_setting, key}}

      not safe_write_key?(key) ->
        {:error, {:read_only_setting, key}}

      true ->
        validate_known_key_value(key, value, settings)
    end
  end

  def validate_settings(settings, opts \\ [])

  def validate_settings(settings, _opts) when is_map(settings) do
    with :ok <- reject_unknown_top_level(settings),
         :ok <- validate_static_keys(settings),
         :ok <- validate_providers(settings),
         :ok <- validate_model_profiles(settings),
         :ok <- validate_model_preferences(settings),
         :ok <- validate_mcp(settings),
         :ok <- validate_public_protocol(settings),
         :ok <- validate_runtime_refs(settings),
         :ok <- validate_dynamic_codegen(settings),
         :ok <- validate_templates(settings),
         :ok <- validate_channels(settings) do
      :ok
    end
  end

  def validate_settings(_settings, _opts), do: {:error, {:invalid_settings, :not_a_map}}

  def get_dotted(settings, key) do
    key
    |> split_key()
    |> Enum.reduce_while(settings, fn segment, acc ->
      case acc do
        %{^segment => value} -> {:cont, value}
        _other -> {:halt, nil}
      end
    end)
  end

  def put_dotted(settings, key, value) do
    put_in_segments(settings, split_key(key), value)
  end

  def known_key?(key) do
    Map.has_key?(schema(), key) ||
      wildcard_known_key?(key) ||
      default_key?(key)
  end

  def sensitive_key?(key) do
    if public_protocol_settings_key?(key) do
      false
    else
      key
      |> String.split(~r/[._-]/, trim: true)
      |> Enum.any?(
        &(&1 in ["secret", "token", "password", "api", "key", "private", "credential"])
      )
    end
  end

  defp public_protocol_settings_key?(key) when is_binary(key) do
    String.starts_with?(key, "openai_api.") or
      String.starts_with?(key, "mcp_server.") or
      String.starts_with?(key, "acp_server.") or
      String.starts_with?(key, "public_protocol.")
  end

  defp public_protocol_settings_key?(_key), do: false

  defp validate_known_key_value(key, value, settings) do
    schema_for_key(key)
    |> validate_value(value, key, settings)
    |> case do
      :ok -> :ok
      {:error, reason} -> {:error, {:invalid_setting, key, reason}}
    end
  end

  defp schema_for_key(key) do
    cond do
      schema = Map.get(schema(), key) ->
        schema

      Regex.match?(~r/^providers\.[^.]+\.[^.]+$/, key) ->
        key |> split_key() |> List.last() |> then(&Map.fetch!(@provider_schema, &1))

      Regex.match?(~r/^model_profiles\.[^.]+\.[^.]+$/, key) ->
        key |> split_key() |> List.last() |> then(&Map.fetch!(@model_profile_schema, &1))

      Regex.match?(~r/^model_preferences\.(tasks|capabilities)\.[^.]+$/, key) ->
        %{type: :profile_ref_list}

      Regex.match?(~r/^mcp\.servers\.[^.]+\.[^.]+$/, key) ->
        key |> split_key() |> List.last() |> then(&Map.fetch!(@mcp_server_schema, &1))

      public_protocol_client_key?(key) ->
        key
        |> public_protocol_client_field()
        |> then(&Map.fetch!(@public_protocol_client_schema, &1))
    end
  end

  defp validate_static_keys(settings) do
    schema()
    |> Map.keys()
    |> Enum.reduce_while(:ok, fn key, :ok ->
      case validate_value(schema_for_key(key), get_dotted(settings, key), key, settings) do
        :ok -> {:cont, :ok}
        {:error, reason} -> {:halt, {:error, {:invalid_setting, key, reason}}}
      end
    end)
  end

  defp validate_providers(settings) do
    settings
    |> get_in(["providers"])
    |> case do
      providers when is_map(providers) ->
        validate_dynamic_map(providers, @provider_schema, "providers", settings)

      other ->
        {:error, {:invalid_setting, "providers", {:expected_map, other}}}
    end
  end

  defp validate_model_profiles(settings) do
    settings
    |> get_in(["model_profiles"])
    |> case do
      profiles when is_map(profiles) ->
        with :ok <-
               validate_dynamic_map(profiles, @model_profile_schema, "model_profiles", settings) do
          validate_model_profile_provider_constraints(profiles, settings)
        end

      other ->
        {:error, {:invalid_setting, "model_profiles", {:expected_map, other}}}
    end
  end

  defp validate_model_profile_provider_constraints(profiles, settings) do
    Enum.reduce_while(profiles, :ok, fn {name, attrs}, :ok ->
      case validate_model_profile_provider_constraint(name, attrs, settings) do
        :ok -> {:cont, :ok}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
  end

  defp validate_model_profile_provider_constraint(name, attrs, settings) when is_map(attrs) do
    provider = Map.get(attrs, "provider")
    provider_type = get_in(settings, ["providers", provider, "type"])
    max_tokens = Map.get(attrs, "max_tokens")

    if provider_type == "openai" && is_integer(max_tokens) && max_tokens < 16 do
      {:error,
       {:invalid_setting, "model_profiles.#{name}.max_tokens", {:below_provider_minimum, 16}}}
    else
      :ok
    end
  end

  defp validate_model_profile_provider_constraint(_name, _attrs, _settings), do: :ok

  defp validate_model_preferences(settings) do
    case get_in(settings, ["model_preferences"]) do
      preferences when is_map(preferences) ->
        with :ok <- validate_model_preference_keys(preferences),
             :ok <-
               validate_model_preference_map(
                 get_in(preferences, ["tasks"]),
                 "model_preferences.tasks",
                 :task,
                 settings
               ) do
          validate_model_preference_map(
            get_in(preferences, ["capabilities"]),
            "model_preferences.capabilities",
            :capability,
            settings
          )
        end

      other ->
        {:error, {:invalid_setting, "model_preferences", {:expected_map, other}}}
    end
  end

  defp validate_model_preference_keys(preferences) do
    allowed = ~w[schema_version primary tasks capabilities]

    preferences
    |> Map.keys()
    |> Enum.reject(&(&1 in allowed))
    |> case do
      [] -> :ok
      [key | _rest] -> {:error, {:unknown_setting, "model_preferences.#{key}"}}
    end
  end

  defp validate_model_preference_map(preferences, prefix, kind, settings)
       when is_map(preferences) do
    Enum.reduce_while(preferences, :ok, fn {name, profiles}, :ok ->
      key = "#{prefix}.#{name}"

      with :ok <- validate_model_preference_name(name, key, kind),
           :ok <- validate_value(%{type: :profile_ref_list}, profiles, key, settings) do
        {:cont, :ok}
      else
        {:error, {:invalid_setting, _key, _reason} = reason} ->
          {:halt, {:error, reason}}

        {:error, reason} ->
          {:halt, {:error, {:invalid_setting, key, reason}}}
      end
    end)
  end

  defp validate_model_preference_map(other, prefix, _kind, _settings),
    do: {:error, {:invalid_setting, prefix, {:expected_map, other}}}

  defp validate_model_preference_name(name, key, :task) do
    if valid_name?(name), do: :ok, else: {:error, {:invalid_setting, key, :invalid_name}}
  end

  defp validate_model_preference_name(name, key, :capability) do
    cond do
      not valid_name?(name) ->
        {:error, {:invalid_setting, key, :invalid_name}}

      name not in ProviderCatalog.known_capabilities() ->
        {:error, {:invalid_setting, key, {:unknown_capability, name}}}

      true ->
        :ok
    end
  end

  defp validate_mcp(settings) do
    with :ok <- validate_mcp_launchers(settings),
         :ok <-
           settings
           |> get_in(["mcp", "servers"])
           |> validate_mcp_servers(settings) do
      validate_mcp_discovery(settings)
    end
  end

  defp validate_mcp_servers(servers, settings) when is_map(servers) do
    with :ok <- validate_dynamic_map(servers, @mcp_server_schema, "mcp.servers", settings) do
      validate_mcp_server_constraints(servers, settings)
    end
  end

  defp validate_mcp_servers(other, _settings),
    do: {:error, {:invalid_setting, "mcp.servers", {:expected_map, other}}}

  defp validate_mcp_launchers(settings) do
    launchers = get_dotted(settings, "mcp.stdio.allowed_launchers") || []

    if Enum.all?(launchers, &safe_mcp_launcher?/1) do
      :ok
    else
      {:error, {:invalid_setting, "mcp.stdio.allowed_launchers", :unsafe_launcher}}
    end
  end

  defp validate_mcp_discovery(settings) do
    with :ok <- validate_mcp_discovery_auto_connect(settings) do
      validate_mcp_discovery_pulsemcp(settings)
    end
  end

  defp validate_mcp_discovery_auto_connect(settings) do
    case get_dotted(settings, "mcp.discovery.auto_connect") do
      false ->
        :ok

      value ->
        {:error, {:invalid_setting, "mcp.discovery.auto_connect", {:must_remain_false, value}}}
    end
  end

  defp validate_mcp_discovery_pulsemcp(settings) do
    enabled? = get_dotted(settings, "mcp.discovery.sources.pulsemcp.enabled")
    api_key_ref = get_dotted(settings, "mcp.discovery.sources.pulsemcp.api_key_ref")
    tenant_ref = get_dotted(settings, "mcp.discovery.sources.pulsemcp.tenant_ref")

    cond do
      enabled? != true ->
        :ok

      not is_binary(api_key_ref) ->
        {:error,
         {:invalid_setting, "mcp.discovery.sources.pulsemcp.api_key_ref",
          {:required_when_enabled, api_key_ref}}}

      not is_binary(tenant_ref) ->
        {:error,
         {:invalid_setting, "mcp.discovery.sources.pulsemcp.tenant_ref",
          {:required_when_enabled, tenant_ref}}}

      true ->
        :ok
    end
  end

  defp validate_mcp_server_constraints(servers, settings) do
    Enum.reduce_while(servers, :ok, fn {name, attrs}, :ok ->
      case validate_mcp_server_constraint(name, attrs, settings) do
        :ok -> {:cont, :ok}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
  end

  defp validate_mcp_server_constraint(_name, %{"enabled" => true} = attrs, settings) do
    case Map.get(attrs, "transport") do
      "stdio" -> validate_enabled_stdio_mcp_server(attrs, settings)
      "sse" -> validate_enabled_http_mcp_server(attrs)
      "streamable_http" -> validate_enabled_http_mcp_server(attrs)
      other -> {:error, {:invalid_setting, "mcp.servers.*.transport", {:required, other}}}
    end
  end

  defp validate_mcp_server_constraint(_name, attrs, _settings) when is_map(attrs) do
    validate_disabled_mcp_server_branches(attrs)
  end

  defp validate_mcp_server_constraint(name, _attrs, _settings),
    do: {:error, {:invalid_setting, "mcp.servers.#{name}", :expected_map}}

  defp validate_public_protocol(settings) do
    with :ok <- validate_public_surface_clients(settings, "mcp_server", "mcp_http"),
         :ok <- validate_public_surface_clients(settings, "openai_api", "openai_api") do
      :ok
    end
  end

  defp validate_public_surface_clients(settings, namespace, surface) do
    clients = get_dotted(settings, "#{namespace}.clients") || %{}

    case validate_public_protocol_clients(clients, surface) do
      :ok -> :ok
      {:error, reason} -> {:error, {:invalid_setting, "#{namespace}.clients", reason}}
    end
  end

  defp validate_enabled_stdio_mcp_server(attrs, settings) do
    with :ok <- require_mcp_string(attrs, "command"),
         :ok <- validate_stdio_launcher_allowed(Map.fetch!(attrs, "command"), settings),
         :ok <- forbid_mcp_field(attrs, "base_url"),
         :ok <- forbid_mcp_field(attrs, "headers") do
      :ok
    end
  end

  defp validate_enabled_http_mcp_server(attrs) do
    with :ok <- require_mcp_string(attrs, "base_url"),
         :ok <- forbid_mcp_field(attrs, "command"),
         :ok <- forbid_mcp_field(attrs, "args"),
         :ok <- forbid_mcp_field(attrs, "env") do
      :ok
    end
  end

  defp validate_disabled_mcp_server_branches(%{"transport" => "stdio"} = attrs) do
    with :ok <- forbid_mcp_field(attrs, "base_url") do
      forbid_mcp_field(attrs, "headers")
    end
  end

  defp validate_disabled_mcp_server_branches(%{"transport" => transport} = attrs)
       when transport in ["sse", "streamable_http"] do
    with :ok <- forbid_mcp_field(attrs, "command"),
         :ok <- forbid_mcp_field(attrs, "args") do
      forbid_mcp_field(attrs, "env")
    end
  end

  defp validate_disabled_mcp_server_branches(_attrs), do: :ok

  defp require_mcp_string(attrs, field) do
    case Map.get(attrs, field) do
      value when is_binary(value) and value != "" -> :ok
      value -> {:error, {:invalid_setting, "mcp.servers.*.#{field}", {:required, value}}}
    end
  end

  defp forbid_mcp_field(attrs, field) do
    case Map.get(attrs, field) do
      nil -> :ok
      [] -> :ok
      value -> {:error, {:invalid_setting, "mcp.servers.*.#{field}", {:forbidden, value}}}
    end
  end

  defp validate_stdio_launcher_allowed(command, settings) do
    allowed = get_dotted(settings, "mcp.stdio.allowed_launchers") || []

    if command in allowed do
      :ok
    else
      {:error, {:invalid_setting, "mcp.servers.*.command", {:launcher_not_allowed, command}}}
    end
  end

  defp validate_dynamic_map(items, field_schema, prefix, settings) do
    Enum.reduce_while(items, :ok, &validate_dynamic_item(&1, &2, field_schema, prefix, settings))
  end

  defp validate_dynamic_item({name, attrs}, :ok, field_schema, prefix, settings) do
    dynamic_prefix = "#{prefix}.#{name}"

    with :ok <- validate_dynamic_name(name, dynamic_prefix),
         :ok <- validate_dynamic_map_attrs(attrs, dynamic_prefix),
         :ok <- validate_dynamic_attrs(attrs, field_schema, dynamic_prefix, settings) do
      {:cont, :ok}
    else
      {:error, reason} -> {:halt, {:error, reason}}
    end
  end

  defp validate_dynamic_name(name, prefix) do
    if valid_name?(name), do: :ok, else: {:error, {:invalid_setting, prefix, :invalid_name}}
  end

  defp validate_dynamic_map_attrs(attrs, prefix) do
    if is_map(attrs), do: :ok, else: {:error, {:invalid_setting, prefix, :expected_map}}
  end

  defp validate_dynamic_attrs(attrs, field_schema, prefix, settings) do
    Enum.reduce_while(attrs, :ok, &validate_dynamic_attr(&1, &2, field_schema, prefix, settings))
  end

  defp validate_dynamic_attr({field, value}, :ok, field_schema, prefix, settings) do
    key = "#{prefix}.#{field}"

    with {:ok, schema} <- fetch_dynamic_schema(field_schema, field, key),
         :ok <- validate_value(schema, value, key, settings) do
      {:cont, :ok}
    else
      {:error, {:unknown_setting, _key} = reason} -> {:halt, {:error, reason}}
      {:error, reason} -> {:halt, {:error, {:invalid_setting, key, reason}}}
    end
  end

  defp fetch_dynamic_schema(field_schema, field, key) do
    case Map.fetch(field_schema, field) do
      {:ok, schema} -> {:ok, schema}
      :error -> {:error, {:unknown_setting, key}}
    end
  end

  defp validate_runtime_refs(settings) do
    alias_name = get_dotted(settings, "runtime.model_alias")

    if is_map(get_in(settings, ["model_profiles"])) &&
         Map.has_key?(settings["model_profiles"], alias_name) do
      :ok
    else
      {:error, {:invalid_setting, "runtime.model_alias", {:unknown_model_profile, alias_name}}}
    end
  end

  defp validate_value(%{type: :string}, value, _key, _settings) when is_binary(value) do
    if String.trim(value) == "" or String.length(value) > 200 do
      {:error, :invalid_string}
    else
      :ok
    end
  end

  defp validate_value(%{type: :string}, value, _key, _settings),
    do: {:error, {:expected_string, value}}

  defp validate_value(%{type: :loopback_http_base_url}, value, _key, _settings)
       when is_binary(value) do
    uri = value |> String.trim() |> URI.parse()

    case loopback_http_base_url_error(uri) do
      nil -> :ok
      reason -> {:error, {:expected_loopback_http_base_url, reason}}
    end
  end

  defp validate_value(%{type: :loopback_http_base_url}, value, _key, _settings),
    do: {:error, {:expected_loopback_http_base_url, value}}

  defp validate_value(%{type: :string_or_empty}, value, _key, _settings)
       when is_binary(value) do
    if String.length(value) <= 200, do: :ok, else: {:error, :invalid_string}
  end

  defp validate_value(%{type: :string_or_empty}, value, _key, _settings),
    do: {:error, {:expected_string, value}}

  defp validate_value(%{type: :loopback_bind_host}, value, _key, _settings)
       when is_binary(value) do
    if value in ["127.0.0.1", "localhost", "::1"] do
      :ok
    else
      {:error, {:expected_loopback_bind_host, value}}
    end
  end

  defp validate_value(%{type: :loopback_bind_host}, value, _key, _settings),
    do: {:error, {:expected_loopback_bind_host, value}}

  defp validate_value(%{type: :port_or_nil}, nil, _key, _settings), do: :ok

  defp validate_value(%{type: :port_or_nil}, value, _key, _settings) when is_integer(value) do
    if value >= 1 and value <= 65_535, do: :ok, else: {:error, {:out_of_range, 1, 65_535}}
  end

  defp validate_value(%{type: :port_or_nil}, value, _key, _settings),
    do: {:error, {:expected_port_or_nil, value}}

  defp validate_value(%{type: :public_api_path_prefix}, value, _key, _settings)
       when is_binary(value) do
    if Regex.match?(~r/^\/[A-Za-z0-9_\/-]*$/, value) and value == "/v1" do
      :ok
    else
      {:error, {:expected_public_api_path_prefix, "/v1"}}
    end
  end

  defp validate_value(%{type: :public_api_path_prefix}, value, _key, _settings),
    do: {:error, {:expected_public_api_path_prefix, value}}

  defp validate_value(%{type: :email_or_empty}, "", _key, _settings), do: :ok

  defp validate_value(%{type: :email_or_empty}, value, _key, _settings)
       when is_binary(value) do
    if valid_email?(value), do: :ok, else: {:error, :invalid_email}
  end

  defp validate_value(%{type: :email_or_empty}, value, _key, _settings),
    do: {:error, {:expected_email, value}}

  defp validate_value(%{type: :timezone}, value, _key, _settings) when is_binary(value) do
    case DateTime.now(value) do
      {:ok, _datetime} -> :ok
      {:error, :utc_only_time_zone_database} -> validate_timezone_name(value)
      {:error, reason} -> {:error, {:invalid_timezone, reason}}
    end
  end

  defp validate_value(%{type: :timezone}, value, _key, _settings),
    do: {:error, {:expected_timezone, value}}

  defp validate_value(%{type: :enum, allowed_values: values}, value, _key, _settings) do
    if value in values, do: :ok, else: {:error, {:allowed_values, values}}
  end

  defp validate_value(%{type: :boolean}, value, _key, _settings) when is_boolean(value), do: :ok

  defp validate_value(%{type: :boolean}, value, _key, _settings),
    do: {:error, {:expected_boolean, value}}

  defp validate_value(%{type: :string_or_nil}, nil, _key, _settings), do: :ok

  defp validate_value(%{type: :string_or_nil}, value, _key, _settings) when is_binary(value),
    do: :ok

  defp validate_value(%{type: :string_or_nil}, value, _key, _settings),
    do: {:error, {:expected_string_or_nil, value}}

  defp validate_value(%{type: :hex_secret_or_nil}, nil, _key, _settings), do: :ok

  defp validate_value(%{type: :hex_secret_or_nil}, value, _key, _settings)
       when is_binary(value) do
    if Regex.match?(~r/^[0-9a-fA-F]{64}$/, value) do
      :ok
    else
      {:error, :invalid_hex_secret}
    end
  end

  defp validate_value(%{type: :hex_secret_or_nil}, value, _key, _settings),
    do: {:error, {:expected_hex_secret_or_nil, value}}

  defp validate_value(%{type: :string_list}, value, _key, _settings) when is_list(value) do
    if Enum.all?(value, &valid_string_list_item?/1) do
      :ok
    else
      {:error, {:expected_string_list, value}}
    end
  end

  defp validate_value(%{type: :string_list}, value, _key, _settings),
    do: {:error, {:expected_string_list, value}}

  defp validate_value(%{type: :public_tool_list}, value, _key, _settings) when is_list(value) do
    case ExposureFilter.filter_tools(value) do
      {:ok, _tools} -> :ok
      {:error, reason} -> {:error, reason}
    end
  end

  defp validate_value(%{type: :public_tool_list}, value, _key, _settings),
    do: {:error, {:expected_public_tool_list, value}}

  defp validate_value(%{type: :public_memory_namespace_list}, value, _key, _settings)
       when is_list(value) do
    case ExposureFilter.filter_memory_namespaces(value) do
      {:ok, _namespaces} -> :ok
      {:error, reason} -> {:error, reason}
    end
  end

  defp validate_value(%{type: :public_memory_namespace_list}, value, _key, _settings),
    do: {:error, {:expected_public_memory_namespace_list, value}}

  defp validate_value(%{type: :public_protocol_clients, surface: surface}, value, _key, _settings)
       when is_map(value) do
    validate_public_protocol_clients(value, surface)
  end

  defp validate_value(%{type: :public_protocol_clients}, value, _key, _settings),
    do: {:error, {:expected_public_protocol_clients, value}}

  defp validate_value(%{type: :public_protocol_secret_ref}, value, _key, _settings)
       when is_binary(value) do
    if TokenAuth.public_protocol_secret_ref?(value) do
      :ok
    else
      {:error, :invalid_public_protocol_secret_ref}
    end
  end

  defp validate_value(%{type: :public_protocol_secret_ref}, value, _key, _settings),
    do: {:error, {:expected_public_protocol_secret_ref, value}}

  defp validate_value(%{type: :model_capabilities}, value, _key, _settings),
    do: ProviderCatalog.validate_capabilities(value)

  defp validate_value(%{type: :model_media}, value, _key, _settings),
    do: ProviderCatalog.validate_media(value)

  defp validate_value(%{type: :http_methods}, value, _key, _settings) when is_list(value) do
    allowed = ["GET", "HEAD", "POST", "PUT", "PATCH", "DELETE"]

    if value != [] and Enum.all?(value, &(&1 in allowed)) do
      :ok
    else
      {:error, {:expected_http_methods, allowed}}
    end
  end

  defp validate_value(%{type: :http_methods}, value, _key, _settings),
    do: {:error, {:expected_http_methods, value}}

  defp validate_value(%{type: :external_service_profiles}, value, _key, _settings)
       when is_map(value) do
    Enum.reduce_while(value, :ok, fn {name, profile}, :ok ->
      case validate_external_service_profile(name, profile) do
        :ok -> {:cont, :ok}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
  end

  defp validate_value(%{type: :external_service_profiles}, value, _key, _settings),
    do: {:error, {:expected_external_service_profiles, value}}

  defp validate_value(%{type: :command_profiles}, value, _key, _settings)
       when is_map(value) do
    Enum.reduce_while(value, :ok, fn {name, profile}, :ok ->
      case validate_command_profile(name, profile) do
        :ok -> {:cont, :ok}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
  end

  defp validate_value(%{type: :command_profiles}, value, _key, _settings),
    do: {:error, {:expected_command_profiles, value}}

  defp validate_value(%{type: :interpreter_profiles}, value, _key, _settings)
       when is_map(value) do
    Enum.reduce_while(value, :ok, fn {name, profile}, :ok ->
      case validate_interpreter_profile(name, profile) do
        :ok -> {:cont, :ok}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
  end

  defp validate_value(%{type: :interpreter_profiles}, value, _key, _settings),
    do: {:error, {:expected_interpreter_profiles, value}}

  defp validate_value(%{type: :package_manager_profiles}, value, _key, _settings)
       when is_map(value) do
    Enum.reduce_while(value, :ok, fn {name, profile}, :ok ->
      case validate_package_manager_profile(name, profile) do
        :ok -> {:cont, :ok}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
  end

  defp validate_value(%{type: :package_manager_profiles}, value, _key, _settings),
    do: {:error, {:expected_package_manager_profiles, value}}

  defp validate_value(%{type: :resource_grants}, value, _key, _settings) when is_list(value) do
    Enum.reduce_while(value, :ok, fn grant, :ok ->
      case validate_resource_grant(grant) do
        :ok -> {:cont, :ok}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
  end

  defp validate_value(%{type: :resource_grants}, value, _key, _settings),
    do: {:error, {:expected_resource_grants, value}}

  defp validate_value(%{type: :url_or_nil}, nil, _key, _settings), do: :ok

  defp validate_value(%{type: :url_or_nil}, value, _key, _settings) when is_binary(value) do
    uri = URI.parse(value)

    if uri.scheme in ["http", "https"] and is_binary(uri.host) and uri.host != "" do
      :ok
    else
      {:error, :invalid_url}
    end
  end

  defp validate_value(%{type: :url_or_nil}, value, _key, _settings),
    do: {:error, {:expected_url, value}}

  defp validate_value(%{type: :secret_ref_or_nil}, nil, _key, _settings), do: :ok

  defp validate_value(%{type: :secret_ref_or_nil}, value, _key, _settings)
       when is_binary(value) do
    if Regex.match?(~r/^secret:\/\/providers\/[A-Za-z0-9_-]+\/api_key$/, value) do
      :ok
    else
      {:error, :invalid_secret_ref}
    end
  end

  defp validate_value(%{type: :secret_ref_or_nil}, value, _key, _settings),
    do: {:error, {:expected_secret_ref, value}}

  defp validate_value(%{type: :channel_secret_ref}, value, _key, _settings)
       when is_binary(value) do
    if Regex.match?(~r/^secret:\/\/channels\/[A-Za-z0-9_-]+\/[A-Za-z0-9_-]+$/, value) do
      :ok
    else
      {:error, :invalid_secret_ref}
    end
  end

  defp validate_value(%{type: :channel_secret_ref}, value, _key, _settings),
    do: {:error, {:expected_secret_ref, value}}

  defp validate_value(%{type: :mcp_secret_ref_or_nil}, nil, _key, _settings), do: :ok

  defp validate_value(%{type: :mcp_secret_ref_or_nil}, value, _key, _settings)
       when is_binary(value) do
    if mcp_secret_ref?(value) do
      :ok
    else
      {:error, :invalid_secret_ref}
    end
  end

  defp validate_value(%{type: :mcp_secret_ref_or_nil}, value, _key, _settings),
    do: {:error, {:expected_secret_ref, value}}

  defp validate_value(%{type: :mcp_secret_ref_string_map}, value, _key, _settings)
       when is_map(value) do
    value
    |> Enum.reduce_while(:ok, fn {name, entry}, :ok ->
      cond do
        not valid_string_map_key?(name) ->
          {:halt, {:error, {:invalid_string_map_key, name}}}

        not is_binary(entry) ->
          {:halt, {:error, {:expected_string_map_value, name}}}

        secret_like_key?(name) and not mcp_secret_ref?(entry) ->
          {:halt, {:error, {:secret_value_requires_ref, name}}}

        true ->
          {:cont, :ok}
      end
    end)
  end

  defp validate_value(%{type: :mcp_secret_ref_string_map}, value, _key, _settings),
    do: {:error, {:expected_string_map, value}}

  defp validate_value(%{type: :channel_identity_map}, value, _key, _settings)
       when is_list(value) do
    validate_channel_identity_map(value)
  end

  defp validate_value(%{type: :channel_identity_map}, value, _key, _settings),
    do: {:error, {:expected_channel_identity_map, value}}

  defp validate_value(%{type: :provider_ref}, value, _key, settings) when is_binary(value) do
    if is_map(settings["providers"]) && Map.has_key?(settings["providers"], value) do
      :ok
    else
      {:error, {:unknown_provider, value}}
    end
  end

  defp validate_value(%{type: :profile_ref}, value, _key, settings) when is_binary(value) do
    if is_map(settings["model_profiles"]) && Map.has_key?(settings["model_profiles"], value) do
      :ok
    else
      {:error, {:unknown_model_profile, value}}
    end
  end

  defp validate_value(%{type: :profile_ref_list}, value, _key, settings) when is_list(value) do
    profiles = settings["model_profiles"]

    if is_map(profiles) and Enum.all?(value, &(is_binary(&1) and Map.has_key?(profiles, &1))) do
      :ok
    else
      {:error, {:unknown_model_profile_in_list, value}}
    end
  end

  defp validate_value(%{type: :profile_ref_list}, value, _key, _settings),
    do: {:error, {:expected_profile_ref_list, value}}

  defp validate_value(%{type: :temperature}, value, _key, _settings) when is_number(value) do
    if value >= 0.0 and value <= 2.0, do: :ok, else: {:error, :out_of_range}
  end

  defp validate_value(%{type: :temperature}, value, _key, _settings),
    do: {:error, {:expected_number, value}}

  defp validate_value(%{type: :positive_integer}, value, _key, _settings)
       when is_integer(value) do
    if value >= 1 and value <= 100_000_000, do: :ok, else: {:error, :out_of_range}
  end

  defp validate_value(%{type: :bounded_integer, min: min, max: max}, value, _key, _settings)
       when is_integer(value) do
    if value >= min and value <= max, do: :ok, else: {:error, {:out_of_range, min, max}}
  end

  defp validate_value(%{type: :bounded_float, min: min, max: max}, value, _key, _settings)
       when is_number(value) do
    if value >= min and value <= max, do: :ok, else: {:error, {:out_of_range, min, max}}
  end

  defp validate_value(%{type: :bounded_float}, value, _key, _settings),
    do: {:error, {:expected_number, value}}

  defp validate_value(%{type: :non_negative_integer}, value, _key, _settings)
       when is_integer(value) do
    if value >= 0 and value <= 200_000, do: :ok, else: {:error, :out_of_range}
  end

  defp validate_value(%{type: :non_negative_integer_or_nil}, nil, _key, _settings), do: :ok

  defp validate_value(%{type: :non_negative_integer_or_nil}, value, key, settings),
    do: validate_value(%{type: :non_negative_integer}, value, key, settings)

  defp validate_value(%{type: :timeout_ms}, value, _key, _settings) when is_integer(value) do
    if value >= 1_000 and value <= 600_000, do: :ok, else: {:error, :out_of_range}
  end

  defp validate_value(schema, value, _key, _settings),
    do: {:error, {:invalid_value, schema.type, value}}

  defp loopback_http_base_url_error(uri) do
    [
      {uri.scheme not in ["http", "https"], :invalid_scheme},
      {not is_binary(uri.host) or uri.host == "", :missing_host},
      {is_binary(uri.userinfo) and uri.userinfo != "", :credentials_denied},
      {is_binary(uri.query) and uri.query != "", :query_denied},
      {is_binary(uri.fragment) and uri.fragment != "", :fragment_denied},
      {not loopback_setting_host?(uri.host), :non_loopback_host}
    ]
    |> Enum.find_value(fn
      {true, reason} -> reason
      {false, _reason} -> nil
    end)
  end

  defp validate_dynamic_codegen(settings) do
    with :ok <-
           validate_dynamic_codegen_list(
             settings,
             "dynamic_codegen.allowed_targets",
             ["action"]
           ),
         :ok <-
           validate_dynamic_codegen_list(
             settings,
             "dynamic_codegen.allowed_action_permissions",
             ["read_only", "memory_write", "external_network"]
           ),
         :ok <-
           validate_dynamic_codegen_list(
             settings,
             "dynamic_codegen.allowed_facades",
             ["append_memory", "external_network_request"],
             allow_empty?: true
           ) do
      validate_dynamic_codegen_list(
        settings,
        "dynamic_codegen.integration_approval_surfaces",
        ["cli", "liveview"]
      )
    end
  end

  defp validate_dynamic_codegen_list(settings, key, allowed_values, opts \\ []) do
    values = get_dotted(settings, key)
    allow_empty? = Keyword.get(opts, :allow_empty?, false)

    cond do
      not is_list(values) ->
        {:error, {:invalid_setting, key, {:expected_string_list, values}}}

      values == [] and not allow_empty? ->
        {:error, {:invalid_setting, key, :empty_list}}

      not Enum.all?(values, &(&1 in allowed_values)) ->
        {:error, {:invalid_setting, key, {:allowed_values, allowed_values}}}

      true ->
        :ok
    end
  end

  defp validate_templates(settings) do
    allowed_values = ~w[plugin app llm_tool flow objective]
    values = get_dotted(settings, "templates.allowed_patterns") || []

    cond do
      not is_list(values) ->
        {:error,
         {:invalid_setting, "templates.allowed_patterns", {:expected_string_list, values}}}

      not Enum.all?(values, &(&1 in allowed_values)) ->
        {:error,
         {:invalid_setting, "templates.allowed_patterns", {:allowed_values, allowed_values}}}

      true ->
        :ok
    end
  end

  defp validate_channels(settings) do
    with :ok <- validate_enabled_telegram(settings),
         :ok <- validate_enabled_email(settings) do
      :ok
    end
  end

  defp validate_enabled_telegram(settings) do
    if get_dotted(settings, "channels.telegram.enabled") do
      case get_dotted(settings, "channels.telegram.bot_token_ref") do
        value when is_binary(value) and value != "" ->
          :ok

        value ->
          {:error, {:invalid_setting, "channels.telegram.bot_token_ref", {:required, value}}}
      end
    else
      :ok
    end
  end

  defp validate_enabled_email(settings) do
    if get_dotted(settings, "channels.email.enabled") do
      with :ok <- require_non_empty_setting(settings, "channels.email.imap_host"),
           :ok <- require_non_empty_setting(settings, "channels.email.smtp_host"),
           :ok <- require_non_empty_setting(settings, "channels.email.imap_username"),
           :ok <- require_non_empty_setting(settings, "channels.email.smtp_username"),
           :ok <- require_non_empty_setting(settings, "channels.email.imap_password_ref"),
           :ok <- require_non_empty_setting(settings, "channels.email.smtp_password_ref"),
           :ok <- require_non_empty_setting(settings, "channels.email.from_address"),
           true <-
             get_dotted(settings, "channels.email.imap_ssl") ||
               {:error, {:invalid_setting, "channels.email.imap_ssl", :required}},
           true <-
             get_dotted(settings, "channels.email.smtp_tls") ||
               {:error, {:invalid_setting, "channels.email.smtp_tls", :required}} do
        :ok
      else
        {:error, reason} -> {:error, reason}
      end
    else
      :ok
    end
  end

  defp require_non_empty_setting(settings, key) do
    case get_dotted(settings, key) do
      value when is_binary(value) and value != "" -> :ok
      value -> {:error, {:invalid_setting, key, {:required, value}}}
    end
  end

  defp validate_channel_identity_map(entries) do
    Enum.reduce_while(entries, MapSet.new(), fn entry, seen ->
      with :ok <- validate_channel_identity_entry(entry),
           external_user_id <- identity_field(entry, "external_user_id"),
           false <- MapSet.member?(seen, external_user_id) do
        {:cont, MapSet.put(seen, external_user_id)}
      else
        true ->
          {:halt,
           {:error, {:duplicate_external_user_id, identity_field(entry, "external_user_id")}}}

        {:error, reason} ->
          {:halt, {:error, reason}}
      end
    end)
    |> case do
      %MapSet{} -> :ok
      {:error, reason} -> {:error, reason}
    end
  end

  defp validate_channel_identity_entry(entry) when is_map(entry) do
    allowed = ~w[external_user_id user_id display_name enabled]
    keys = Map.keys(entry) |> Enum.map(&to_string/1)

    with nil <- Enum.find(keys, &(&1 not in allowed)),
         :ok <- validate_identity_string(entry, "external_user_id"),
         :ok <- validate_identity_string(entry, "user_id"),
         :ok <- validate_optional_identity_string(entry, "display_name"),
         :ok <- validate_optional_identity_boolean(entry, "enabled") do
      :ok
    else
      key when is_binary(key) -> {:error, {:channel_identity_unknown_key, key}}
      {:error, reason} -> {:error, reason}
    end
  end

  defp validate_channel_identity_entry(entry), do: {:error, {:invalid_channel_identity, entry}}

  defp validate_public_protocol_clients(clients, surface) when is_map(clients) do
    Enum.reduce_while(clients, :ok, fn {client_id, attrs}, :ok ->
      case validate_public_protocol_client(client_id, attrs, surface) do
        :ok -> {:cont, :ok}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
  end

  defp validate_public_protocol_clients(clients, _surface),
    do: {:error, {:expected_public_protocol_clients, clients}}

  defp validate_public_protocol_client(client_id, attrs, surface) when is_map(attrs) do
    with :ok <- TokenAuth.validate_client_id(client_id),
         :ok <- validate_public_protocol_client_keys(attrs),
         :ok <- validate_public_protocol_client_enabled(attrs),
         :ok <- validate_public_protocol_client_token_ref(client_id, attrs, surface) do
      validate_public_protocol_rate_limit(Map.get(attrs, "rate_limit", %{}))
    end
  end

  defp validate_public_protocol_client(client_id, _attrs, _surface),
    do: {:error, {:invalid_public_protocol_client, client_id, :expected_map}}

  defp validate_public_protocol_client_keys(attrs) do
    allowed = ~w[enabled token_ref rate_limit]

    attrs
    |> Map.keys()
    |> Enum.map(&to_string/1)
    |> Enum.find(&(&1 not in allowed))
    |> case do
      nil -> :ok
      key -> {:error, {:public_protocol_client_unknown_key, key}}
    end
  end

  defp validate_public_protocol_client_enabled(attrs) do
    case Map.get(attrs, "enabled", Map.get(attrs, :enabled, false)) do
      value when is_boolean(value) -> :ok
      value -> {:error, {:public_protocol_client_invalid_enabled, value}}
    end
  end

  defp validate_public_protocol_client_token_ref(client_id, attrs, surface) do
    enabled? = Map.get(attrs, "enabled", Map.get(attrs, :enabled, false))

    case Map.get(attrs, "token_ref", Map.get(attrs, :token_ref)) do
      value when is_binary(value) ->
        validate_public_protocol_client_token_ref_value(value, surface, client_id)

      nil when enabled? == false ->
        :ok

      value ->
        {:error, {:public_protocol_client_invalid_token_ref, value}}
    end
  end

  defp validate_public_protocol_client_token_ref_value(value, surface, client_id) do
    case TokenAuth.parse_secret_ref(value) do
      {:ok, ^surface, ^client_id, "bearer_token"} ->
        :ok

      {:ok, other_surface, other_client_id, _name} ->
        {:error, {:token_ref_mismatch, other_surface, other_client_id}}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp validate_public_protocol_rate_limit(rate_limit) when is_map(rate_limit) do
    allowed = ~w[limit period_ms burst]

    with nil <- Enum.find(Map.keys(rate_limit), &(to_string(&1) not in allowed)),
         :ok <- validate_optional_rate_limit_field(rate_limit, "limit", 1, 10_000),
         :ok <- validate_optional_rate_limit_field(rate_limit, "period_ms", 100, 86_400_000) do
      validate_optional_rate_limit_field(rate_limit, "burst", 0, 10_000)
    else
      key when is_binary(key) -> {:error, {:public_protocol_rate_limit_unknown_key, key}}
      {:error, reason} -> {:error, reason}
    end
  end

  defp validate_public_protocol_rate_limit(rate_limit),
    do: {:error, {:public_protocol_rate_limit_expected_map, rate_limit}}

  defp validate_optional_rate_limit_field(rate_limit, key, min, max) do
    case Map.get(rate_limit, key, Map.get(rate_limit, String.to_atom(key))) do
      nil -> :ok
      value when is_integer(value) and value >= min and value <= max -> :ok
      value -> {:error, {:public_protocol_rate_limit_out_of_range, key, value, min, max}}
    end
  end

  defp validate_identity_string(entry, key) do
    value = identity_field(entry, key)

    if is_binary(value) and String.trim(value) != "" and String.length(value) <= 200 do
      :ok
    else
      {:error, {:channel_identity_invalid_string, key}}
    end
  end

  defp validate_optional_identity_string(entry, key) do
    case identity_field(entry, key) do
      nil -> :ok
      value when is_binary(value) and byte_size(value) <= 200 -> :ok
      _value -> {:error, {:channel_identity_invalid_string, key}}
    end
  end

  defp validate_optional_identity_boolean(entry, key) do
    case identity_field(entry, key) do
      nil -> :ok
      value when is_boolean(value) -> :ok
      _value -> {:error, {:channel_identity_invalid_boolean, key}}
    end
  end

  defp identity_field(entry, key), do: Map.get(entry, key, Map.get(entry, String.to_atom(key)))

  defp validate_resource_grant(grant) when is_map(grant) do
    with :ok <- validate_resource_grant_keys(grant),
         :ok <- validate_resource_grant_identity(grant),
         :ok <- validate_resource_grant_scope(grant),
         :ok <- validate_resource_grant_times(grant),
         :ok <- validate_optional_string_field(grant, "id"),
         :ok <- validate_optional_string_field(grant, "downstream_consumer"),
         :ok <- validate_optional_string_field(grant, "action_permission"),
         :ok <- validate_optional_string_field(grant, "origin_channel"),
         :ok <- validate_optional_string_field(grant, "resolver_channel"),
         :ok <- validate_optional_string_field(grant, "audit_path"),
         :ok <- validate_optional_string_field(grant, "reason") do
      validate_resource_grant_metadata(grant)
    end
  end

  defp validate_resource_grant(grant), do: {:error, {:invalid_resource_grant, grant}}

  defp validate_resource_grant_keys(grant) do
    keys = Map.keys(grant) |> Enum.map(&to_string/1)

    cond do
      missing = Enum.find(@resource_grant_required_keys, &(&1 not in keys)) ->
        {:error, {:resource_grant_missing_key, missing}}

      unknown = Enum.find(keys, &(&1 not in @resource_grant_allowed_keys)) ->
        {:error, {:resource_grant_unknown_key, unknown}}

      true ->
        :ok
    end
  end

  defp validate_resource_grant_identity(grant) do
    with {:ok, resource_uri} <-
           ResourceURI.normalize(resource_grant_field(grant, "resource_uri")),
         {:ok, derived} <- ResourceURI.derived_fields(resource_uri),
         {:ok, origin_kind} <-
           OperationClass.origin_kind(resource_grant_field(grant, "origin_kind")),
         {:ok, _operation_class} <-
           OperationClass.operation_class(resource_grant_field(grant, "operation_class")),
         {:ok, _access_mode} <-
           OperationClass.access_mode(resource_grant_field(grant, "access_mode")),
         true <-
           origin_kind == derived.origin_kind ||
             {:error, {:resource_uri_origin_kind_mismatch, origin_kind, derived.origin_kind}} do
      :ok
    else
      {:error, reason} -> {:error, reason}
    end
  end

  defp validate_resource_grant_scope(grant) do
    scope = resource_grant_field(grant, "scope")

    with true <- is_map(scope) || {:error, {:resource_grant_invalid_scope, scope}},
         {:ok, _scope} <-
           Scope.new(
             resource_grant_scope_field(scope, "kind"),
             resource_grant_scope_field(scope, "value")
           ) do
      :ok
    else
      {:error, reason} -> {:error, reason}
    end
  end

  defp validate_resource_grant_times(grant) do
    with :ok <-
           validate_required_datetime(resource_grant_field(grant, "created_at"), "created_at"),
         :ok <-
           validate_optional_datetime(resource_grant_field(grant, "expires_at"), "expires_at") do
      validate_optional_datetime(resource_grant_field(grant, "revoked_at"), "revoked_at")
    end
  end

  defp validate_required_datetime(value, key) when is_binary(value) do
    case DateTime.from_iso8601(value) do
      {:ok, _datetime, _offset} -> :ok
      {:error, reason} -> {:error, {:resource_grant_invalid_datetime, key, reason}}
    end
  end

  defp validate_required_datetime(value, key),
    do: {:error, {:resource_grant_invalid_datetime, key, value}}

  defp validate_optional_datetime(value, _key) when value in [nil, ""], do: :ok
  defp validate_optional_datetime(value, key), do: validate_required_datetime(value, key)

  defp validate_optional_string_field(grant, key) do
    case resource_grant_field(grant, key) do
      nil -> :ok
      value when is_binary(value) -> validate_non_empty_resource_grant_string(value, key)
      value -> {:error, {:resource_grant_expected_string, key, value}}
    end
  end

  defp validate_non_empty_resource_grant_string(value, key) do
    if String.trim(value) == "" do
      {:error, {:resource_grant_empty_string, key}}
    else
      :ok
    end
  end

  defp validate_resource_grant_metadata(grant) do
    case resource_grant_field(grant, "metadata", %{}) do
      metadata when is_map(metadata) -> :ok
      metadata -> {:error, {:resource_grant_expected_metadata_map, metadata}}
    end
  end

  defp resource_grant_field(map, key, default \\ nil) when is_map(map) do
    Map.get(map, key, Map.get(map, Map.fetch!(@resource_grant_atom_keys, key), default))
  end

  defp resource_grant_scope_field(map, key) when is_map(map) do
    Map.get(map, key, Map.get(map, String.to_existing_atom(key)))
  rescue
    ArgumentError -> nil
  end

  defp validate_timezone_name("UTC"), do: :ok

  defp validate_timezone_name(value) do
    if Regex.match?(~r/^[A-Za-z_]+\/[A-Za-z0-9_+\-]+(?:\/[A-Za-z0-9_+\-]+)?$/, value) do
      :ok
    else
      {:error, :invalid_timezone}
    end
  end

  defp reject_unknown_top_level(settings) do
    known = MapSet.new(Map.keys(defaults()))

    settings
    |> Map.keys()
    |> Enum.reject(&MapSet.member?(known, &1))
    |> case do
      [] -> :ok
      [key | _rest] -> {:error, {:unknown_setting, key}}
    end
  end

  defp wildcard_known_key?(key) do
    Regex.match?(~r/^providers\.[^.]+\.(type|enabled|endpoint_kind|base_url|api_key_ref)$/, key) ||
      Regex.match?(
        ~r/^model_profiles\.[^.]+\.(provider|model|aliases|capabilities|media|temperature|max_tokens|timeout_ms)$/,
        key
      ) ||
      Regex.match?(~r/^model_preferences\.(tasks|capabilities)\.[^.]+$/, key) ||
      Regex.match?(
        ~r/^mcp\.servers\.[^.]+\.(enabled|transport|command|args|env|base_url|headers|auth_ref|tool_allowlist|tool_denylist|confirmation)$/,
        key
      ) ||
      Regex.match?(
        ~r/^(mcp_server|openai_api)\.clients\.[^.]+\.(enabled|token_ref|rate_limit\.(limit|period_ms|burst))$/,
        key
      )
  end

  defp public_protocol_client_key?(key) do
    Regex.match?(
      ~r/^(mcp_server|openai_api)\.clients\.[^.]+\.(enabled|token_ref|rate_limit\.(limit|period_ms|burst))$/,
      key
    )
  end

  defp public_protocol_client_field(key) do
    key
    |> split_key()
    |> Enum.drop(3)
    |> Enum.join(".")
  end

  defp default_key?(key) do
    defaults()
    |> flatten_default_keys()
    |> MapSet.member?(key)
  end

  defp flatten_default_keys(map, prefix \\ [])

  defp flatten_default_keys(map, prefix) when is_map(map) do
    map
    |> Enum.flat_map(fn {key, value} -> flatten_default_keys(value, prefix ++ [key]) end)
    |> MapSet.new()
  end

  defp flatten_default_keys(_value, prefix), do: [Enum.join(prefix, ".")]

  defp key_matches?(pattern, key) do
    pattern_parts = split_key(pattern)
    key_parts = split_key(key)

    length(pattern_parts) == length(key_parts) &&
      Enum.zip(pattern_parts, key_parts)
      |> Enum.all?(fn
        {"*", part} -> part != ""
        {part, part} -> true
        _other -> false
      end)
  end

  defp split_key(key), do: String.split(key, ".", trim: true)

  @doc false
  def app_schema do
    :app
    |> safe_registered_settings()
    |> Enum.flat_map(&normalize_app_schema_entry/1)
    |> Map.new()
  end

  @doc false
  def app_defaults do
    app_schema()
    |> Enum.reduce(%{}, fn {key, schema}, defaults ->
      put_dotted(defaults, key, Map.fetch!(schema, :default))
    end)
  end

  @doc false
  def app_safe_write_keys do
    app_schema()
    |> Enum.filter(fn {_key, schema} -> Map.get(schema, :writable?, true) end)
    |> Enum.map(fn {key, _schema} -> key end)
  end

  @doc false
  def plugin_schema do
    :plugin
    |> safe_registered_settings()
    |> Enum.flat_map(&normalize_plugin_schema_entry(&1, []))
    |> Map.new()
  end

  @doc false
  def plugin_defaults do
    plugin_schema()
    |> Enum.reduce(%{}, fn {key, schema}, defaults ->
      put_dotted(defaults, key, Map.fetch!(schema, :default))
    end)
  end

  @doc false
  def plugin_safe_write_keys do
    plugin_schema()
    |> Enum.filter(fn {_key, schema} -> Map.get(schema, :writable?, true) end)
    |> Enum.map(fn {key, _schema} -> key end)
  end

  defp safe_registered_settings(:app) do
    AppRegistry.registered_settings_schema()
  rescue
    exception ->
      Logger.warning("App settings schema unavailable: #{Exception.message(exception)}")
      []
  catch
    :exit, reason ->
      Logger.warning("App settings schema unavailable: #{inspect(reason)}")
      []
  end

  defp safe_registered_settings(:plugin) do
    PluginRegistry.registered_settings_schema()
  rescue
    exception ->
      Logger.warning("Plugin settings schema unavailable: #{Exception.message(exception)}")
      []
  catch
    :exit, reason ->
      Logger.warning("Plugin settings schema unavailable: #{inspect(reason)}")
      []
  end

  @doc false
  def normalize_app_schema_entries(entries) when is_list(entries) do
    entries
    |> Enum.flat_map(&normalize_app_schema_entry/1)
    |> Map.new()
  end

  def normalize_app_schema_entries(_entries), do: %{}

  defp normalize_app_schema_entry(entry) when is_map(entry) do
    key = schema_field(entry, :key)

    if valid_app_setting_key?(key) do
      normalize_schema_entry(entry)
    else
      []
    end
  end

  defp normalize_app_schema_entry(_entry), do: []

  @doc false
  def normalize_plugin_schema_entries(entries, opts \\ [])

  def normalize_plugin_schema_entries(entries, opts) when is_list(entries) do
    entries
    |> Enum.flat_map(&normalize_plugin_schema_entry(&1, opts))
    |> Map.new()
  end

  def normalize_plugin_schema_entries(_entries, _opts), do: %{}

  defp normalize_plugin_schema_entry(entry, opts) when is_map(entry) do
    key = schema_field(entry, :key)

    cond do
      valid_plugin_setting_key?(key) ->
        normalize_schema_entry(entry)

      channel_setting_key_allowed?(key, opts) ->
        normalize_schema_entry(entry)

      Map.has_key?(@schema, key) and not channel_setting_key?(key) ->
        normalize_schema_entry(entry)

      true ->
        []
    end
  end

  defp normalize_plugin_schema_entry(_entry, _opts), do: []

  defp normalize_schema_entry(entry) when is_map(entry) do
    key = schema_field(entry, :key)
    type = schema_field(entry, :type)

    cond do
      not is_binary(key) ->
        []

      not is_atom(type) ->
        []

      not has_schema_field?(entry, :default) ->
        []

      true ->
        [{key, plugin_schema_attrs(entry, type)}]
    end
  end

  defp plugin_schema_attrs(entry, type) do
    %{
      type: type,
      default: schema_field(entry, :default),
      writable?: schema_field(entry, :writable?, true),
      sensitive?: schema_field(entry, :sensitive?, sensitive_key?(schema_field(entry, :key)))
    }
    |> maybe_put_schema_attr(:allowed_values, schema_field(entry, :allowed_values))
    |> maybe_put_schema_attr(:min, schema_field(entry, :min))
    |> maybe_put_schema_attr(:max, schema_field(entry, :max))
  end

  defp maybe_put_schema_attr(schema, _key, nil), do: schema
  defp maybe_put_schema_attr(schema, key, value), do: Map.put(schema, key, value)

  defp schema_field(entry, key, default \\ nil) do
    Map.get(entry, key, Map.get(entry, Atom.to_string(key), default))
  end

  defp has_schema_field?(entry, key) do
    Map.has_key?(entry, key) or Map.has_key?(entry, Atom.to_string(key))
  end

  defp valid_plugin_setting_key?(key) when is_binary(key) do
    byte_size(key) <= 160 and
      Regex.match?(~r/^[a-z][a-z0-9_]*(\.[a-z][a-z0-9_]*)+$/, key) and
      (String.starts_with?(key, "plugins.") or
         key
         |> split_key()
         |> List.first()
         |> reserved_plugin_settings_namespace?()
         |> Kernel.not())
  end

  defp valid_plugin_setting_key?(_key), do: false

  defp channel_setting_key_allowed?(key, opts) when is_binary(key) do
    channel_setting_key?(key) and trusted_source_tree_plugin?(Keyword.get(opts, :plugin)) and
      Enum.any?(channel_settings_prefixes(Keyword.get(opts, :plugin)), fn prefix ->
        key == prefix or String.starts_with?(key, prefix <> ".")
      end)
  end

  defp channel_setting_key_allowed?(_key, _opts), do: false

  defp channel_setting_key?(key) when is_binary(key), do: String.starts_with?(key, "channels.")
  defp channel_setting_key?(_key), do: false

  defp trusted_source_tree_plugin?(plugin) when is_map(plugin) do
    Map.get(plugin, :source) in [:shipped, :project] and
      Map.get(plugin, :trust_status) == :trusted
  end

  defp trusted_source_tree_plugin?(_plugin), do: false

  defp channel_settings_prefixes(plugin) when is_map(plugin) do
    plugin
    |> Map.get(:channels, [])
    |> Enum.flat_map(fn
      %{settings_prefix: prefix} when is_binary(prefix) -> [prefix]
      %{"settings_prefix" => prefix} when is_binary(prefix) -> [prefix]
      _descriptor -> []
    end)
    |> Enum.uniq()
  end

  defp channel_settings_prefixes(_plugin), do: []

  defp reserved_plugin_settings_namespace?(namespace) do
    namespace in [
      "agents",
      "apps",
      "channels",
      "confirmations",
      "execution",
      "external_services",
      "intent",
      "jobs",
      "memory",
      "model_profiles",
      "operator",
      "package_installs",
      "permissions",
      "providers",
      "resource_grants",
      "runtime",
      "sessions",
      "skills",
      "workspace"
    ]
  end

  defp valid_app_setting_key?(key) when is_binary(key) do
    byte_size(key) <= 160 and Regex.match?(~r/^apps\.[a-z][a-z0-9_]*(\.[a-z][a-z0-9_]*)+$/, key)
  end

  defp valid_app_setting_key?(_key), do: false

  defp put_in_segments(_settings, [], value), do: value

  defp put_in_segments(settings, [segment], value) when is_map(settings) do
    Map.put(settings, segment, value)
  end

  defp put_in_segments(settings, [segment | rest], value) when is_map(settings) do
    child =
      settings
      |> Map.get(segment, %{})
      |> case do
        map when is_map(map) -> map
        _other -> %{}
      end

    Map.put(settings, segment, put_in_segments(child, rest, value))
  end

  defp valid_name?(name), do: is_binary(name) and Regex.match?(~r/^[A-Za-z0-9_-]+$/, name)

  defp valid_string_list_item?(value), do: is_binary(value) and String.trim(value) != ""

  defp valid_string_map_key?(value), do: is_binary(value) and String.trim(value) != ""

  defp secret_like_key?(key) when is_binary(key) do
    key
    |> String.downcase()
    |> String.split(~r/[^a-z0-9]+/, trim: true)
    |> Enum.any?(&(&1 in ["authorization", "secret", "token", "password", "api", "key"]))
  end

  defp safe_mcp_launcher?(launcher) when is_binary(launcher) do
    launcher = String.trim(launcher)

    launcher != "" and
      (bare_mcp_launcher?(launcher) or absolute_mcp_launcher?(launcher)) and
      not String.contains?(launcher, [" ", "\t", "\n", "\r"])
  end

  defp safe_mcp_launcher?(_launcher), do: false

  defp bare_mcp_launcher?(launcher) do
    not String.contains?(launcher, ["/", "\\", "\0"])
  end

  defp absolute_mcp_launcher?(launcher) do
    parts = Path.split(launcher)

    String.starts_with?(launcher, "/") and
      length(parts) > 1 and
      not String.contains?(launcher, ["\\", "\0"]) and
      Enum.all?(parts, &(&1 not in ["", ".", ".."]))
  end

  defp mcp_secret_ref?(value) when is_binary(value) do
    Regex.match?(~r/^secret:\/\/mcp\/[A-Za-z0-9_-]+\/[A-Za-z0-9_-]+$/, value)
  end

  defp mcp_secret_ref?(_value), do: false

  defp valid_email?(value) when is_binary(value) do
    String.length(value) <= 254 and
      Regex.match?(~r/^[^\s@]+@[^\s@]+\.[^\s@]+$/, value)
  end

  defp validate_command_profile(name, profile) do
    cond do
      not valid_name?(name) ->
        {:error, {:invalid_profile_name, name}}

      not is_map(profile) ->
        {:error, {:invalid_command_profile, name, :expected_map}}

      true ->
        validate_command_profile_attrs(name, profile)
    end
  end

  defp validate_command_profile_attrs(name, profile) do
    allowed_keys =
      [
        "command",
        "args_prefix",
        "command_class",
        "description",
        "allowed_roots",
        "env_allowlist",
        "timeout_ms",
        "max_output_bytes",
        "require_confirmation"
      ]

    profile
    |> Map.keys()
    |> Enum.reject(&(&1 in allowed_keys))
    |> case do
      [] -> validate_command_profile_values(name, profile)
      [key | _rest] -> {:error, {:invalid_command_profile, name, {:unknown_key, key}}}
    end
  end

  defp validate_command_profile_values(name, profile) do
    with :ok <- validate_required_profile_command(name, profile),
         :ok <- validate_optional_string_list(profile, "args_prefix"),
         :ok <- validate_optional_string_list(profile, "allowed_roots"),
         :ok <- validate_optional_string_list(profile, "env_allowlist"),
         :ok <- validate_optional_timeout(profile, "timeout_ms"),
         :ok <- validate_optional_positive_integer(profile, "max_output_bytes"),
         :ok <- validate_optional_boolean(profile, "require_confirmation") do
      validate_optional_command_class(name, profile)
    end
  end

  defp validate_required_profile_command(name, profile) do
    case Map.get(profile, "command") do
      command when is_binary(command) ->
        if String.trim(command) == "" do
          {:error, {:invalid_command_profile, name, :empty_command}}
        else
          :ok
        end

      other ->
        {:error, {:invalid_command_profile, name, {:expected_command, other}}}
    end
  end

  defp validate_optional_command_class(name, profile) do
    case Map.get(profile, "command_class", "developer") do
      class when class in ["read_only", "developer", "mutating"] ->
        :ok

      other ->
        {:error, {:invalid_command_profile, name, {:invalid_command_class, other}}}
    end
  end

  defp validate_external_service_profile(name, profile) do
    cond do
      not valid_name?(name) ->
        {:error, {:invalid_external_service_profile_name, name}}

      not is_map(profile) ->
        {:error, {:invalid_external_service_profile, name, :expected_map}}

      true ->
        validate_external_service_profile_attrs(name, profile)
    end
  end

  defp validate_external_service_profile_attrs(name, profile) do
    allowed_keys = [
      "enabled",
      "base_url",
      "allowed_hosts",
      "blocked_hosts",
      "allowed_paths",
      "allowed_methods",
      "default_timeout_ms",
      "max_timeout_ms",
      "max_response_bytes",
      "allow_redirects",
      "max_redirects",
      "retry_policy",
      "redact_request_headers",
      "redact_response_headers",
      "description"
    ]

    profile
    |> Map.keys()
    |> Enum.reject(&(&1 in allowed_keys))
    |> case do
      [] -> validate_external_service_profile_values(name, profile)
      [key | _rest] -> {:error, {:invalid_external_service_profile, name, {:unknown_key, key}}}
    end
  end

  defp validate_external_service_profile_values(_name, profile) do
    with :ok <- validate_optional_boolean(profile, "enabled"),
         :ok <- validate_optional_url_or_nil(profile, "base_url"),
         :ok <- validate_optional_string_list(profile, "allowed_hosts"),
         :ok <- validate_optional_string_list(profile, "blocked_hosts"),
         :ok <- validate_optional_string_list(profile, "allowed_paths"),
         :ok <- validate_optional_http_methods(profile, "allowed_methods"),
         :ok <- validate_optional_timeout(profile, "default_timeout_ms"),
         :ok <- validate_optional_timeout(profile, "max_timeout_ms"),
         :ok <- validate_optional_positive_integer(profile, "max_response_bytes"),
         :ok <- validate_optional_boolean(profile, "allow_redirects"),
         :ok <- validate_optional_non_negative_integer(profile, "max_redirects"),
         :ok <- validate_optional_retry_policy(profile, "retry_policy"),
         :ok <- validate_optional_string_list(profile, "redact_request_headers") do
      validate_optional_string_list(profile, "redact_response_headers")
    end
  end

  defp validate_package_manager_profile(name, profile) do
    cond do
      not valid_name?(name) ->
        {:error, {:invalid_package_manager_profile_name, name}}

      not is_map(profile) ->
        {:error, {:invalid_package_manager_profile, name, :expected_map}}

      true ->
        validate_package_manager_profile_attrs(name, profile)
    end
  end

  defp validate_package_manager_profile_attrs(name, profile) do
    allowed_keys = [
      "executable",
      "args_prefix",
      "plan_args",
      "install_args",
      "description",
      "allowed_roots",
      "timeout_ms",
      "max_output_bytes",
      "require_confirmation",
      "lifecycle_scripts_allowed",
      "git_dependencies_allowed",
      "global_installs_allowed"
    ]

    profile
    |> Map.keys()
    |> Enum.reject(&(&1 in allowed_keys))
    |> case do
      [] -> validate_package_manager_profile_values(name, profile)
      [key | _rest] -> {:error, {:invalid_package_manager_profile, name, {:unknown_key, key}}}
    end
  end

  defp validate_package_manager_profile_values(name, profile) do
    with :ok <- validate_required_package_manager_executable(name, profile),
         :ok <- validate_optional_string_list(profile, "args_prefix"),
         :ok <- validate_optional_string_list(profile, "plan_args"),
         :ok <- validate_optional_string_list(profile, "install_args"),
         :ok <- validate_optional_string_list(profile, "allowed_roots"),
         :ok <- validate_optional_timeout(profile, "timeout_ms"),
         :ok <- validate_optional_positive_integer(profile, "max_output_bytes"),
         :ok <- validate_optional_boolean(profile, "require_confirmation"),
         :ok <- validate_optional_boolean(profile, "lifecycle_scripts_allowed"),
         :ok <- validate_optional_boolean(profile, "git_dependencies_allowed") do
      validate_optional_boolean(profile, "global_installs_allowed")
    end
  end

  defp validate_optional_string_list(profile, key) do
    case Map.fetch(profile, key) do
      :error -> :ok
      {:ok, value} -> validate_value(%{type: :string_list}, value, key, %{})
    end
  end

  defp validate_optional_http_methods(profile, key) do
    case Map.fetch(profile, key) do
      :error -> :ok
      {:ok, value} -> validate_value(%{type: :http_methods}, value, key, %{})
    end
  end

  defp validate_optional_url_or_nil(profile, key) do
    case Map.fetch(profile, key) do
      :error -> :ok
      {:ok, value} -> validate_value(%{type: :url_or_nil}, value, key, %{})
    end
  end

  defp validate_optional_timeout(profile, key) do
    case Map.fetch(profile, key) do
      :error -> :ok
      {:ok, value} -> validate_value(%{type: :timeout_ms}, value, key, %{})
    end
  end

  defp validate_optional_positive_integer(profile, key) do
    case Map.fetch(profile, key) do
      :error -> :ok
      {:ok, value} -> validate_value(%{type: :positive_integer}, value, key, %{})
    end
  end

  defp validate_optional_non_negative_integer(profile, key) do
    case Map.fetch(profile, key) do
      :error -> :ok
      {:ok, value} -> validate_value(%{type: :non_negative_integer}, value, key, %{})
    end
  end

  defp validate_optional_boolean(profile, key) do
    case Map.fetch(profile, key) do
      :error -> :ok
      {:ok, value} -> validate_value(%{type: :boolean}, value, key, %{})
    end
  end

  defp validate_optional_retry_policy(profile, key) do
    case Map.fetch(profile, key) do
      :error ->
        :ok

      {:ok, value} ->
        validate_value(
          %{type: :enum, allowed_values: ["none", "safe_idempotent"]},
          value,
          key,
          %{}
        )
    end
  end

  defp validate_interpreter_profile(name, profile) do
    cond do
      not valid_name?(name) ->
        {:error, {:invalid_interpreter_profile_name, name}}

      not is_map(profile) ->
        {:error, {:invalid_interpreter_profile, name, :expected_map}}

      true ->
        validate_interpreter_profile_attrs(name, profile)
    end
  end

  defp validate_interpreter_profile_attrs(name, profile) do
    allowed_keys = [
      "executable",
      "allowed_extensions",
      "args_prefix",
      "command_class",
      "description",
      "timeout_ms",
      "max_output_bytes",
      "require_confirmation"
    ]

    profile
    |> Map.keys()
    |> Enum.reject(&(&1 in allowed_keys))
    |> case do
      [] -> validate_interpreter_profile_values(name, profile)
      [key | _rest] -> {:error, {:invalid_interpreter_profile, name, {:unknown_key, key}}}
    end
  end

  defp validate_interpreter_profile_values(name, profile) do
    with :ok <- validate_required_profile_executable(name, profile),
         :ok <- validate_required_allowed_extensions(name, profile),
         :ok <- validate_optional_string_list(profile, "args_prefix"),
         :ok <- validate_optional_timeout(profile, "timeout_ms"),
         :ok <- validate_optional_positive_integer(profile, "max_output_bytes"),
         :ok <- validate_optional_boolean(profile, "require_confirmation") do
      validate_optional_interpreter_command_class(name, profile)
    end
  end

  defp validate_required_profile_executable(name, profile) do
    case Map.get(profile, "executable") do
      executable when is_binary(executable) ->
        if String.trim(executable) == "" do
          {:error, {:invalid_interpreter_profile, name, :empty_executable}}
        else
          :ok
        end

      other ->
        {:error, {:invalid_interpreter_profile, name, {:expected_executable, other}}}
    end
  end

  defp validate_required_package_manager_executable(name, profile) do
    case Map.get(profile, "executable") do
      executable when is_binary(executable) ->
        if String.trim(executable) == "" do
          {:error, {:invalid_package_manager_profile, name, :empty_executable}}
        else
          :ok
        end

      other ->
        {:error, {:invalid_package_manager_profile, name, {:expected_executable, other}}}
    end
  end

  defp validate_required_allowed_extensions(name, profile) do
    case Map.get(profile, "allowed_extensions") do
      extensions when is_list(extensions) ->
        if Enum.all?(extensions, &valid_extension?/1) do
          :ok
        else
          {:error, {:invalid_interpreter_profile, name, :invalid_allowed_extensions}}
        end

      other ->
        {:error, {:invalid_interpreter_profile, name, {:expected_allowed_extensions, other}}}
    end
  end

  defp validate_optional_interpreter_command_class(name, profile) do
    case Map.get(profile, "command_class", "developer") do
      class when class in ["read_only", "developer", "mutating"] ->
        :ok

      other ->
        {:error, {:invalid_interpreter_profile, name, {:invalid_command_class, other}}}
    end
  end

  defp valid_extension?("." <> rest), do: valid_extension_name?(rest)
  defp valid_extension?(value), do: valid_extension_name?(value)

  defp valid_extension_name?(value) when is_binary(value) do
    Regex.match?(~r/^[A-Za-z0-9_+-]+$/, value)
  end

  defp valid_extension_name?(_value), do: false

  defp loopback_setting_host?(host)
       when host in ["localhost", "localhost.localdomain", "127.0.0.1", "::1"],
       do: true

  defp loopback_setting_host?(host) when is_binary(host) do
    case :inet.parse_address(String.to_charlist(host)) do
      {:ok, {127, _b, _c, _d}} -> true
      {:ok, {0, 0, 0, 0, 0, 0, 0, 1}} -> true
      _result -> false
    end
  end

  defp loopback_setting_host?(_host), do: false
end
