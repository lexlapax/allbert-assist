defmodule AllbertAssist.Security.Policy do
  @moduledoc """
  Settings-backed policy lookup with v0.05 built-in safety floors.
  """

  alias AllbertAssist.Settings
  alias AllbertAssist.Settings.Schema

  @permission_settings %{
    memory_write: "permissions.memory_write",
    command_plan: "permissions.command_plan",
    command_execute: "permissions.command_execute",
    coding_file_read: "permissions.coding_file_read",
    coding_file_write: "permissions.coding_file_write",
    coding_shell_execute: "permissions.coding_shell_execute",
    external_network: "permissions.external_network",
    package_install: "permissions.package_install",
    online_skill_import: "permissions.online_skill_import",
    settings_write: "permissions.settings_write",
    skill_write: "permissions.skill_write",
    dynamic_codegen_request: "permissions.dynamic_codegen_request",
    dynamic_codegen_discard: "permissions.dynamic_codegen_discard",
    skill_script_execute: "permissions.skill_script_execute",
    confirmation_decide: "permissions.confirmation_decide",
    objective_write: "permissions.objective_write",
    workspace_canvas_write: "permissions.workspace_canvas_write",
    sandbox_trial: "permissions.sandbox_trial",
    dynamic_integration: "permissions.dynamic_integration",
    stocksage_write: "permissions.stocksage_write",
    stocksage_analyze: "permissions.stocksage_analyze",
    stocksage_evidence_fetch: "permissions.stocksage_evidence_fetch",
    notes_file_write: "permissions.notes_file_write",
    microphone_capture: "permissions.microphone_capture",
    voice_transcribe: "permissions.voice_transcribe",
    voice_synthesize: "permissions.voice_synthesize",
    voice_local_runtime_manage: "permissions.voice_local_runtime_manage",
    image_input: "permissions.image_input",
    image_generate: "permissions.image_generate",
    artifact_read: "permissions.artifact_read",
    artifact_write: "permissions.artifact_write",
    artifact_delete: "permissions.artifact_delete",
    tool_discovery: "permissions.tool_discovery",
    mcp_server_connect: "permissions.mcp_server_connect",
    mcp_tool_call: "permissions.mcp_tool_call",
    mcp_resource_read: "permissions.mcp_resource_read",
    public_surface_call_inbound: "permissions.public_surface_call_inbound",
    channel_message_inbound: "permissions.channel_message_inbound",
    browser_session_start: "permissions.browser_session_start",
    browser_navigate: "permissions.browser_navigate",
    browser_extract: "permissions.browser_extract",
    browser_screenshot: "permissions.browser_screenshot",
    browser_interact: "permissions.browser_interact",
    browser_form_fill: "permissions.browser_form_fill",
    browser_download: "permissions.browser_download",
    workflow_read: "permissions.workflow_read",
    workflow_run_start: "permissions.workflow_run_start",
    plan_cancel: "permissions.plan_cancel",
    job_write: "permissions.job_write",
    marketplace_install: "permissions.marketplace_install",
    email_send: "permissions.email_send",
    channel_message_send: "permissions.channel_message_send",
    calendar_write: "permissions.calendar_write"
  }

  @default_decisions %{
    read_only: :allowed,
    conversation_write: :allowed,
    memory_write: :allowed,
    command_plan: :allowed,
    command_execute: :denied,
    coding_file_read: :allowed,
    coding_file_write: :needs_confirmation,
    coding_shell_execute: :needs_confirmation,
    external_network: :needs_confirmation,
    package_install: :denied,
    online_skill_import: :denied,
    settings_write: :allowed,
    skill_write: :allowed,
    dynamic_codegen_request: :allowed,
    dynamic_codegen_discard: :allowed,
    skill_script_execute: :denied,
    confirmation_decide: :allowed,
    objective_write: :allowed,
    workspace_canvas_write: :allowed,
    sandbox_trial: :allowed,
    dynamic_integration: :needs_confirmation,
    stocksage_write: :allowed,
    stocksage_analyze: :needs_confirmation,
    stocksage_evidence_fetch: :allowed,
    notes_file_write: :needs_confirmation,
    microphone_capture: :needs_confirmation,
    voice_transcribe: :allowed,
    voice_synthesize: :allowed,
    voice_local_runtime_manage: :allowed,
    image_input: :allowed,
    image_generate: :allowed,
    artifact_read: :allowed,
    artifact_write: :allowed,
    artifact_delete: :needs_confirmation,
    tool_discovery: :allowed,
    mcp_server_connect: :needs_confirmation,
    mcp_tool_call: :needs_confirmation,
    mcp_resource_read: :allowed,
    public_surface_call_inbound: :needs_confirmation,
    channel_message_inbound: :needs_confirmation,
    browser_session_start: :needs_confirmation,
    browser_navigate: :needs_confirmation,
    browser_extract: :allowed,
    browser_screenshot: :allowed,
    browser_interact: :needs_confirmation,
    browser_form_fill: :denied,
    browser_download: :denied,
    workflow_read: :allowed,
    workflow_run_start: :needs_confirmation,
    plan_cancel: :allowed,
    job_write: :allowed,
    marketplace_install: :allowed,
    # v0.54 M10 outbound compose actions: effectful + externally visible, so they
    # default to needs_confirmation (routing never auto-sends; ADR 0063).
    email_send: :needs_confirmation,
    channel_message_send: :needs_confirmation,
    calendar_write: :needs_confirmation,
    settings_secret_write: :allowed,
    settings_secret_read: :denied
  }

  @known_permissions Map.keys(@default_decisions)

  @type policy_decision :: :allowed | :needs_confirmation | :denied
  @type resolution :: %{
          permission: atom(),
          setting_key: String.t() | nil,
          configured: term(),
          configured_decision: term(),
          effective: term(),
          source: :built_in_default | :settings,
          safety_floor: policy_decision(),
          capped?: boolean(),
          context_denial: String.t() | nil,
          reason: String.t() | nil
        }

  @type permission ::
          :read_only
          | :conversation_write
          | :memory_write
          | :command_plan
          | :command_execute
          | :coding_file_read
          | :coding_file_write
          | :coding_shell_execute
          | :external_network
          | :package_install
          | :online_skill_import
          | :settings_write
          | :skill_write
          | :dynamic_codegen_request
          | :dynamic_codegen_discard
          | :skill_script_execute
          | :confirmation_decide
          | :objective_write
          | :workspace_canvas_write
          | :sandbox_trial
          | :dynamic_integration
          | :stocksage_write
          | :stocksage_analyze
          | :stocksage_evidence_fetch
          | :microphone_capture
          | :voice_transcribe
          | :voice_synthesize
          | :voice_local_runtime_manage
          | :image_input
          | :image_generate
          | :artifact_read
          | :artifact_write
          | :artifact_delete
          | :notes_file_write
          | :tool_discovery
          | :mcp_server_connect
          | :mcp_tool_call
          | :mcp_resource_read
          | :public_surface_call_inbound
          | :channel_message_inbound
          | :browser_session_start
          | :browser_navigate
          | :browser_extract
          | :browser_screenshot
          | :browser_interact
          | :browser_form_fill
          | :browser_download
          | :workflow_read
          | :workflow_run_start
          | :plan_cancel
          | :job_write
          | :marketplace_install
          | :email_send
          | :channel_message_send
          | :calendar_write
          | :settings_secret_write
          | :settings_secret_read

  @doc "Return known permission classes in stable order."
  @spec permission_classes() :: nonempty_list(permission())
  def permission_classes do
    [
      :read_only,
      :conversation_write,
      :memory_write,
      :command_plan,
      :command_execute,
      :coding_file_read,
      :coding_file_write,
      :coding_shell_execute,
      :external_network,
      :package_install,
      :online_skill_import,
      :settings_write,
      :skill_write,
      :dynamic_codegen_request,
      :dynamic_codegen_discard,
      :skill_script_execute,
      :confirmation_decide,
      :objective_write,
      :workspace_canvas_write,
      :sandbox_trial,
      :dynamic_integration,
      :stocksage_write,
      :stocksage_analyze,
      :stocksage_evidence_fetch,
      :notes_file_write,
      :microphone_capture,
      :voice_transcribe,
      :voice_synthesize,
      :voice_local_runtime_manage,
      :image_input,
      :image_generate,
      :artifact_read,
      :artifact_write,
      :artifact_delete,
      :tool_discovery,
      :mcp_server_connect,
      :mcp_tool_call,
      :mcp_resource_read,
      :public_surface_call_inbound,
      :channel_message_inbound,
      :browser_session_start,
      :browser_navigate,
      :browser_extract,
      :browser_screenshot,
      :browser_interact,
      :browser_form_fill,
      :browser_download,
      :workflow_read,
      :workflow_run_start,
      :plan_cancel,
      :job_write,
      :marketplace_install,
      :email_send,
      :channel_message_send,
      :calendar_write,
      :settings_secret_write,
      :settings_secret_read
    ]
  end

  @doc "Resolve effective policy for a permission and normalized context."
  @spec resolve(atom(), map()) :: resolution()
  def resolve(permission, context \\ %{}) do
    configured = configured_policy(permission)
    resolve_from_configured(permission, context, configured)
  end

  @doc "Resolve effective policy using an already-resolved Settings snapshot."
  @spec resolve(atom(), map(), map()) :: resolution()
  def resolve(permission, context, settings) when is_map(settings) do
    configured = configured_policy(permission, settings)
    resolve_from_configured(permission, context, configured)
  end

  defp resolve_from_configured(permission, context, configured) do
    floor = safety_floor(permission, context)
    effective = apply_safety_floor(configured.decision, floor)
    context_denial = context_denial(permission, context)

    final_effective =
      effective_decision(permission, context, configured, effective, context_denial)

    %{
      permission: permission,
      setting_key: Map.get(@permission_settings, permission),
      configured: configured.value,
      configured_decision: configured.decision,
      effective: final_effective,
      source: configured.source,
      safety_floor: floor,
      capped?: final_effective != configured.decision,
      context_denial: context_denial,
      reason: context_denial || reason(permission, final_effective, configured, floor, context)
    }
  end

  defp effective_decision(_permission, _context, _configured, _effective, context_denial)
       when is_binary(context_denial),
       do: :denied

  defp effective_decision(permission, context, %{decision: decision}, effective, _context_denial)
       when decision != :denied do
    cond do
      advisory_memory_write?(permission, context) -> :needs_confirmation
      approved_parent_analysis?(permission, context) -> :allowed
      fixture_evidence?(permission, context) -> :allowed
      true -> effective
    end
  end

  defp effective_decision(_permission, _context, _configured, effective, _context_denial),
    do: effective

  @doc "Return configured and effective policies for status surfaces."
  @spec permission_policies(map()) :: [map()]
  def permission_policies(context \\ %{}) do
    Enum.map(permission_classes(), &resolve(&1, context))
  end

  @doc "Return configured and effective policies from an already-resolved Settings snapshot."
  @spec permission_policies(map(), map()) :: [map()]
  def permission_policies(context, settings) when is_map(settings) do
    Enum.map(permission_classes(), &resolve(&1, context, settings))
  end

  @doc "Return the Pi-mode approval-mode vocabulary in stable order."
  @spec approval_modes() :: nonempty_list(:default | :accept_edits | :plan | :tier)
  def approval_modes, do: [:default, :accept_edits, :plan, :tier]

  @doc "Read the requested Pi-mode approval mode from context, then Settings Central."
  @spec approval_mode(map()) :: :default | :accept_edits | :plan | :tier
  def approval_mode(context) when is_map(context) do
    (coding_context_value(context, :approval_mode) ||
       coding_context_value(context, :default_approval_mode) ||
       setting_value("coding.default_approval_mode", "default"))
    |> normalize_approval_mode()
  end

  def approval_mode(_context),
    do: setting_value("coding.default_approval_mode", "default") |> normalize_approval_mode()

  @doc "Return the known Pi-mode coding trust tiers."
  @spec coding_tiers() :: nonempty_list(:none | :local_coding_operator)
  def coding_tiers, do: [:none, :local_coding_operator]

  @doc """
  Resolve the Pi-mode local-coding trust tier from Settings Central plus the
  active request context.
  """
  @spec coding_tier(map()) :: :local_coding_operator | :none
  def coding_tier(context) when is_map(context) do
    if pi_mode_enabled?(context) and local_coding_operator_context?(context) do
      :local_coding_operator
    else
      :none
    end
  end

  def coding_tier(_context), do: :none

  @doc "Return the v0.05 safety floor for a permission."
  @spec safety_floor(atom()) :: :allowed | :needs_confirmation | :denied
  def safety_floor(permission), do: safety_floor(permission, %{})

  @doc "Return the effective safety floor for a permission and context."
  @spec safety_floor(atom(), map()) :: :allowed | :needs_confirmation | :denied
  def safety_floor(:command_execute, _context), do: :needs_confirmation
  def safety_floor(:coding_file_read, _context), do: :allowed
  def safety_floor(:coding_file_write, _context), do: :needs_confirmation
  def safety_floor(:coding_shell_execute, _context), do: :needs_confirmation
  def safety_floor(:external_network, _context), do: :needs_confirmation
  def safety_floor(:package_install, _context), do: :needs_confirmation
  def safety_floor(:online_skill_import, _context), do: :needs_confirmation
  def safety_floor(:skill_script_execute, _context), do: :needs_confirmation
  def safety_floor(:dynamic_integration, _context), do: :needs_confirmation
  def safety_floor(:mcp_server_connect, _context), do: :needs_confirmation
  def safety_floor(:mcp_tool_call, _context), do: :needs_confirmation
  def safety_floor(:public_surface_call_inbound, _context), do: :needs_confirmation
  def safety_floor(:channel_message_inbound, _context), do: :needs_confirmation
  def safety_floor(:browser_session_start, _context), do: :needs_confirmation
  def safety_floor(:browser_navigate, _context), do: :needs_confirmation
  def safety_floor(:browser_interact, _context), do: :needs_confirmation
  def safety_floor(:browser_form_fill, _context), do: :needs_confirmation
  def safety_floor(:browser_download, _context), do: :needs_confirmation
  def safety_floor(:workflow_run_start, _context), do: :needs_confirmation
  def safety_floor(:stocksage_analyze, _context), do: :needs_confirmation
  def safety_floor(:stocksage_evidence_fetch, _context), do: :needs_confirmation
  def safety_floor(:notes_file_write, _context), do: :needs_confirmation
  def safety_floor(:microphone_capture, _context), do: :needs_confirmation
  def safety_floor(:voice_transcribe, context), do: voice_floor(context)
  def safety_floor(:voice_synthesize, context), do: voice_floor(context)
  def safety_floor(:image_input, _context), do: :allowed
  def safety_floor(:image_generate, context), do: image_floor(context)
  def safety_floor(:artifact_read, _context), do: :allowed
  def safety_floor(:artifact_write, _context), do: :allowed
  def safety_floor(:artifact_delete, _context), do: :needs_confirmation
  def safety_floor(:settings_secret_read, _context), do: :denied
  # v0.62 M8.8: migrating credentials into the OS vault is confirmation-gated even
  # though the settings_write class defaults to :allowed — the operator approves
  # each secret-vault migration explicitly (migrate_secrets' `confirmation:
  # :required` contract). Other settings writes stay :allowed (line below).
  def safety_floor(:settings_write, %{action: %{name: "migrate_secrets"}}),
    do: :needs_confirmation

  def safety_floor(permission, _context) when permission in @known_permissions, do: :allowed
  def safety_floor(_permission, _context), do: :denied

  defp voice_floor(context) do
    case provider_deployment_mode(context) do
      :fake -> :allowed
      :bundled_local -> :allowed
      "fake" -> :allowed
      "bundled_local" -> :allowed
      _local_or_remote_or_unknown -> :needs_confirmation
    end
  end

  defp image_floor(context) do
    case provider_deployment_mode(context) do
      :fake -> :allowed
      "fake" -> :allowed
      _local_or_remote_or_unknown -> :needs_confirmation
    end
  end

  defp provider_deployment_mode(context) when is_map(context) do
    Enum.find_value(deployment_mode_paths(), &deployment_mode_path(context, &1))
  end

  defp provider_deployment_mode(_context), do: nil

  defp deployment_mode_paths do
    [
      {:field, :provider_deployment_mode},
      {:field, :deployment_mode},
      [:image, :provider_deployment_mode],
      ["image", "provider_deployment_mode"],
      [:image, :media, "deployment_mode"],
      [:image, :media, :deployment_mode],
      ["image", "media", "deployment_mode"],
      ["image", "media", :deployment_mode],
      [:voice, :provider_deployment_mode],
      ["voice", "provider_deployment_mode"],
      [:voice, :media, "deployment_mode"],
      [:voice, :media, :deployment_mode],
      ["voice", "media", "deployment_mode"],
      ["voice", "media", :deployment_mode],
      [:model_profile, :media, "deployment_mode"],
      [:model_profile, :media, :deployment_mode],
      ["model_profile", "media", "deployment_mode"],
      ["model_profile", "media", :deployment_mode]
    ]
  end

  defp deployment_mode_path(context, {:field, key}), do: field(context, key)
  defp deployment_mode_path(context, path), do: get_in(context, path)

  defp local_coding_operator_context?(context) do
    trusted_operator_id =
      coding_context_value(context, :trusted_operator_id) ||
        setting_value("coding.trusted_operator_id", nil)

    actor_id = actor_id(context)

    trusted_operator_id not in [nil, ""] and actor_id == trusted_operator_id and
      channel_name(context) in [:tui, "tui"] and main_session?(context) and
      not disallowed_coding_origin?(context)
  end

  defp pi_mode_enabled?(context) do
    context_value =
      coding_context_value(context, :pi_mode_enabled) ||
        coding_context_value(context, :pi_mode_enabled?) ||
        get_in(context, [:coding, :pi_mode, :enabled]) ||
        get_in(context, ["coding", "pi_mode", "enabled"])

    case context_value do
      nil -> truthy?(setting_value("coding.pi_mode.enabled", false))
      value -> truthy?(value)
    end
  end

  defp actor_id(context) do
    actor = field(context, :actor)

    actor_id_from(actor) || field(context, :operator_id)
  end

  defp channel_name(context) do
    context
    |> field(:channel)
    |> channel_name_from()
  end

  defp actor_id_from(%{id: id}), do: id
  defp actor_id_from(%{"id" => id}), do: id
  defp actor_id_from(actor) when is_binary(actor) or is_atom(actor), do: actor
  defp actor_id_from(_actor), do: nil

  defp channel_name_from(%{name: name}), do: name
  defp channel_name_from(%{"name" => name}), do: name
  defp channel_name_from(channel) when is_binary(channel) or is_atom(channel), do: channel
  defp channel_name_from(_channel), do: nil

  defp main_session?(context) do
    session = field(context, :session) || %{}

    field(session, :main?) == true or get_in(context, [:session, :main?]) == true or
      get_in(context, ["session", "main?"]) == true or
      field(context, :main_session?) == true or field(context, :session_kind) in [:main, "main"]
  end

  defp disallowed_coding_origin?(context) do
    field(context, :channel_originated?) == true or field(context, :scheduled?) == true or
      field(context, :generated_code_session?) == true or
      get_in(context, [:coding, :channel_originated?]) == true or
      get_in(context, ["coding", "channel_originated?"]) == true or
      get_in(context, [:coding, :scheduled?]) == true or
      get_in(context, ["coding", "scheduled?"]) == true or
      get_in(context, [:coding, :generated_code_session?]) == true or
      get_in(context, ["coding", "generated_code_session?"]) == true
  end

  defp coding_context_value(context, key) do
    field(context, key) || get_in(context, [:coding, key]) ||
      get_in(context, ["coding", Atom.to_string(key)])
  end

  defp normalize_approval_mode(:default), do: :default
  defp normalize_approval_mode("default"), do: :default
  defp normalize_approval_mode(:accept_edits), do: :accept_edits
  defp normalize_approval_mode(:"accept-edits"), do: :accept_edits
  defp normalize_approval_mode("accept-edits"), do: :accept_edits
  defp normalize_approval_mode("accept_edits"), do: :accept_edits
  defp normalize_approval_mode(:plan), do: :plan
  defp normalize_approval_mode("plan"), do: :plan
  defp normalize_approval_mode(:tier), do: :tier
  defp normalize_approval_mode("tier"), do: :tier
  defp normalize_approval_mode(_value), do: :default

  defp truthy?(true), do: true
  defp truthy?("true"), do: true
  defp truthy?("1"), do: true
  defp truthy?(_value), do: false

  defp setting_value(key, default) do
    case Settings.get(key) do
      {:ok, value} -> value
      {:error, _reason} -> default
    end
  rescue
    _exception -> default
  end

  defp field(map, key) when is_map(map),
    do: Map.get(map, key) || Map.get(map, Atom.to_string(key))

  defp configured_policy(permission) do
    setting_key = Map.get(@permission_settings, permission)

    with key when is_binary(key) <- setting_key,
         {:ok, value} <- Settings.get(key) do
      %{
        value: value,
        decision: normalize_setting_value(value, default_decision(permission)),
        source: :settings
      }
    else
      _other ->
        %{
          value: nil,
          decision: default_decision(permission),
          source: :built_in_default
        }
    end
  rescue
    _exception ->
      %{
        value: nil,
        decision: default_decision(permission),
        source: :built_in_default
      }
  end

  defp configured_policy(permission, settings) when is_map(settings) do
    setting_key = Map.get(@permission_settings, permission)

    with key when is_binary(key) <- setting_key,
         value when not is_nil(value) <- Schema.get_dotted(settings, key) do
      %{
        value: value,
        decision: normalize_setting_value(value, default_decision(permission)),
        source: :settings
      }
    else
      _other ->
        %{
          value: nil,
          decision: default_decision(permission),
          source: :built_in_default
        }
    end
  rescue
    _exception ->
      %{
        value: nil,
        decision: default_decision(permission),
        source: :built_in_default
      }
  end

  defp default_decision(permission), do: Map.get(@default_decisions, permission, :denied)

  defp normalize_setting_value("allowed", _default), do: :allowed
  defp normalize_setting_value("allowed_safe_keys", _default), do: :allowed
  defp normalize_setting_value("needs_confirmation", _default), do: :needs_confirmation
  defp normalize_setting_value("denied", _default), do: :denied
  defp normalize_setting_value(_value, default), do: default

  defp apply_safety_floor(:denied, _floor), do: :denied
  defp apply_safety_floor(_configured, :denied), do: :denied
  defp apply_safety_floor(:allowed, :needs_confirmation), do: :needs_confirmation
  defp apply_safety_floor(configured, _floor), do: configured

  defp context_denial(_permission, %{action: %{name: name, registered?: false}})
       when not is_nil(name) do
    "Unknown or unregistered action boundary: #{inspect(name)}."
  end

  defp context_denial(permission, %{skill: %{lookup_status: :not_found, name: name}})
       when not is_nil(name) and permission != :read_only do
    "Selected skill is not trusted, enabled, or discoverable: #{inspect(name)}."
  end

  defp context_denial(permission, %{skill: %{trust_status: trust_status, name: name}})
       when not is_nil(name) and permission != :read_only and trust_status not in [nil, :trusted] do
    "Selected skill is not trusted for this permission: #{inspect(name)}."
  end

  defp context_denial(permission, context)
       when permission in [:coding_file_write, :coding_shell_execute] do
    if approval_mode(context) == :plan do
      "Pi-mode approval mode plan blocks coding writes and shell execution."
    end
  end

  defp context_denial(_permission, _context), do: nil

  defp advisory_memory_write?(:memory_write, %{advisory: %{present?: true}}), do: true
  defp advisory_memory_write?(_permission, _context), do: false

  defp approved_parent_analysis?(:stocksage_evidence_fetch, %{parent: parent})
       when is_map(parent) do
    Map.get(parent, :permission) in [:stocksage_analyze, "stocksage_analyze"] and
      Map.get(parent, :approved?) == true
  end

  defp approved_parent_analysis?(_permission, _context), do: false

  defp fixture_evidence?(:stocksage_evidence_fetch, %{resource: %{kind: kind}})
       when kind in [:fixture_evidence, "fixture_evidence"],
       do: true

  defp fixture_evidence?(_permission, _context), do: false

  defp reason(:read_only, :allowed, _configured, _floor, _context),
    do: "Read-only inspection is allowed locally."

  defp reason(:memory_write, :allowed, _configured, _floor, _context),
    do: "Memory-write intent is allowed for markdown memory."

  defp reason(:memory_write, :needs_confirmation, _configured, _floor, %{
         advisory: %{present?: true}
       }),
       do:
         "Advisory provider output requires explicit operator confirmation before durable memory writes."

  defp reason(:command_plan, :allowed, _configured, _floor, _context),
    do: "Planning shell work is allowed when no command executes."

  defp reason(:command_execute, :denied, _configured, _floor, _context),
    do: "Command execution is denied until local execution is explicitly enabled and confirmed."

  defp reason(:coding_file_read, :allowed, _configured, _floor, _context),
    do:
      "Pi-mode bounded file reads and searches are allowed through policy-bounded coding actions."

  defp reason(:coding_file_read, :needs_confirmation, _configured, _floor, _context),
    do: "Pi-mode bounded file reads and searches require confirmation by current policy."

  defp reason(:coding_file_read, :denied, _configured, _floor, _context),
    do: "Pi-mode bounded file reads and searches are denied by current policy."

  defp reason(:coding_file_write, :needs_confirmation, _configured, _floor, _context),
    do:
      "Pi-mode file writes and edits require confirmation unless a later local-coding tier suppresses only the prompt."

  defp reason(:coding_file_write, :denied, _configured, _floor, _context),
    do: "Pi-mode file writes and edits are denied by current policy."

  defp reason(:coding_shell_execute, :needs_confirmation, _configured, _floor, _context),
    do:
      "Pi-mode shell execution requires confirmation unless a later local-coding tier suppresses only the prompt."

  defp reason(:coding_shell_execute, :denied, _configured, _floor, _context),
    do: "Pi-mode shell execution is denied by current policy."

  defp reason(:external_network, :needs_confirmation, _configured, _floor, _context),
    do: "External network access requires confirmation and a configured v0.10 adapter."

  defp reason(:browser_session_start, :needs_confirmation, _configured, _floor, _context),
    do: "Starting a browser session requires explicit operator confirmation."

  defp reason(:browser_navigate, :needs_confirmation, _configured, _floor, _context),
    do: "Browser navigation requires confirmation or a matching remembered domain grant."

  defp reason(:browser_extract, :allowed, _configured, _floor, _context),
    do: "Bounded extraction from an already-loaded browser page is allowed."

  defp reason(:browser_screenshot, :allowed, _configured, _floor, _context),
    do: "Bounded browser screenshots are allowed with credential-input redaction."

  defp reason(:browser_interact, :needs_confirmation, _configured, _floor, _context),
    do: "Browser interaction can change page state and requires confirmation."

  defp reason(:browser_form_fill, :denied, _configured, _floor, _context),
    do: "Browser form fill is denied by default."

  defp reason(:browser_form_fill, :needs_confirmation, _configured, _floor, _context),
    do: "Browser form fill requires explicit opt-in and confirmation."

  defp reason(:browser_download, :denied, _configured, _floor, _context),
    do: "Browser download is denied by default."

  defp reason(:browser_download, :needs_confirmation, _configured, _floor, _context),
    do: "Browser download requires explicit opt-in and confirmation."

  defp reason(:workflow_read, :allowed, _configured, _floor, _context),
    do: "Workflow YAML inspection and expansion are local read-only operations."

  defp reason(:workflow_read, :needs_confirmation, _configured, _floor, _context),
    do: "Workflow YAML reads require confirmation by current policy."

  defp reason(:workflow_read, :denied, _configured, _floor, _context),
    do: "Workflow YAML reads are denied by current policy."

  defp reason(:workflow_run_start, :needs_confirmation, _configured, _floor, _context),
    do: "Starting a plan run requires explicit operator confirmation."

  defp reason(:workflow_run_start, :denied, _configured, _floor, _context),
    do: "Starting a plan run is denied by current policy."

  defp reason(:plan_cancel, :allowed, _configured, _floor, _context),
    do: "Cooperative plan cancellation is allowed through registered Plan/Build actions."

  defp reason(:plan_cancel, :needs_confirmation, _configured, _floor, _context),
    do: "Cooperative plan cancellation requires confirmation by current policy."

  defp reason(:plan_cancel, :denied, _configured, _floor, _context),
    do: "Cooperative plan cancellation is denied by current policy."

  defp reason(:job_write, :allowed, _configured, _floor, _context),
    do: "Scheduled-job control (pause/resume/run) on the operator's own jobs is allowed."

  defp reason(:job_write, :needs_confirmation, _configured, _floor, _context),
    do: "Scheduled-job control requires confirmation by current policy."

  defp reason(:job_write, :denied, _configured, _floor, _context),
    do: "Scheduled-job control is denied by current policy."

  defp reason(:marketplace_install, :allowed, _configured, _floor, _context),
    do: "Marketplace installs are allowed because shipped bundles land disabled and untrusted."

  defp reason(:marketplace_install, :needs_confirmation, _configured, _floor, _context),
    do: "Marketplace installs require confirmation by current policy."

  defp reason(:marketplace_install, :denied, _configured, _floor, _context),
    do: "Marketplace installs are denied by current policy."

  defp reason(:package_install, :denied, _configured, _floor, _context),
    do: "Package installation is denied until an operator explicitly enables confirmed installs."

  defp reason(:package_install, :needs_confirmation, _configured, _floor, _context),
    do:
      "Package installation requires confirmation, sandbox settings, and package manager policy."

  defp reason(:online_skill_import, :denied, _configured, _floor, _context),
    do: "Online skill import is denied until an operator explicitly enables the import boundary."

  defp reason(:online_skill_import, :needs_confirmation, _configured, _floor, _context),
    do: "Online skill import requires confirmation, source audit, and disabled-by-default trust."

  defp reason(:settings_write, :allowed, _configured, _floor, _context),
    do: "Safe Settings Central writes are allowed through registered settings actions."

  defp reason(:skill_write, :allowed, _configured, _floor, _context),
    do: "Local skill scaffold writes are allowed through registered skill actions."

  defp reason(:dynamic_codegen_request, :allowed, _configured, _floor, _context),
    do: "Explicit dynamic draft requests are allowed through the codegen request action."

  defp reason(:dynamic_codegen_request, :denied, _configured, _floor, _context),
    do: "Dynamic draft requests are denied by current policy."

  defp reason(:dynamic_codegen_discard, :allowed, _configured, _floor, _context),
    do: "Dynamic draft discard is allowed for non-integrated draft lifecycle cleanup."

  defp reason(:dynamic_codegen_discard, :denied, _configured, _floor, _context),
    do: "Dynamic draft discard is denied by current policy."

  defp reason(:skill_script_execute, :denied, _configured, _floor, _context),
    do: "Skill script execution is denied until explicitly enabled and confirmed."

  defp reason(:skill_script_execute, :needs_confirmation, _configured, _floor, _context),
    do: "Trusted skill script execution requires confirmation and resource digest checks."

  defp reason(:confirmation_decide, :allowed, _configured, _floor, _context),
    do: "Confirmation approval and denial are allowed for the local operator."

  defp reason(:objective_write, :allowed, _configured, _floor, _context),
    do: "Objective lifecycle writes are allowed through registered objective actions."

  defp reason(:objective_write, :denied, _configured, _floor, _context),
    do: "Objective lifecycle writes are denied by current policy."

  defp reason(:workspace_canvas_write, :allowed, _configured, _floor, _context),
    do: "Workspace canvas writes are allowed through registered workspace actions."

  defp reason(:workspace_canvas_write, :denied, _configured, _floor, _context),
    do: "Workspace canvas writes are denied by current policy."

  defp reason(:sandbox_trial, :allowed, _configured, _floor, _context),
    do:
      "Sandbox trial execution is allowed only through default-off sandbox settings and registered sandbox actions."

  defp reason(:sandbox_trial, :denied, _configured, _floor, _context),
    do: "Sandbox trial execution is denied by current policy."

  defp reason(:dynamic_integration, :needs_confirmation, _configured, _floor, _context),
    do:
      "Dynamic integration hot-loads reviewed code into the core node and requires operator confirmation."

  defp reason(:dynamic_integration, :denied, _configured, _floor, _context),
    do: "Dynamic integration is denied by current policy."

  defp reason(:stocksage_write, :allowed, _configured, _floor, _context),
    do: "Local StockSage domain writes are allowed through registered StockSage actions."

  defp reason(:stocksage_analyze, :needs_confirmation, _configured, _floor, _context),
    do:
      "StockSage analysis execution requires confirmation; the Python bridge makes external market-data calls."

  defp reason(:stocksage_analyze, :denied, _configured, _floor, _context),
    do: "StockSage analysis execution is denied by current policy."

  defp reason(:stocksage_evidence_fetch, :allowed, _configured, _floor, _context),
    do: "StockSage evidence fetch is allowed inside an approved StockSage analysis run."

  defp reason(:stocksage_evidence_fetch, :needs_confirmation, _configured, _floor, _context),
    do:
      "StockSage evidence fetch requires Resource Access confirmation outside an approved analysis run."

  defp reason(:stocksage_evidence_fetch, :denied, _configured, _floor, _context),
    do: "StockSage evidence fetch is denied by current policy."

  defp reason(:microphone_capture, :needs_confirmation, _configured, _floor, _context),
    do: "Microphone capture requires per-session operator confirmation."

  defp reason(:microphone_capture, :denied, _configured, _floor, _context),
    do: "Microphone capture is denied by current policy."

  defp reason(:voice_transcribe, :allowed, _configured, _floor, _context),
    do: "Voice transcription is allowed for an already local/in-process provider boundary."

  defp reason(:voice_transcribe, :needs_confirmation, _configured, _floor, _context),
    do:
      "Voice transcription can upload audio across a socket or unresolved boundary and requires confirmation."

  defp reason(:voice_transcribe, :denied, _configured, _floor, _context),
    do: "Voice transcription is denied by current policy."

  defp reason(:voice_synthesize, :allowed, _configured, _floor, _context),
    do: "Voice synthesis is allowed for an already local/in-process provider boundary."

  defp reason(:voice_synthesize, :needs_confirmation, _configured, _floor, _context),
    do:
      "Voice synthesis can cross a socket or unresolved provider boundary and requires confirmation."

  defp reason(:voice_synthesize, :denied, _configured, _floor, _context),
    do: "Voice synthesis is denied by current policy."

  defp reason(:voice_local_runtime_manage, :allowed, _configured, _floor, _context),
    do: "The Allbert local voice runtime may bind to the loopback interface."

  defp reason(:voice_local_runtime_manage, :needs_confirmation, _configured, _floor, _context),
    do: "Starting or managing the Allbert local voice runtime requires confirmation."

  defp reason(:voice_local_runtime_manage, :denied, _configured, _floor, _context),
    do: "The Allbert local voice runtime is denied by current policy."

  defp reason(:image_input, :allowed, _configured, _floor, _context),
    do: "Operator-supplied image input is allowed after server-side bounds and redaction."

  defp reason(:image_input, :needs_confirmation, _configured, _floor, _context),
    do: "Operator-supplied image input requires confirmation by current policy."

  defp reason(:image_input, :denied, _configured, _floor, _context),
    do: "Image input is denied by current policy."

  defp reason(:image_generate, :allowed, _configured, _floor, _context),
    do: "Image generation is allowed only for an explicitly fake provider profile."

  defp reason(:image_generate, :needs_confirmation, _configured, _floor, _context),
    do:
      "Image generation can create billable media through a provider boundary and requires confirmation."

  defp reason(:image_generate, :denied, _configured, _floor, _context),
    do: "Image generation is denied by current policy."

  defp reason(:artifact_read, :allowed, _configured, _floor, _context),
    do: "Artifact reads are allowed after Resource Access and redaction."

  defp reason(:artifact_read, :needs_confirmation, _configured, _floor, _context),
    do: "Artifact reads require confirmation by current policy."

  defp reason(:artifact_read, :denied, _configured, _floor, _context),
    do: "Artifact reads are denied by current policy."

  defp reason(:artifact_write, :allowed, _configured, _floor, _context),
    do: "Artifact writes are allowed after ingest bounds and redaction."

  defp reason(:artifact_write, :needs_confirmation, _configured, _floor, _context),
    do: "Artifact writes require confirmation by current policy."

  defp reason(:artifact_write, :denied, _configured, _floor, _context),
    do: "Artifact writes are denied by current policy."

  defp reason(:artifact_delete, :needs_confirmation, _configured, _floor, _context),
    do: "Artifact deletion removes durable local content and requires confirmation."

  defp reason(:artifact_delete, :denied, _configured, _floor, _context),
    do: "Artifact deletion is denied by current policy."

  defp reason(:tool_discovery, :allowed, _configured, _floor, _context),
    do: "Tool discovery search is allowed through registered discovery actions."

  defp reason(:tool_discovery, :denied, _configured, _floor, _context),
    do: "Tool discovery search is denied by current policy."

  defp reason(:mcp_server_connect, :needs_confirmation, _configured, _floor, _context),
    do: "Connecting discovered MCP servers requires explicit operator confirmation."

  defp reason(:mcp_server_connect, :denied, _configured, _floor, _context),
    do: "Connecting discovered MCP servers is denied by current policy."

  defp reason(:mcp_tool_call, :needs_confirmation, _configured, _floor, _context),
    do: "MCP tool calls require explicit operator confirmation."

  defp reason(:mcp_tool_call, :denied, _configured, _floor, _context),
    do: "MCP tool calls are denied by current policy."

  defp reason(:mcp_resource_read, :allowed, _configured, _floor, _context),
    do: "MCP resource reads are allowed through registered MCP resource actions."

  defp reason(:mcp_resource_read, :needs_confirmation, _configured, _floor, _context),
    do: "MCP resource reads require operator confirmation by current policy."

  defp reason(:mcp_resource_read, :denied, _configured, _floor, _context),
    do: "MCP resource reads are denied by current policy."

  defp reason(:public_surface_call_inbound, :needs_confirmation, _configured, _floor, _context),
    do: "Inbound public protocol clients require operator confirmation before effectful work."

  defp reason(:public_surface_call_inbound, :denied, _configured, _floor, _context),
    do: "Inbound public protocol calls are denied by current policy."

  defp reason(:channel_message_inbound, :needs_confirmation, _configured, _floor, _context),
    do: "Inbound channel messages require operator confirmation before effectful work."

  defp reason(:channel_message_inbound, :allowed, _configured, _floor, _context),
    do: "Inbound channel messages are allowed to enter runtime after channel identity checks."

  defp reason(:channel_message_inbound, :denied, _configured, _floor, _context),
    do: "Inbound channel messages are denied by current policy."

  defp reason(:settings_secret_write, :allowed, _configured, _floor, _context),
    do: "Provider credentials may be configured through explicit credential flows."

  defp reason(:settings_secret_read, :denied, _configured, _floor, _context),
    do: "Raw secret display is not available from user-facing settings surfaces."

  defp reason(permission, :denied, _configured, _floor, _context),
    do: "Unknown permission class: #{inspect(permission)}."

  defp reason(permission, :needs_confirmation, _configured, _floor, _context),
    do: "Permission requires confirmation before it can run: #{inspect(permission)}."

  defp reason(permission, :allowed, _configured, _floor, _context),
    do: "Permission is allowed by current policy: #{inspect(permission)}."
end
