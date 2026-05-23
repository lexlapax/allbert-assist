defmodule AllbertAssist.Actions.Intent.ReadSkill do
  @moduledoc """
  Reads one static v0.01 skill declaration.
  """

  use AllbertAssist.Action,
    permission: :read_only,
    exposure: :agent,
    execution_mode: :read_only,
    skill_backed?: true,
    confirmation: :not_required,
    name: "read_skill",
    description: "Read one v0.01 skill declaration by name.",
    category: "intent",
    tags: ["intent", "skills", "read_only"],
    schema: [
      name: [type: :string, required: true, doc: "Skill name or title."]
    ],
    output_schema: [
      message: [type: :string, required: true],
      status: [type: :atom, required: true],
      permission_decision: [type: :map, required: true],
      actions: [type: {:list, :map}, required: true]
    ]

  alias AllbertAssist.Security.PermissionGate
  alias AllbertAssist.Skills

  @impl true
  def run(%{name: name}, context) do
    permission_decision = PermissionGate.authorize(:read_only, context)

    case Skills.read(name, context) do
      {:ok, skill_read} ->
        {:ok,
         %{
           message: skill_message(skill_read),
           status: PermissionGate.response_status(permission_decision),
           permission_decision: permission_decision,
           actions: [
             %{
               name: "read_skill",
               status: :completed,
               permission: :read_only,
               permission_decision: permission_decision,
               input: %{name: name},
               skill_metadata: skill_metadata(skill_read.skill)
             }
           ]
         }}

      {:error, :not_found} ->
        {:ok,
         %{
           message: "I do not have a trusted enabled skill declaration named #{inspect(name)}.",
           status: PermissionGate.response_status(permission_decision),
           permission_decision: permission_decision,
           actions: [
             %{
               name: "read_skill",
               status: :not_found,
               permission: :read_only,
               permission_decision: permission_decision,
               input: %{name: name}
             }
           ]
         }}
    end
  end

  defp skill_message(%{skill: skill, body: body, diagnostics: diagnostics}) do
    """
    Skill: #{skill.title}
    Name: #{skill.name}
    Kind: #{skill.kind}
    Source: #{skill.source_scope}
    Trust: #{skill.trust_status}
    Activation: #{skill.activation_mode}
    Status: #{skill.status || :available}
    Permission: #{skill.permission || :read_only}
    Capability actions: #{contract_actions(skill)}
    Capability permissions: #{contract_permissions(skill)}
    Contract validation: #{contract_validation_status(skill)}
    Execution eligible: #{contract_execution_eligible?(skill)}

    #{skill.description}

    ## Instructions

    #{body}

    Diagnostics: #{diagnostics_summary(diagnostics)}
    """
    |> String.trim()
  end

  defp skill_metadata(skill) do
    %{
      selected_skill: skill.name,
      source_scope: skill.source_scope,
      source_path: skill.source_path,
      trust_status: skill.trust_status,
      kind: skill.kind,
      activation_mode: skill.activation_mode,
      capability_contract: contract_summary(skill)
    }
  end

  defp diagnostics_summary([]), do: "none"
  defp diagnostics_summary(diagnostics), do: inspect(diagnostics, pretty: true)

  defp contract_actions(%{capability_contract: %{actions: actions}}), do: Enum.join(actions, ", ")
  defp contract_actions(_skill), do: "none"

  defp contract_permissions(%{capability_contract: %{permissions: permissions}}),
    do: Enum.join(permissions, ", ")

  defp contract_permissions(_skill), do: "none"

  defp contract_validation_status(%{contract_validation: %{status: status}}), do: status
  defp contract_validation_status(_skill), do: :none

  defp contract_execution_eligible?(%{contract_validation: validation}) when is_map(validation),
    do: Map.get(validation, :execution_eligible?, false)

  defp contract_execution_eligible?(_skill), do: false

  defp contract_summary(skill) do
    validation = skill.contract_validation || %{}

    %{
      status: Map.get(skill.capability_contract || %{}, :status, :none),
      actions: Map.get(skill.capability_contract || %{}, :actions, []),
      permissions: Map.get(skill.capability_contract || %{}, :permissions, []),
      validation_status: Map.get(validation, :status, :none),
      execution_eligible?: Map.get(validation, :execution_eligible?, false),
      diagnostics: Map.get(validation, :diagnostics, [])
    }
  end
end
