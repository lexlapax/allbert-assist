defmodule AllbertAssist.ActionLegacyOutputSchemaTest do
  use ExUnit.Case, async: true
  @moduletag :global_process_serial

  alias AllbertAssist.DevGates.V14M0RegistryLedger

  # This row sweeps the thirty shipped actions converted to the legacy standard
  # output schema. Its subject is that roster, which is residual content, so it
  # stays here rather than following the Action DSL into the kernel.

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

  @legacy_standard_response_schema [
    message: [type: :string, required: true],
    status: [type: :atom, required: true],
    permission_decision: [type: :map, required: true],
    actions: [type: {:list, :map}, required: true]
  ]
  @legacy_standard_response_digest "bc9909868f01ff438ae01305dd57bb89df7ac83baaf7283bab5a17f5b3d6e9e4"

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

  test "legacy standard output-schema option preserves the frozen four-key schema and digest" do
    assert LegacyStandardResponseAction.output_schema() == @legacy_standard_response_schema

    assert V14M0RegistryLedger.digest(LegacyStandardResponseAction.output_schema()) ==
             @legacy_standard_response_digest

    assert length(@converted_legacy_standard_actions) == 30

    for module <- @converted_legacy_standard_actions do
      assert module.output_schema() == @legacy_standard_response_schema

      assert V14M0RegistryLedger.digest(module.output_schema()) ==
               @legacy_standard_response_digest
    end
  end
end
