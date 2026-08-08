defmodule AllbertAssist.Settings.FragmentOwners.Permissions do
  @moduledoc false
  @behaviour AllbertAssist.Settings.FragmentOwner
  alias AllbertAssist.Settings.Fragment

  @schema %{
    "permissions.artifact_delete" => %{
      allowed_values: ["needs_confirmation", "denied"],
      default: "needs_confirmation",
      sensitive?: false,
      type: :enum,
      writable?: true
    },
    "permissions.artifact_read" => %{
      allowed_values: ["allowed", "needs_confirmation", "denied"],
      default: "allowed",
      sensitive?: false,
      type: :enum,
      writable?: true
    },
    "permissions.artifact_write" => %{
      allowed_values: ["allowed", "needs_confirmation", "denied"],
      default: "allowed",
      sensitive?: false,
      type: :enum,
      writable?: true
    },
    "permissions.browser_download" => %{
      allowed_values: ["needs_confirmation", "denied"],
      default: "denied",
      sensitive?: false,
      type: :enum,
      writable?: true
    },
    "permissions.browser_extract" => %{
      allowed_values: ["allowed", "needs_confirmation", "denied"],
      default: "allowed",
      sensitive?: false,
      type: :enum,
      writable?: true
    },
    "permissions.browser_form_fill" => %{
      allowed_values: ["needs_confirmation", "denied"],
      default: "denied",
      sensitive?: false,
      type: :enum,
      writable?: true
    },
    "permissions.browser_interact" => %{
      allowed_values: ["needs_confirmation", "denied"],
      default: "needs_confirmation",
      sensitive?: false,
      type: :enum,
      writable?: true
    },
    "permissions.browser_navigate" => %{
      allowed_values: ["needs_confirmation", "denied"],
      default: "needs_confirmation",
      sensitive?: false,
      type: :enum,
      writable?: true
    },
    "permissions.browser_screenshot" => %{
      allowed_values: ["allowed", "needs_confirmation", "denied"],
      default: "allowed",
      sensitive?: false,
      type: :enum,
      writable?: true
    },
    "permissions.browser_session_start" => %{
      allowed_values: ["needs_confirmation", "denied"],
      default: "needs_confirmation",
      sensitive?: false,
      type: :enum,
      writable?: true
    },
    "permissions.calendar_write" => %{
      allowed_values: ["allowed", "needs_confirmation", "denied"],
      default: "needs_confirmation",
      sensitive?: false,
      type: :enum,
      writable?: true
    },
    "permissions.channel_autonomous_notify" => %{
      allowed_values: ["allowed", "denied"],
      default: "allowed",
      sensitive?: false,
      type: :enum,
      writable?: true
    },
    "permissions.channel_message_inbound" => %{
      allowed_values: ["needs_confirmation", "denied"],
      default: "needs_confirmation",
      sensitive?: false,
      type: :enum,
      writable?: true
    },
    "permissions.channel_message_send" => %{
      allowed_values: ["allowed", "needs_confirmation", "denied"],
      default: "needs_confirmation",
      sensitive?: false,
      type: :enum,
      writable?: true
    },
    "permissions.coding_file_read" => %{
      allowed_values: ["allowed", "needs_confirmation", "denied"],
      default: "allowed",
      sensitive?: false,
      type: :enum,
      writable?: true
    },
    "permissions.coding_file_write" => %{
      allowed_values: ["allowed", "needs_confirmation", "denied"],
      default: "needs_confirmation",
      sensitive?: false,
      type: :enum,
      writable?: true
    },
    "permissions.coding_shell_execute" => %{
      allowed_values: ["allowed", "needs_confirmation", "denied"],
      default: "needs_confirmation",
      sensitive?: false,
      type: :enum,
      writable?: true
    },
    "permissions.command_execute" => %{
      allowed_values: ["allowed", "needs_confirmation", "denied"],
      default: "denied",
      sensitive?: false,
      type: :enum,
      writable?: true
    },
    "permissions.command_plan" => %{
      allowed_values: ["allowed", "needs_confirmation", "denied"],
      default: "allowed",
      sensitive?: false,
      type: :enum,
      writable?: true
    },
    "permissions.confirmation_decide" => %{
      allowed_values: ["allowed", "denied"],
      default: "allowed",
      sensitive?: false,
      type: :enum,
      writable?: true
    },
    "permissions.dynamic_codegen_discard" => %{
      allowed_values: ["allowed", "needs_confirmation", "denied"],
      default: "allowed",
      sensitive?: false,
      type: :enum,
      writable?: true
    },
    "permissions.dynamic_codegen_request" => %{
      allowed_values: ["allowed", "needs_confirmation", "denied"],
      default: "allowed",
      sensitive?: false,
      type: :enum,
      writable?: true
    },
    "permissions.dynamic_integration" => %{
      allowed_values: ["needs_confirmation", "denied"],
      default: "needs_confirmation",
      sensitive?: false,
      type: :enum,
      writable?: true
    },
    "permissions.email_send" => %{
      allowed_values: ["allowed", "needs_confirmation", "denied"],
      default: "needs_confirmation",
      sensitive?: false,
      type: :enum,
      writable?: true
    },
    "permissions.external_network" => %{
      allowed_values: ["allowed", "needs_confirmation", "denied"],
      default: "needs_confirmation",
      sensitive?: false,
      type: :enum,
      writable?: true
    },
    "permissions.image_generate" => %{
      allowed_values: ["allowed", "needs_confirmation", "denied"],
      default: "allowed",
      sensitive?: false,
      type: :enum,
      writable?: true
    },
    "permissions.image_input" => %{
      allowed_values: ["allowed", "needs_confirmation", "denied"],
      default: "allowed",
      sensitive?: false,
      type: :enum,
      writable?: true
    },
    "permissions.marketplace_install" => %{
      allowed_values: ["allowed", "needs_confirmation", "denied"],
      default: "allowed",
      sensitive?: false,
      type: :enum,
      writable?: true
    },
    "permissions.mcp_resource_read" => %{
      allowed_values: ["allowed", "needs_confirmation", "denied"],
      default: "allowed",
      sensitive?: false,
      type: :enum,
      writable?: true
    },
    "permissions.mcp_server_connect" => %{
      allowed_values: ["needs_confirmation", "denied"],
      default: "needs_confirmation",
      sensitive?: false,
      type: :enum,
      writable?: true
    },
    "permissions.mcp_tool_call" => %{
      allowed_values: ["needs_confirmation", "denied"],
      default: "needs_confirmation",
      sensitive?: false,
      type: :enum,
      writable?: true
    },
    "permissions.memory_propose" => %{
      allowed_values: ["allowed", "needs_confirmation", "denied"],
      default: "allowed",
      sensitive?: false,
      type: :enum,
      writable?: true
    },
    "permissions.memory_write" => %{
      allowed_values: ["allowed", "needs_confirmation", "denied"],
      default: "allowed",
      sensitive?: false,
      type: :enum,
      writable?: true
    },
    "permissions.microphone_capture" => %{
      allowed_values: ["needs_confirmation", "denied"],
      default: "needs_confirmation",
      sensitive?: false,
      type: :enum,
      writable?: true
    },
    "permissions.notes_file_write" => %{
      allowed_values: ["needs_confirmation", "denied"],
      default: "needs_confirmation",
      sensitive?: false,
      type: :enum,
      writable?: true
    },
    "permissions.objective_write" => %{
      allowed_values: ["allowed", "needs_confirmation", "denied"],
      default: "allowed",
      sensitive?: false,
      type: :enum,
      writable?: true
    },
    "permissions.online_skill_import" => %{
      allowed_values: ["allowed", "needs_confirmation", "denied"],
      default: "denied",
      sensitive?: false,
      type: :enum,
      writable?: true
    },
    "permissions.package_install" => %{
      allowed_values: ["allowed", "needs_confirmation", "denied"],
      default: "denied",
      sensitive?: false,
      type: :enum,
      writable?: true
    },
    "permissions.plan_cancel" => %{
      allowed_values: ["allowed", "needs_confirmation", "denied"],
      default: "allowed",
      sensitive?: false,
      type: :enum,
      writable?: true
    },
    "permissions.public_surface_call_inbound" => %{
      allowed_values: ["needs_confirmation", "denied"],
      default: "needs_confirmation",
      sensitive?: false,
      type: :enum,
      writable?: true
    },
    "permissions.sandbox_trial" => %{
      allowed_values: ["allowed", "denied"],
      default: "allowed",
      sensitive?: false,
      type: :enum,
      writable?: true
    },
    "permissions.search_manage" => %{
      allowed_values: ["allowed", "needs_confirmation", "denied"],
      default: "allowed",
      sensitive?: false,
      type: :enum,
      writable?: true
    },
    "permissions.settings_write" => %{
      allowed_values: ["allowed_safe_keys", "needs_confirmation", "denied"],
      default: "allowed_safe_keys",
      sensitive?: false,
      type: :enum,
      writable?: true
    },
    "permissions.skill_script_execute" => %{
      allowed_values: ["allowed", "needs_confirmation", "denied"],
      default: "denied",
      sensitive?: false,
      type: :enum,
      writable?: true
    },
    "permissions.skill_write" => %{
      allowed_values: ["allowed", "needs_confirmation", "denied"],
      default: "allowed",
      sensitive?: false,
      type: :enum,
      writable?: true
    },
    "permissions.stocksage_analyze" => %{
      allowed_values: ["needs_confirmation", "denied"],
      default: "needs_confirmation",
      sensitive?: false,
      type: :enum,
      writable?: true
    },
    "permissions.stocksage_evidence_fetch" => %{
      allowed_values: ["allowed", "needs_confirmation", "denied"],
      default: "allowed",
      sensitive?: false,
      type: :enum,
      writable?: true
    },
    "permissions.stocksage_write" => %{
      allowed_values: ["allowed", "needs_confirmation", "denied"],
      default: "allowed",
      sensitive?: false,
      type: :enum,
      writable?: true
    },
    "permissions.tool_discovery" => %{
      allowed_values: ["allowed", "denied"],
      default: "allowed",
      sensitive?: false,
      type: :enum,
      writable?: true
    },
    "permissions.voice_local_runtime_manage" => %{
      allowed_values: ["allowed", "needs_confirmation", "denied"],
      default: "allowed",
      sensitive?: false,
      type: :enum,
      writable?: true
    },
    "permissions.voice_synthesize" => %{
      allowed_values: ["allowed", "needs_confirmation", "denied"],
      default: "allowed",
      sensitive?: false,
      type: :enum,
      writable?: true
    },
    "permissions.voice_transcribe" => %{
      allowed_values: ["allowed", "needs_confirmation", "denied"],
      default: "allowed",
      sensitive?: false,
      type: :enum,
      writable?: true
    },
    "permissions.workflow_read" => %{
      allowed_values: ["allowed", "needs_confirmation", "denied"],
      default: "allowed",
      sensitive?: false,
      type: :enum,
      writable?: true
    },
    "permissions.workflow_run_start" => %{
      allowed_values: ["needs_confirmation", "denied"],
      default: "needs_confirmation",
      sensitive?: false,
      type: :enum,
      writable?: true
    },
    "permissions.workspace_canvas_write" => %{
      allowed_values: ["allowed", "needs_confirmation", "denied"],
      default: "allowed",
      sensitive?: false,
      type: :enum,
      writable?: true
    }
  }
  @defaults %{
    "permissions" => %{
      "artifact_delete" => "needs_confirmation",
      "artifact_read" => "allowed",
      "artifact_write" => "allowed",
      "browser_download" => "denied",
      "browser_extract" => "allowed",
      "browser_form_fill" => "denied",
      "browser_interact" => "needs_confirmation",
      "browser_navigate" => "needs_confirmation",
      "browser_screenshot" => "allowed",
      "browser_session_start" => "needs_confirmation",
      "calendar_write" => "needs_confirmation",
      "channel_autonomous_notify" => "allowed",
      "channel_message_inbound" => "needs_confirmation",
      "channel_message_send" => "needs_confirmation",
      "coding_file_read" => "allowed",
      "coding_file_write" => "needs_confirmation",
      "coding_shell_execute" => "needs_confirmation",
      "command_execute" => "denied",
      "command_plan" => "allowed",
      "confirmation_decide" => "allowed",
      "dynamic_codegen_discard" => "allowed",
      "dynamic_codegen_request" => "allowed",
      "dynamic_integration" => "needs_confirmation",
      "email_send" => "needs_confirmation",
      "external_network" => "needs_confirmation",
      "image_generate" => "allowed",
      "image_input" => "allowed",
      "marketplace_install" => "allowed",
      "mcp_resource_read" => "allowed",
      "mcp_server_connect" => "needs_confirmation",
      "mcp_tool_call" => "needs_confirmation",
      "memory_propose" => "allowed",
      "memory_write" => "allowed",
      "microphone_capture" => "needs_confirmation",
      "notes_file_write" => "needs_confirmation",
      "objective_write" => "allowed",
      "online_skill_import" => "denied",
      "package_install" => "denied",
      "plan_cancel" => "allowed",
      "public_surface_call_inbound" => "needs_confirmation",
      "sandbox_trial" => "allowed",
      "search_manage" => "allowed",
      "settings_write" => "allowed_safe_keys",
      "skill_script_execute" => "denied",
      "skill_write" => "allowed",
      "stocksage_analyze" => "needs_confirmation",
      "stocksage_evidence_fetch" => "allowed",
      "stocksage_write" => "allowed",
      "tool_discovery" => "allowed",
      "voice_local_runtime_manage" => "allowed",
      "voice_synthesize" => "allowed",
      "voice_transcribe" => "allowed",
      "workflow_read" => "allowed",
      "workflow_run_start" => "needs_confirmation",
      "workspace_canvas_write" => "allowed"
    }
  }
  @safe_write_keys [
    "permissions.memory_propose",
    "permissions.memory_write",
    "permissions.search_manage",
    "permissions.command_plan",
    "permissions.command_execute",
    "permissions.coding_file_read",
    "permissions.coding_file_write",
    "permissions.coding_shell_execute",
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
    "permissions.channel_autonomous_notify",
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
    "permissions.calendar_write"
  ]
  @safe_write_rows [
    {149, "permissions.memory_propose"},
    {150, "permissions.memory_write"},
    {151, "permissions.search_manage"},
    {152, "permissions.command_plan"},
    {153, "permissions.command_execute"},
    {154, "permissions.coding_file_read"},
    {155, "permissions.coding_file_write"},
    {156, "permissions.coding_shell_execute"},
    {157, "permissions.external_network"},
    {158, "permissions.package_install"},
    {159, "permissions.online_skill_import"},
    {160, "permissions.settings_write"},
    {161, "permissions.skill_write"},
    {162, "permissions.dynamic_codegen_request"},
    {163, "permissions.dynamic_codegen_discard"},
    {164, "permissions.skill_script_execute"},
    {165, "permissions.confirmation_decide"},
    {166, "permissions.objective_write"},
    {167, "permissions.workspace_canvas_write"},
    {168, "permissions.sandbox_trial"},
    {169, "permissions.dynamic_integration"},
    {170, "permissions.stocksage_write"},
    {171, "permissions.stocksage_analyze"},
    {172, "permissions.stocksage_evidence_fetch"},
    {173, "permissions.notes_file_write"},
    {174, "permissions.microphone_capture"},
    {175, "permissions.voice_transcribe"},
    {176, "permissions.voice_synthesize"},
    {177, "permissions.voice_local_runtime_manage"},
    {178, "permissions.image_input"},
    {179, "permissions.image_generate"},
    {180, "permissions.artifact_read"},
    {181, "permissions.artifact_write"},
    {182, "permissions.artifact_delete"},
    {183, "permissions.tool_discovery"},
    {184, "permissions.mcp_server_connect"},
    {185, "permissions.mcp_tool_call"},
    {186, "permissions.mcp_resource_read"},
    {187, "permissions.public_surface_call_inbound"},
    {188, "permissions.channel_message_inbound"},
    {189, "permissions.channel_autonomous_notify"},
    {237, "permissions.browser_session_start"},
    {238, "permissions.browser_navigate"},
    {239, "permissions.browser_extract"},
    {240, "permissions.browser_screenshot"},
    {241, "permissions.browser_interact"},
    {242, "permissions.browser_form_fill"},
    {243, "permissions.browser_download"},
    {244, "permissions.workflow_read"},
    {245, "permissions.workflow_run_start"},
    {246, "permissions.plan_cancel"},
    {247, "permissions.marketplace_install"},
    {248, "permissions.email_send"},
    {249, "permissions.channel_message_send"},
    {250, "permissions.calendar_write"}
  ]
  @impl true
  def fragment do
    Fragment.new!(%{
      id: "core:permissions",
      owner: "permissions",
      source: :core,
      group: "permissions",
      schema: @schema,
      defaults: @defaults,
      safe_write_keys: @safe_write_keys,
      metadata: %{label: "Permissions"}
    })
  end

  @impl true
  def safe_write_rows, do: @safe_write_rows
end
