defmodule AllbertAssist.Security.PermissionGateTest do
  use ExUnit.Case, async: true
  @moduletag :external_runtime_serial

  alias AllbertAssist.Security.PermissionGate

  test "documents the runtime permission classes" do
    assert PermissionGate.permission_classes() == [
             :read_only,
             :memory_write,
             :command_plan,
             :command_execute,
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
             :tool_discovery,
             :mcp_server_connect,
             :mcp_tool_call,
             :mcp_resource_read,
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
             :marketplace_install,
             :settings_secret_write,
             :settings_secret_read
           ]
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

  test "denies command execution" do
    decision = PermissionGate.authorize(:command_execute, %{})

    assert decision.permission == :command_execute
    assert decision.decision == :denied
    refute decision.requires_confirmation
    refute PermissionGate.allowed?(decision)
    assert PermissionGate.response_status(decision) == :denied
    assert_compatibility_fields(decision)
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
