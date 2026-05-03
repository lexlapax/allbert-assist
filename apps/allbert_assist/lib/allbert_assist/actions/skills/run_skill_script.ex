defmodule AllbertAssist.Actions.Skills.RunSkillScript do
  @moduledoc """
  v0.09 skill script execution boundary.

  M1 registers the action and permission vocabulary without executing scripts.
  Later milestones add resource-gated spec resolution, confirmation, and the
  bounded runner behind this same action name.
  """

  use Jido.Action,
    name: "run_skill_script",
    description: "Run a confirmed trusted Agent Skill script resource.",
    category: "skills",
    tags: ["skills", "scripts", "skill_script_execute", "confirmation_required"],
    schema: [
      skill_name: [type: :string, required: true, doc: "Trusted selected skill name."],
      script_path: [type: :string, required: true, doc: "Inventoried script resource path."],
      args: [type: {:list, :string}, required: false, doc: "Explicit script argv list."],
      cwd: [type: :string, required: false, doc: "Working directory inside an allowed root."],
      timeout_ms: [type: :integer, required: false, doc: "Requested timeout in milliseconds."],
      max_output_bytes: [type: :integer, required: false, doc: "Requested output cap."],
      source_text: [type: :string, required: false, doc: "Original operator prompt."]
    ],
    output_schema: [
      message: [type: :string, required: true],
      status: [type: :atom, required: true],
      permission_decision: [type: :map, required: true],
      actions: [type: {:list, :map}, required: true]
    ]

  alias AllbertAssist.Security.PermissionGate

  @impl true
  def run(params, context) when is_map(params) do
    permission_decision = PermissionGate.authorize(:skill_script_execute, context)
    status = PermissionGate.response_status(permission_decision)

    {:ok,
     %{
       message:
         "Skill script execution policy is registered; resource-gated execution lands in later v0.09 milestones.",
       status: status,
       permission_decision: permission_decision,
       actions: [
         %{
           name: "run_skill_script",
           status: status,
           permission: :skill_script_execute,
           permission_decision: permission_decision,
           execution: :not_started,
           input: safe_input(params),
           diagnostics: [:v0_09_runner_not_implemented]
         }
       ]
     }}
  end

  defp safe_input(params) do
    Map.take(params, [:skill_name, :script_path, :args, :cwd, :timeout_ms, :max_output_bytes])
  end
end
