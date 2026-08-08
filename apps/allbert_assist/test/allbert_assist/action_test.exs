defmodule AllbertAssist.ActionTest do
  use ExUnit.Case, async: true
  @moduletag :external_runtime_serial

  alias AllbertAssist.Action

  @legacy_standard_response_schema [
    message: [type: :string, required: true],
    status: [type: :atom, required: true],
    permission_decision: [type: :map, required: true],
    actions: [type: {:list, :map}, required: true]
  ]
  @legacy_standard_response_digest "bc9909868f01ff438ae01305dd57bb89df7ac83baaf7283bab5a17f5b3d6e9e4"
  @converted_legacy_standard_actions [
    AllbertAssist.Actions.Coding.Bash,
    AllbertAssist.Actions.Coding.Edit,
    AllbertAssist.Actions.Coding.Glob,
    AllbertAssist.Actions.Coding.Grep,
    AllbertAssist.Actions.Coding.Read,
    AllbertAssist.Actions.Coding.Write,
    AllbertAssist.Actions.Conversations.PersistApprovalMediaResponse,
    AllbertAssist.Actions.Database.RestoreBackup,
    AllbertAssist.Actions.DynamicPlugins.DisableLiveLoader,
    AllbertAssist.Actions.FirstModel.InstallOllama,
    AllbertAssist.Actions.Intent.DirectAnswer,
    AllbertAssist.Actions.Intent.ExternalNetworkRequest,
    AllbertAssist.Actions.Intent.PlanShellCommand,
    AllbertAssist.Actions.Intent.ReadSkill,
    AllbertAssist.Actions.Intent.RunShellCommand,
    AllbertAssist.Actions.Intent.ShowDescriptor,
    AllbertAssist.Actions.Intent.UnsupportedResourceWorkflow,
    AllbertAssist.Actions.Jobs.PauseJob,
    AllbertAssist.Actions.Jobs.ResumeJob,
    AllbertAssist.Actions.Jobs.RunJob,
    AllbertAssist.Actions.Packages.PlanPackageInstall,
    AllbertAssist.Actions.Packages.RunPackageInstall,
    AllbertAssist.Actions.Sandbox.DiscardBundle,
    AllbertAssist.Actions.Serve.ServiceControl,
    AllbertAssist.Actions.Skills.AuditOnlineSkill,
    AllbertAssist.Actions.Skills.ImportLocalSkill,
    AllbertAssist.Actions.Skills.ImportOnlineSkill,
    AllbertAssist.Actions.Skills.ImportRemoteSkill,
    AllbertAssist.Actions.Skills.SearchOnlineSkills,
    AllbertAssist.Actions.Skills.ShowOnlineSkill
  ]

  defmodule DemoAction do
    use AllbertAssist.Action,
      registry_order: 777,
      permission: :read_only,
      exposure: :agent,
      execution_mode: :read_only,
      skill_backed?: false,
      confirmation: :not_required,
      name: "demo_allbert_action",
      description: "Demo Allbert action wrapper.",
      category: "test",
      schema: [text: [type: :string, required: true]]

    @impl true
    def run(%{text: text}, _context), do: {:ok, %{message: text, status: :completed}}
  end

  defmodule OverrideAction do
    use AllbertAssist.Action,
      permission: :read_only,
      exposure: :agent,
      execution_mode: :read_only,
      skill_backed?: false,
      confirmation: :not_required,
      name: "override_allbert_action",
      description: "Demo override action wrapper.",
      category: "test",
      schema: []

    def capability do
      %{
        permission: :memory_write,
        exposure: :internal,
        execution_mode: :memory_write,
        skill_backed?: false,
        confirmation: :required,
        resumable?: true
      }
    end

    @impl true
    def run(_params, _context), do: {:ok, %{message: "override", status: :completed}}
  end

  defmodule LegacyStandardResponseAction do
    use AllbertAssist.Action,
      permission: :read_only,
      exposure: :internal,
      execution_mode: :read_only,
      skill_backed?: false,
      confirmation: :not_required,
      name: "legacy_standard_response_action",
      description: "Exercises the frozen 1.x output-schema shorthand.",
      category: "test",
      schema: [],
      output_schema: :legacy_standard_response

    @impl true
    def run(_params, _context), do: {:ok, %{message: "done", status: :completed}}
  end

  test "wraps Jido.Action and pins Allbert capability metadata" do
    assert DemoAction.name() == "demo_allbert_action"
    assert Action.allbert_action?(DemoAction)
    assert DemoAction.registry_order() == 777

    assert DemoAction.capability() == %{
             permission: :read_only,
             exposure: :agent,
             execution_mode: :read_only,
             skill_backed?: false,
             confirmation: :not_required,
             resumable?: false,
             retry_safety: :unknown
           }
  end

  test "lets plugin-style modules override capability metadata explicitly" do
    assert Action.allbert_action?(OverrideAction)
    assert OverrideAction.registry_order() == nil
    assert OverrideAction.capability().permission == :memory_write
    assert OverrideAction.capability().confirmation == :required
    assert OverrideAction.capability().resumable?
  end

  test "provides overridable canonical response builders without changing capability metadata" do
    assert DemoAction.response_completed("done").status == :completed
    assert DemoAction.response_needs_confirmation("confirm").status == :needs_confirmation
    assert DemoAction.response_denied("no").status == :denied
    assert DemoAction.response_error("broken", :boom).error == :boom

    assert DemoAction.response_action(:completed, result: %{kept?: true}) == %{
             name: "demo_allbert_action",
             status: :completed,
             result: %{kept?: true}
           }

    assert DemoAction.response_schema() == AllbertAssist.Runtime.Response.action_response_schema()
  end

  test "legacy standard output-schema option preserves the frozen four-key schema and digest" do
    assert LegacyStandardResponseAction.output_schema() == @legacy_standard_response_schema

    assert AllbertAssist.DevGates.V14M0RegistryLedger.digest(
             LegacyStandardResponseAction.output_schema()
           ) == @legacy_standard_response_digest

    assert length(@converted_legacy_standard_actions) == 30

    for module <- @converted_legacy_standard_actions do
      assert module.output_schema() == @legacy_standard_response_schema

      assert AllbertAssist.DevGates.V14M0RegistryLedger.digest(module.output_schema()) ==
               @legacy_standard_response_digest
    end
  end

  test "validates required capability metadata" do
    assert {:error, {:missing_capability_keys, [:confirmation]}} =
             Action.validate_capability(
               permission: :read_only,
               exposure: :agent,
               execution_mode: :read_only,
               skill_backed?: false
             )
  end

  test "accepts MCP server connect capability metadata" do
    assert {:ok, capability} =
             Action.validate_capability(
               permission: :mcp_server_connect,
               exposure: :internal,
               execution_mode: :mcp_server_connect,
               skill_backed?: false,
               confirmation: :required
             )

    assert capability.permission == :mcp_server_connect
    assert capability.execution_mode == :mcp_server_connect
  end
end
