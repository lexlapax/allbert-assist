defmodule AllbertAssist.Actions.Skills.ValidateSkill do
  @moduledoc """
  Validate a local Agent Skill directory without trusting or executing it.
  """

  use AllbertAssist.Action,
    permission: :read_only,
    exposure: :internal,
    execution_mode: :skill_validation,
    skill_backed?: false,
    confirmation: :not_required,
    notes: "Operator helper; validates local skill folders without trusting or executing them.",
    name: "validate_skill",
    description: "Validate a local SKILL.md directory and Allbert action contract.",
    category: "skills",
    tags: ["skills", "validation", "read_only"],
    schema: [
      path: [type: :string, required: true, doc: "Local skill directory containing SKILL.md."]
    ],
    output_schema: [
      message: [type: :string, required: true],
      status: [type: :atom, required: true],
      permission_decision: [type: :map, required: true],
      validation: [type: :map, required: true],
      actions: [type: {:list, :map}, required: true]
    ]

  alias AllbertAssist.Security.PermissionGate
  alias AllbertAssist.Skills.LocalHelper

  @impl true
  def run(%{path: path}, context) do
    permission_decision = PermissionGate.authorize(:read_only, context)

    if PermissionGate.allowed?(permission_decision) do
      validation = LocalHelper.validate_dir(path)

      {:ok,
       %{
         message: message(validation),
         status: PermissionGate.response_status(permission_decision),
         permission_decision: permission_decision,
         validation: validation,
         actions: [
           %{
             name: "validate_skill",
             status: :completed,
             permission: :read_only,
             permission_decision: permission_decision,
             validation: validation
           }
         ]
       }}
    else
      {:ok,
       %{
         message: "Local skill validation is not allowed by current policy.",
         status: PermissionGate.response_status(permission_decision),
         permission_decision: permission_decision,
         validation: %{},
         actions: [
           %{
             name: "validate_skill",
             status: PermissionGate.response_status(permission_decision),
             permission: :read_only,
             permission_decision: permission_decision
           }
         ]
       }}
    end
  end

  defp message(validation) do
    """
    Skill validation #{validation.status}.

    Path: #{validation.path}
    Name: #{validation.name || "unknown"}
    Contract validation: #{validation.contract.validation_status}
    Execution eligible: #{validation.contract.execution_eligible?}
    Diagnostics: #{diagnostics_summary(validation.diagnostics)}
    """
    |> String.trim()
  end

  defp diagnostics_summary([]), do: "none"
  defp diagnostics_summary(diagnostics), do: inspect(diagnostics, pretty: true)
end
