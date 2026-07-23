defmodule AllbertAssist.Security.PermissionGateTest do
  use ExUnit.Case, async: true
  @moduletag :external_runtime_serial

  alias AllbertAssist.Security.PermissionGate
  alias AllbertAssist.Security.Policy

  test "documents the runtime permission classes" do
    assert PermissionGate.permission_classes() == [
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
             :channel_autonomous_notify,
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

  test "allows local conversation continuity writes" do
    decision = PermissionGate.authorize(:conversation_write, %{})

    assert decision.permission == :conversation_write
    assert decision.decision == :allowed
    assert decision.policy.safety_floor == :allowed
    assert decision.risk.tier == :low
    assert PermissionGate.allowed?(decision)
  end

  test "requires confirmation for StockSage analysis execution" do
    decision = PermissionGate.authorize(:stocksage_analyze, %{})

    assert decision.permission == :stocksage_analyze
    assert decision.decision == :needs_confirmation
    assert decision.requires_confirmation
    assert decision.risk.tier == :high
    refute PermissionGate.allowed?(decision)
    assert PermissionGate.response_status(decision) == :needs_confirmation
  end

  test "stocksage_analyze cannot be lowered to :allowed by settings" do
    # Safety floor is needs_confirmation; even a misconfigured value cannot
    # weaken the decision.
    decision = PermissionGate.authorize(:stocksage_analyze, %{})
    assert decision.decision in [:needs_confirmation, :denied]
  end

  test "requires confirmation for MCP tool calls and allows MCP resource reads" do
    tool_call = PermissionGate.authorize(:mcp_tool_call, %{})

    assert tool_call.permission == :mcp_tool_call
    assert tool_call.decision == :needs_confirmation
    assert tool_call.requires_confirmation
    assert tool_call.risk.tier == :high
    refute PermissionGate.allowed?(tool_call)

    resource_read = PermissionGate.authorize(:mcp_resource_read, %{})

    assert resource_read.permission == :mcp_resource_read
    assert resource_read.decision == :allowed
    refute resource_read.requires_confirmation
    assert resource_read.risk.tier == :medium
    assert PermissionGate.allowed?(resource_read)
  end

  test "documents browser permission floors and denied defaults" do
    navigate = PermissionGate.authorize(:browser_navigate, %{})
    assert navigate.decision == :needs_confirmation
    assert navigate.requires_confirmation

    extract = PermissionGate.authorize(:browser_extract, %{})
    assert extract.decision == :allowed
    assert PermissionGate.allowed?(extract)

    form_fill = PermissionGate.authorize(:browser_form_fill, %{})
    assert form_fill.decision == :denied
    refute PermissionGate.allowed?(form_fill)
    assert form_fill.policy.safety_floor == :needs_confirmation

    download = PermissionGate.authorize(:browser_download, %{})
    assert download.decision == :denied
    assert download.policy.safety_floor == :needs_confirmation
  end

  test "documents Plan/Build permission floors" do
    workflow_read = PermissionGate.authorize(:workflow_read, %{})
    assert workflow_read.decision == :allowed
    assert workflow_read.policy.safety_floor == :allowed
    assert PermissionGate.allowed?(workflow_read)

    run_start = PermissionGate.authorize(:workflow_run_start, %{})
    assert run_start.decision == :needs_confirmation
    assert run_start.requires_confirmation
    assert run_start.policy.safety_floor == :needs_confirmation
    refute PermissionGate.allowed?(run_start)

    cancel = PermissionGate.authorize(:plan_cancel, %{})
    assert cancel.decision == :allowed
    assert cancel.policy.safety_floor == :allowed
    assert PermissionGate.allowed?(cancel)
  end

  test "documents Marketplace Lite install permission floor" do
    install = PermissionGate.authorize(:marketplace_install, %{})

    assert install.permission == :marketplace_install
    assert install.decision == :allowed
    assert install.policy.safety_floor == :allowed
    assert install.risk.tier == :medium
    refute install.requires_confirmation
    assert PermissionGate.allowed?(install)
  end

  test "documents voice permission floors by provider deployment mode" do
    capture = PermissionGate.authorize(:microphone_capture, %{})
    assert capture.decision == :needs_confirmation
    assert capture.requires_confirmation
    assert capture.policy.safety_floor == :needs_confirmation
    assert capture.risk.tier == :high

    fake_transcribe =
      PermissionGate.authorize(:voice_transcribe, %{provider_deployment_mode: :fake})

    assert fake_transcribe.decision == :allowed
    assert fake_transcribe.policy.safety_floor == :allowed
    assert PermissionGate.allowed?(fake_transcribe)

    bundled_synthesis =
      PermissionGate.authorize(:voice_synthesize, %{provider_deployment_mode: :bundled_local})

    assert bundled_synthesis.decision == :allowed
    assert bundled_synthesis.policy.safety_floor == :allowed
    assert PermissionGate.allowed?(bundled_synthesis)

    local_transcribe =
      PermissionGate.authorize(:voice_transcribe, %{provider_deployment_mode: :local_endpoint})

    assert local_transcribe.decision == :needs_confirmation
    assert local_transcribe.policy.safety_floor == :needs_confirmation
    refute PermissionGate.allowed?(local_transcribe)

    remote_synthesis =
      PermissionGate.authorize(:voice_synthesize, %{
        model_profile: %{media: %{"deployment_mode" => "remote_credentialed"}}
      })

    assert remote_synthesis.decision == :needs_confirmation
    assert remote_synthesis.policy.safety_floor == :needs_confirmation
    refute PermissionGate.allowed?(remote_synthesis)

    unknown_transcribe =
      PermissionGate.authorize(:voice_transcribe, %{provider_deployment_mode: nil})

    assert unknown_transcribe.decision == :needs_confirmation
    assert unknown_transcribe.policy.safety_floor == :needs_confirmation
    refute PermissionGate.allowed?(unknown_transcribe)

    local_runtime = PermissionGate.authorize(:voice_local_runtime_manage, %{})

    assert local_runtime.decision == :allowed
    assert local_runtime.policy.safety_floor == :allowed
    assert local_runtime.risk.tier == :medium
    assert PermissionGate.allowed?(local_runtime)
  end

  test "documents image permission floors by provider deployment mode" do
    input = PermissionGate.authorize(:image_input, %{})

    assert input.decision == :allowed
    assert input.policy.safety_floor == :allowed
    assert input.risk.tier == :medium
    assert PermissionGate.allowed?(input)

    fake_generation =
      PermissionGate.authorize(:image_generate, %{provider_deployment_mode: :fake})

    assert fake_generation.decision == :allowed
    assert fake_generation.policy.safety_floor == :allowed
    assert fake_generation.risk.tier == :high
    assert PermissionGate.allowed?(fake_generation)

    remote_generation =
      PermissionGate.authorize(:image_generate, %{
        model_profile: %{media: %{"deployment_mode" => "remote_credentialed"}}
      })

    assert remote_generation.decision == :needs_confirmation
    assert remote_generation.policy.safety_floor == :needs_confirmation
    refute PermissionGate.allowed?(remote_generation)

    local_generation =
      PermissionGate.authorize(:image_generate, %{provider_deployment_mode: :local_endpoint})

    assert local_generation.decision == :needs_confirmation
    assert local_generation.policy.safety_floor == :needs_confirmation
    refute PermissionGate.allowed?(local_generation)

    unknown_generation =
      PermissionGate.authorize(:image_generate, %{provider_deployment_mode: nil})

    assert unknown_generation.decision == :needs_confirmation
    assert unknown_generation.policy.safety_floor == :needs_confirmation
    refute PermissionGate.allowed?(unknown_generation)
  end

  test "documents artifact permission floors" do
    read = PermissionGate.authorize(:artifact_read, %{})
    assert read.decision == :allowed
    assert read.policy.safety_floor == :allowed
    assert read.risk.tier == :medium
    assert PermissionGate.allowed?(read)

    write = PermissionGate.authorize(:artifact_write, %{})
    assert write.decision == :allowed
    assert write.policy.safety_floor == :allowed
    assert write.risk.tier == :medium
    assert PermissionGate.allowed?(write)

    delete = PermissionGate.authorize(:artifact_delete, %{})
    assert delete.decision == :needs_confirmation
    assert delete.policy.safety_floor == :needs_confirmation
    assert delete.risk.tier == :high
    refute PermissionGate.allowed?(delete)
  end

  test "allows discovery search but requires confirmation for discovered MCP server connect" do
    discovery = PermissionGate.authorize(:tool_discovery, %{})

    assert discovery.permission == :tool_discovery
    assert discovery.decision == :allowed
    refute discovery.requires_confirmation
    assert discovery.risk.tier == :medium
    assert PermissionGate.allowed?(discovery)

    connect = PermissionGate.authorize(:mcp_server_connect, %{})

    assert connect.permission == :mcp_server_connect
    assert connect.decision == :needs_confirmation
    assert connect.requires_confirmation
    assert connect.risk.tier == :high
    refute PermissionGate.allowed?(connect)
  end

  test "requires confirmation for dynamic integration hot-loading" do
    decision = PermissionGate.authorize(:dynamic_integration, %{})

    assert decision.permission == :dynamic_integration
    assert decision.decision == :needs_confirmation
    assert decision.requires_confirmation
    assert decision.risk.tier == :critical
    refute PermissionGate.allowed?(decision)
    assert PermissionGate.response_status(decision) == :needs_confirmation
  end

  test "allows read-only, memory-write intent, command planning, sandbox trials, and local writes" do
    for permission <- [
          :read_only,
          :memory_write,
          :command_plan,
          :objective_write,
          :workspace_canvas_write,
          :sandbox_trial,
          :stocksage_write
        ] do
      decision = PermissionGate.authorize(permission, %{})

      assert decision.permission == permission
      assert decision.decision == :allowed
      refute decision.requires_confirmation
      assert PermissionGate.allowed?(decision)
      assert PermissionGate.response_status(decision) == :completed
      assert_compatibility_fields(decision)
    end
  end

  test "does not allow command execution without confirmation" do
    default_policy = Policy.resolve(:command_execute, %{}, %{})
    assert default_policy.source == :built_in_default
    assert default_policy.configured_decision == :denied
    assert default_policy.effective == :denied
    assert default_policy.safety_floor == :needs_confirmation

    decision = PermissionGate.authorize(:command_execute, %{})

    assert decision.permission == :command_execute
    assert decision.decision in [:denied, :needs_confirmation]
    assert decision.policy.safety_floor == :needs_confirmation
    assert decision.requires_confirmation == (decision.decision == :needs_confirmation)
    refute PermissionGate.allowed?(decision)
    assert PermissionGate.response_status(decision) == decision.decision
    assert_compatibility_fields(decision)
  end

  test "registers v0.57 coding permissions with declared floors" do
    assert :coding_file_read in PermissionGate.permission_classes()
    assert :coding_file_write in PermissionGate.permission_classes()
    assert :coding_shell_execute in PermissionGate.permission_classes()
    refute :coding_session_write in PermissionGate.permission_classes()

    read = PermissionGate.authorize(:coding_file_read, %{})
    assert read.decision == :allowed
    assert read.policy.setting_key == "permissions.coding_file_read"
    assert read.policy.safety_floor == :allowed
    assert read.risk.tier == :medium
    refute read.requires_confirmation

    for permission <- [:coding_file_write, :coding_shell_execute] do
      decision = PermissionGate.authorize(permission, %{})

      assert decision.decision == :needs_confirmation
      assert decision.policy.setting_key == "permissions.#{permission}"
      assert decision.policy.safety_floor == :needs_confirmation
      assert decision.risk.tier == :high
      assert decision.requires_confirmation
      assert decision.trace.requires_confirmation
      assert_compatibility_fields(decision)
    end
  end

  test "declares v0.57 approval modes and local-coding tier vocabulary" do
    assert PermissionGate.approval_modes() == [:default, :accept_edits, :plan, :tier]
    assert PermissionGate.coding_tiers() == [:none, :local_coding_operator]

    trusted_context = %{
      actor: %{id: "local"},
      channel: %{name: :tui},
      session: %{main?: true},
      coding: %{
        pi_mode_enabled: true,
        trusted_operator_id: "local",
        approval_mode: "accept-edits"
      }
    }

    assert PermissionGate.coding_tier(trusted_context) == :local_coding_operator
    assert PermissionGate.approval_mode(trusted_context) == :accept_edits

    assert PermissionGate.coding_tier(%{trusted_context | channel: %{name: :telegram}}) == :none
    assert PermissionGate.coding_tier(%{trusted_context | session: %{main?: false}}) == :none

    assert PermissionGate.coding_tier(Map.put(trusted_context, :channel_originated?, true)) ==
             :none

    assert PermissionGate.approval_mode(%{coding: %{approval_mode: "bogus"}}) == :default
  end

  test "requires confirmation for external network access" do
    decision = PermissionGate.authorize(:external_network, %{})

    assert decision.permission == :external_network
    assert decision.decision == :needs_confirmation
    assert decision.requires_confirmation
    refute PermissionGate.allowed?(decision)
    assert PermissionGate.response_status(decision) == :needs_confirmation
    assert_compatibility_fields(decision)
  end

  test "denies skill script execution until explicitly enabled" do
    decision = PermissionGate.authorize(:skill_script_execute, %{})

    assert decision.permission == :skill_script_execute
    assert decision.decision == :denied
    refute decision.requires_confirmation
    refute PermissionGate.allowed?(decision)
    assert PermissionGate.response_status(decision) == :denied
    assert_compatibility_fields(decision)
  end

  test "denies new v0.10 high-risk boundaries until explicitly enabled" do
    for permission <- [:package_install, :online_skill_import] do
      decision = PermissionGate.authorize(permission, %{})

      assert decision.permission == permission
      assert decision.decision == :denied
      refute decision.requires_confirmation
      refute PermissionGate.allowed?(decision)
      assert PermissionGate.response_status(decision) == :denied
      assert_compatibility_fields(decision)
    end
  end

  test "allows safe settings writes, skill scaffolds, dynamic draft requests, confirmation decisions, and explicit secret writes" do
    for permission <- [
          :settings_write,
          :skill_write,
          :dynamic_codegen_request,
          :dynamic_codegen_discard,
          :confirmation_decide,
          :settings_secret_write
        ] do
      decision = PermissionGate.authorize(permission, %{})

      assert decision.permission == permission
      assert decision.decision == :allowed
      assert PermissionGate.allowed?(decision)
      assert_compatibility_fields(decision)
    end
  end

  test "denies raw user-facing secret reads" do
    decision = PermissionGate.authorize(:settings_secret_read, %{})

    assert decision.permission == :settings_secret_read
    assert decision.decision == :denied
    refute PermissionGate.allowed?(decision)
    assert_compatibility_fields(decision)
  end

  test "denies unknown permission classes with compatibility fields" do
    decision = PermissionGate.authorize(:unknown_future_permission, %{request: %{channel: :test}})

    assert decision.permission == :unknown_future_permission
    assert decision.decision == :denied
    refute decision.requires_confirmation
    refute PermissionGate.allowed?(decision)
    assert PermissionGate.response_status(decision) == :denied
    assert decision.reason =~ "Unknown permission class"
    assert_compatibility_fields(decision)
  end

  test "delegates to Security Central and preserves widened decision metadata" do
    decision =
      PermissionGate.authorize(:external_network, %{
        request: %{operator_id: "local", channel: :test, input_signal_id: "sig"},
        selected_action: "external_network_request"
      })

    assert decision.source == PermissionGate
    assert decision.risk.tier == :high
    assert decision.policy.effective == :needs_confirmation
    assert decision.trace.risk_tier == :high
    assert decision.audit.event == "security.decision"
    assert decision.context.actor.id == "local"
    assert decision.trust_boundary.action_registered?
  end

  defp assert_compatibility_fields(decision) do
    for field <- [:permission, :decision, :reason, :requires_confirmation, :source] do
      assert Map.has_key?(decision, field)
    end

    assert is_binary(decision.reason)
    assert is_boolean(decision.requires_confirmation)
    assert is_atom(decision.source)
  end
end
