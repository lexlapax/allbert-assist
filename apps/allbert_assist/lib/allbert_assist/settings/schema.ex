defmodule AllbertAssist.Settings.Schema do
  @moduledoc false

  require Logger

  alias AllbertAssist.App.Registry, as: AppRegistry
  alias AllbertAssist.Plugin.Registry, as: PluginRegistry
  alias AllbertAssist.Resources.OperationClass
  alias AllbertAssist.Resources.ResourceURI
  alias AllbertAssist.Resources.Scope

  @safe_write_keys [
    "operator.display_name",
    "operator.timezone",
    "operator.communication_style",
    "operator.handoff_detail",
    "runtime.trace_default",
    "runtime.diagnostics_verbosity",
    "intent.model_assist_enabled",
    "intent.model_profile",
    "intent.model_timeout_ms",
    "intent.model_min_confidence",
    "intent.max_candidates",
    "intent.trace_rejected_candidates",
    "providers.*.enabled",
    "providers.*.base_url",
    "providers.*.api_key_ref",
    "model_profiles.*.provider",
    "model_profiles.*.model",
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
    "permissions.skill_script_execute",
    "permissions.confirmation_decide",
    "permissions.stocksage_write",
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
    "channels.email.allow_html_replies"
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
      default: "fast",
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
    "permissions.stocksage_write" => %{
      type: :enum,
      default: "allowed",
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
      writable?: false,
      sensitive?: false,
      allowed_values: ["manual", "daily", "weekly"]
    },
    "memory.auto_promote_sensitive_entries" => %{
      type: :boolean,
      default: false,
      writable?: false,
      sensitive?: false
    },
    "memory.retention_policy" => %{
      type: :enum,
      default: "preserve_markdown",
      writable?: false,
      sensitive?: false,
      allowed_values: ["preserve_markdown"]
    }
  }

  @provider_schema %{
    "type" => %{
      type: :enum,
      allowed_values: ["openai", "openai_compatible", "anthropic", "local"]
    },
    "enabled" => %{type: :boolean},
    "base_url" => %{type: :url_or_nil},
    "api_key_ref" => %{type: :secret_ref_or_nil}
  }

  @model_profile_schema %{
    "provider" => %{type: :provider_ref},
    "model" => %{type: :string},
    "temperature" => %{type: :temperature},
    "max_tokens" => %{type: :positive_integer},
    "timeout_ms" => %{type: :timeout_ms}
  }

  @defaults %{
    "operator" => %{
      "display_name" => "local",
      "timezone" => "America/Los_Angeles",
      "communication_style" => "concise",
      "handoff_detail" => "concrete_next_steps"
    },
    "runtime" => %{
      "trace_default" => "disabled",
      "diagnostics_verbosity" => "normal",
      "model_alias" => "local",
      "cost_visibility" => "summary"
    },
    "intent" => %{
      "model_assist_enabled" => false,
      "model_profile" => "fast",
      "model_timeout_ms" => 3000,
      "model_min_confidence" => 0.72,
      "max_candidates" => 80,
      "trace_rejected_candidates" => true
    },
    "providers" => %{
      "local_ollama" => %{
        "type" => "openai_compatible",
        "base_url" => "http://localhost:11434/v1",
        "api_key_ref" => nil,
        "enabled" => true
      },
      "openai" => %{
        "type" => "openai",
        "api_key_ref" => "secret://providers/openai/api_key",
        "enabled" => false
      }
    },
    "model_profiles" => %{
      "local" => %{
        "provider" => "local_ollama",
        "model" => "gemma4:26b",
        "temperature" => 0.2,
        "max_tokens" => 1024,
        "timeout_ms" => 30_000
      },
      "fast" => %{
        "provider" => "openai",
        "model" => "gpt-4o-mini",
        "temperature" => 0.2,
        "max_tokens" => 1024,
        "timeout_ms" => 30_000
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
      "skill_script_execute" => "denied",
      "confirmation_decide" => "allowed",
      "stocksage_write" => "allowed"
    },
    "plugins" => %{
      "enabled" => [],
      "disabled" => [],
      "scan_paths" => ["./plugins", "<ALLBERT_HOME>/plugins"],
      "trusted_project_roots" => [],
      "load_policy" => "shipped_and_skill_only"
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
    "memory" => %{
      "review_cadence" => "manual",
      "auto_promote_sensitive_entries" => false,
      "retention_policy" => "preserve_markdown"
    }
  }

  def defaults do
    plugin_defaults()
    |> deep_merge(app_defaults())
    |> deep_merge(@defaults)
  end

  def runtime_schema, do: schema()

  def schema do
    plugin_schema()
    |> Map.merge(app_schema())
    |> Map.merge(@schema)
  end

  def safe_write_keys,
    do: Enum.uniq(@safe_write_keys ++ app_safe_write_keys() ++ plugin_safe_write_keys())

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
         :ok <- validate_runtime_refs(settings),
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
    key
    |> String.split(~r/[._-]/, trim: true)
    |> Enum.any?(&(&1 in ["secret", "token", "password", "api", "key", "private", "credential"]))
  end

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
        validate_dynamic_map(profiles, @model_profile_schema, "model_profiles", settings)

      other ->
        {:error, {:invalid_setting, "model_profiles", {:expected_map, other}}}
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

  defp validate_value(%{type: :string_or_empty}, value, _key, _settings)
       when is_binary(value) do
    if String.length(value) <= 200, do: :ok, else: {:error, :invalid_string}
  end

  defp validate_value(%{type: :string_or_empty}, value, _key, _settings),
    do: {:error, {:expected_string, value}}

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

  defp validate_value(%{type: :string_list}, value, _key, _settings) when is_list(value) do
    if Enum.all?(value, &valid_string_list_item?/1) do
      :ok
    else
      {:error, {:expected_string_list, value}}
    end
  end

  defp validate_value(%{type: :string_list}, value, _key, _settings),
    do: {:error, {:expected_string_list, value}}

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

  defp validate_value(%{type: :timeout_ms}, value, _key, _settings) when is_integer(value) do
    if value >= 1_000 and value <= 600_000, do: :ok, else: {:error, :out_of_range}
  end

  defp validate_value(schema, value, _key, _settings),
    do: {:error, {:invalid_value, schema.type, value}}

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
    Regex.match?(~r/^providers\.[^.]+\.(type|enabled|base_url|api_key_ref)$/, key) ||
      Regex.match?(
        ~r/^model_profiles\.[^.]+\.(provider|model|temperature|max_tokens|timeout_ms)$/,
        key
      )
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

  defp app_schema do
    :app
    |> safe_registered_settings()
    |> Enum.flat_map(&normalize_app_schema_entry/1)
    |> Map.new()
  end

  defp app_defaults do
    app_schema()
    |> Enum.reduce(%{}, fn {key, schema}, defaults ->
      put_dotted(defaults, key, Map.fetch!(schema, :default))
    end)
  end

  defp app_safe_write_keys do
    app_schema()
    |> Enum.filter(fn {_key, schema} -> Map.get(schema, :writable?, true) end)
    |> Enum.map(fn {key, _schema} -> key end)
  end

  defp plugin_schema do
    :plugin
    |> safe_registered_settings()
    |> Enum.flat_map(&normalize_plugin_schema_entry/1)
    |> Map.new()
  end

  defp plugin_defaults do
    plugin_schema()
    |> Enum.reduce(%{}, fn {key, schema}, defaults ->
      put_dotted(defaults, key, Map.fetch!(schema, :default))
    end)
  end

  defp plugin_safe_write_keys do
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

  defp normalize_app_schema_entry(entry) when is_map(entry) do
    key = schema_field(entry, :key)

    if valid_app_setting_key?(key) do
      normalize_schema_entry(entry)
    else
      []
    end
  end

  defp normalize_app_schema_entry(_entry), do: []

  defp normalize_plugin_schema_entry(entry) when is_map(entry) do
    key = schema_field(entry, :key)

    cond do
      valid_plugin_setting_key?(key) ->
        normalize_schema_entry(entry)

      Map.has_key?(@schema, key) ->
        normalize_schema_entry(entry)

      true ->
        []
    end
  end

  defp normalize_plugin_schema_entry(_entry), do: []

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
      "skills"
    ]
  end

  defp valid_app_setting_key?(key) when is_binary(key) do
    byte_size(key) <= 160 and Regex.match?(~r/^apps\.[a-z][a-z0-9_]*(\.[a-z][a-z0-9_]*)+$/, key)
  end

  defp valid_app_setting_key?(_key), do: false

  defp deep_merge(left, right) when is_map(left) and is_map(right) do
    Map.merge(left, right, fn _key, left_value, right_value ->
      deep_merge(left_value, right_value)
    end)
  end

  defp deep_merge(_left, right), do: right

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
end
