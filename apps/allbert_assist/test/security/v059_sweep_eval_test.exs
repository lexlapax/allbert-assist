defmodule AllbertAssist.Security.V059SweepEvalTest do
  @moduledoc """
  v0.59 hardening sweep across already-shipped surfaces.

  These evals are intentionally contract-level. They prove that each surface still
  routes through Registry, Settings Central, Security Central, or the public
  exposure filter without performing live provider or network work.
  """
  use AllbertAssist.SecurityEvalCase, async: true

  alias AllbertAssist.Actions.Registry
  alias AllbertAssist.Channels.Identity, as: ChannelIdentity
  alias AllbertAssist.PublicProtocol.ExposureFilter
  alias AllbertAssist.Security.PermissionGate
  alias AllbertAssist.Security.Policy
  alias AllbertAssist.SecurityFixtures.EvalInventory
  alias AllbertAssist.Settings
  alias AllbertAssist.Settings.Schema

  @eval_groups [
    mcp_client_browser: ~w(v1-eval-sweep-mcp-client-browser-001),
    channels: ~w(v1-eval-sweep-channels-001),
    plan_build: ~w(v1-eval-sweep-plan-build-001),
    marketplace: ~w(v1-eval-sweep-marketplace-001),
    self_improvement: ~w(v1-eval-sweep-self-improvement-001),
    voice_vision: ~w(v1-eval-sweep-voice-vision-001),
    public_protocol: ~w(v1-eval-sweep-public-protocol-001),
    rc_substrate: ~w(rc-substrate-no-drift-001)
  ]
  @eval_ids @eval_groups |> Keyword.values() |> List.flatten()
  @rc_handoff_path Path.expand("../../../../docs/plans/v0.59-rc-handoff.md", __DIR__)

  test "v0.59 eval inventory rows are complete and grouped by protected surface" do
    rows = EvalInventory.rows_for_milestone(:v059)
    row_ids = Enum.map(rows, & &1.id)

    assert MapSet.new(row_ids) == MapSet.new(@eval_ids)
    assert length(row_ids) == length(@eval_ids)
    assert Enum.all?(rows, &(&1.milestone == :v059))
    assert Enum.all?(rows, &(&1.test_module == inspect(__MODULE__)))

    assert_eval_group!(:mcp_client_browser, :mcp_client_browser)
    assert_eval_group!(:channels, :channel_pack)
    assert_eval_group!(:plan_build, :plan_build)
    assert_eval_group!(:marketplace, :marketplace)
    assert_eval_group!(:self_improvement, :self_improvement)
    assert_eval_group!(:voice_vision, :voice_vision)
    assert_eval_group!(:public_protocol, :public_protocol)
    assert_eval_group!(:rc_substrate, :rc_substrate)
  end

  test "v0.59 sweep rows encode concrete pass criteria" do
    rows = EvalInventory.rows_for_milestone(:v059)

    assert Enum.any?(rows, &(&1.expected == :needs_confirmation))
    assert Enum.any?(rows, &(&1.expected == :denied))

    for row <- rows do
      assert is_atom(row.boundary)
      assert is_list(row.assert)
      assert length(row.assert) >= 3
      assert row.scenario =~ ~r/\w/
    end
  end

  test "mcp client and browser egress remain bounded by settings and confirmation floors" do
    defaults = Settings.defaults()

    refute Schema.get_dotted(defaults, "external_services.enabled")
    assert Schema.get_dotted(defaults, "external_services.allowed_hosts") == []
    assert Schema.get_dotted(defaults, "external_services.blocked_hosts") == []
    assert Schema.get_dotted(defaults, "external_services.allow_redirects") == false
    assert Schema.get_dotted(defaults, "external_services.max_redirects") == 0
    assert Schema.get_dotted(defaults, "mcp.discovery.enabled") == false
    assert Schema.get_dotted(defaults, "mcp.discovery.auto_connect") == false
    assert Schema.get_dotted(defaults, "mcp.stdio.allowed_launchers") == []

    assert_capability!("find_mcp_tools",
      exposure: :agent,
      permission: :tool_discovery,
      confirmation: :not_required
    )

    assert_capability!("mcp_server_connect",
      exposure: :internal,
      permission: :mcp_server_connect,
      confirmation: :required,
      resumable?: true
    )

    assert_capability!("mcp_call_tool",
      exposure: :internal,
      permission: :mcp_tool_call,
      confirmation: :required,
      resumable?: true
    )

    assert PermissionGate.authorize(:mcp_server_connect, %{}).decision == :needs_confirmation
    assert PermissionGate.authorize(:mcp_tool_call, %{}).decision == :needs_confirmation

    assert Policy.safety_floor(:browser_session_start) == :needs_confirmation
    assert Policy.safety_floor(:browser_navigate) == :needs_confirmation
    assert Policy.safety_floor(:browser_interact) == :needs_confirmation
    assert Policy.safety_floor(:browser_form_fill) == :needs_confirmation
    assert Policy.safety_floor(:browser_download) == :needs_confirmation
    assert Schema.get_dotted(defaults, "permissions.browser_form_fill") == "denied"
    assert Schema.get_dotted(defaults, "permissions.browser_download") == "denied"
  end

  test "channel outbound remains identity-gated and confirmation-gated" do
    assert_capability!("list_channels",
      exposure: :agent,
      permission: :read_only,
      confirmation: :not_required
    )

    assert_capability!("send_channel_message",
      exposure: :agent,
      permission: :channel_message_send,
      confirmation: :required,
      resumable?: true
    )

    assert PermissionGate.authorize(:channel_message_send, %{}).decision == :needs_confirmation
    assert PermissionGate.authorize(:channel_message_inbound, %{}).decision == :needs_confirmation
    assert ChannelIdentity.resolve("slack", "U123", []) == {:error, :not_mapped}

    assert public_exposable?("send_channel_message")

    assert {:ok, [capability]} =
             ExposureFilter.filter_tools(["send_channel_message"])

    assert capability.name == "send_channel_message"
    assert capability.confirmation == :required
  end

  test "plan build keeps previews advisory and run/step execution internal" do
    assert_capability!("preview_plan",
      exposure: :agent,
      permission: :read_only,
      confirmation: :not_required
    )

    assert_capability!("start_plan_run",
      exposure: :internal,
      permission: :workflow_run_start,
      confirmation: :required,
      resumable?: true
    )

    assert_capability!("plan_step_confirm",
      exposure: :internal,
      permission: :objective_write,
      confirmation: :not_required,
      resumable?: true
    )

    assert Policy.safety_floor(:workflow_run_start) == :needs_confirmation
    assert PermissionGate.authorize(:workflow_run_start, %{}).decision == :needs_confirmation

    refute public_exposable?("start_plan_run")
    refute public_exposable?("plan_step_confirm")
  end

  test "marketplace install remains gated and rollback is internal-only" do
    assert_capability!("list_marketplace_entries",
      exposure: :agent,
      permission: :read_only,
      confirmation: :not_required
    )

    assert_capability!("install_marketplace_bundle",
      exposure: :agent,
      permission: :marketplace_install,
      confirmation: :required,
      resumable?: true
    )

    assert_capability!("rollback_marketplace_install",
      exposure: :internal,
      permission: :marketplace_install,
      confirmation: :not_required,
      resumable?: true
    )

    assert Settings.get("marketplace.enabled") == {:ok, true}

    assert Schema.get_dotted(Settings.defaults(), "marketplace.install.default_state") ==
             "disabled_untrusted"

    assert public_exposable?("install_marketplace_bundle")
    refute public_exposable?("rollback_marketplace_install")

    assert {:ok, [install]} = ExposureFilter.filter_tools(["install_marketplace_bundle"])
    assert install.name == "install_marketplace_bundle"
    assert install.confirmation == :required

    assert {:error, {:non_exposable_tools, [%{name: "rollback_marketplace_install"} = rejected]}} =
             ExposureFilter.filter_tools(["rollback_marketplace_install"])

    assert rejected.reason == :not_agent_exposable
  end

  test "self-improvement suggestions stay inert and mutations are internal-only" do
    assert_capability!("discover_patterns",
      exposure: :internal,
      permission: :read_only,
      confirmation: :not_required
    )

    assert_capability!("create_self_improvement_draft",
      exposure: :internal,
      permission: :dynamic_codegen_request,
      confirmation: :not_required
    )

    for action <- [
          "promote_skill_draft",
          "promote_workflow_draft",
          "promote_memory_draft",
          "promote_template_draft",
          "promote_objective_draft",
          "promote_capability_gap_draft"
        ] do
      assert_capability!(action, exposure: :internal)
      refute public_exposable?(action)
    end

    refute public_exposable?("discover_patterns")
    refute public_exposable?("create_self_improvement_draft")
    assert Policy.safety_floor(:dynamic_codegen_request) == :allowed
  end

  test "voice, vision, and image capture are off by default with bounded retention" do
    defaults = Settings.defaults()

    refute Schema.get_dotted(defaults, "voice.enabled")
    refute Schema.get_dotted(defaults, "voice.local_runtime.enabled")
    refute Schema.get_dotted(defaults, "voice.audio.retention_enabled")
    refute Schema.get_dotted(defaults, "vision.enabled")
    refute Schema.get_dotted(defaults, "vision.media.retention_enabled")
    refute Schema.get_dotted(defaults, "image.enabled")
    refute Schema.get_dotted(defaults, "image.generation.retention_enabled")

    assert_capability!("capture_workspace_voice",
      exposure: :internal,
      permission: :microphone_capture,
      confirmation: :required,
      resumable?: true
    )

    assert_capability!("transcribe_voice",
      exposure: :internal,
      permission: :voice_transcribe,
      confirmation: :required,
      resumable?: true
    )

    assert_capability!("synthesize_voice",
      exposure: :agent,
      permission: :voice_synthesize,
      confirmation: :required,
      resumable?: true
    )

    assert Policy.safety_floor(:microphone_capture) == :needs_confirmation
    assert PermissionGate.authorize(:microphone_capture, %{}).decision == :needs_confirmation
    refute public_exposable?("capture_workspace_voice")
    refute public_exposable?("transcribe_voice")
  end

  test "public protocol exposure excludes internal reads and secret-bearing tools" do
    refute public_exposable?("settings_doctor")
    refute public_exposable?("security_status")
    refute public_exposable?("surface_policy_read")
    refute public_exposable?("set_provider_credential")
    assert public_exposable?("get_public_call_result")

    assert {:error, {:non_exposable_tools, rejected}} =
             ExposureFilter.filter_tools([
               "settings_doctor",
               "security_status",
               "surface_policy_read",
               "set_provider_credential"
             ])

    rejected_by_name = Map.new(rejected, &{&1.name, &1.reason})
    assert rejected_by_name["settings_doctor"] == :not_agent_exposable
    assert rejected_by_name["security_status"] == :not_agent_exposable
    assert rejected_by_name["surface_policy_read"] == :not_agent_exposable
    assert rejected_by_name["set_provider_credential"] == {:blocked_execution_mode, :secret_write}

    assert {:ok, [readback]} = ExposureFilter.filter_tools(["get_public_call_result"])
    assert readback.name == "get_public_call_result"
    assert readback.permission == :read_only
    assert readback.confirmation == :not_required
  end

  @tag :rc_substrate
  test "rc-substrate handoff enumerates downstream consumers without scope drift" do
    row = EvalInventory.row!("rc-substrate-no-drift-001")
    handoff = File.read!(@rc_handoff_path)

    assert row.surface == :rc_substrate
    assert row.boundary == :release_handoff_contract
    assert row.expected == :allowed

    for needle <- [
          "v0.61 Packaged-Install Home Layout",
          "v0.63 Product RC Revalidation",
          "v1.0 Contract Freeze",
          "Allbert Home export envelope",
          "dry-run import diagnostic",
          "first-class Settings fragment `schema_version`",
          "secret references",
          "Settings Central secret-vault references",
          "packaged-layout portability revalidation",
          "`release.v059` evidence",
          "ADR 0046 settings version contract",
          "ADR 0065 central Runner param seam",
          "Registry action schema",
          "`:invalid_params` shape"
        ] do
      assert handoff =~ needle
    end

    refute handoff =~ "TODO"
    refute handoff =~ "TBD"
    refute handoff =~ "named target"
    refute handoff =~ "v0.59 owns packaging"
    refute handoff =~ "v0.59 owns onboarding"
    refute handoff =~ "v0.59 owns product RC"

    IO.puts(
      "rc-substrate-no-drift-001 consumer=v0.61 " <>
        "output=export-import+settings-version-contract+secret-references status=no-drift"
    )

    IO.puts(
      "rc-substrate-no-drift-001 consumer=v0.63 " <>
        "output=packaged-layout-portability-revalidation+release-v059-evidence status=no-drift"
    )

    IO.puts(
      "rc-substrate-no-drift-001 consumer=v1.0 " <>
        "output=adr0046-settings-version-contract+adr0065-param-seam+invalid-params-shape status=no-drift"
    )

    IO.puts("rc-substrate-no-drift-001 no-drift consumers=v0.61,v0.63,v1.0")
  end

  defp assert_eval_group!(group, surface) do
    ids = Keyword.fetch!(@eval_groups, group)
    milestone_rows = EvalInventory.rows_for_milestone(:v059)
    rows = Enum.map(ids, &find_eval_row!(milestone_rows, &1))

    assert Enum.map(rows, & &1.id) == ids
    assert Enum.all?(rows, &(&1.surface == surface))
  end

  defp find_eval_row!(rows, id) do
    Enum.find(rows, &(&1.id == id)) || flunk("missing v0.59 eval row #{id}")
  end

  defp assert_capability!(name, expected) do
    assert {:ok, capability} = Registry.capability(name)

    for {key, value} <- expected do
      assert Map.fetch!(capability, key) == value
    end

    capability
  end

  defp public_exposable?(name) do
    with {:ok, capability} <- Registry.capability(name) do
      ExposureFilter.exposable_tool?(capability)
    end
  end
end
