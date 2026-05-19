defmodule AllbertAssist.Actions.Intent.ListSkills do
  @moduledoc """
  Lists registered skill declarations and read-only capability context.
  """

  use Jido.Action,
    name: "list_skills",
    description: "List the read-only capabilities available to the intent agent.",
    category: "intent",
    tags: ["intent", "skills", "read_only"],
    schema: [],
    output_schema: [
      message: [type: :string, required: true],
      status: [type: :atom, required: true],
      permission_decision: [type: :map, required: true],
      actions: [type: {:list, :map}, required: true],
      skills: [type: {:list, :map}, required: true]
    ]

  alias AllbertAssist.Security.PermissionGate
  alias AllbertAssist.Skills

  @impl true
  def run(_params, context) do
    permission_decision = PermissionGate.authorize(:read_only, context)

    with {:ok, skills} <- Skills.list(context) do
      {:ok,
       %{
         message: message(skills),
         status: PermissionGate.response_status(permission_decision),
         permission_decision: permission_decision,
         skills: Enum.map(skills, &skill_summary/1),
         actions: [
           %{
             name: "list_skills",
             status: :completed,
             permission: :read_only,
             permission_decision: permission_decision,
             skill_metadata: %{count: length(skills), source: :registry}
           }
         ]
       }}
    end
  end

  defp message(skills) do
    skill_lines =
      skills
      |> Enum.map(fn skill ->
        "- #{skill.name}: #{skill.description} (#{skill.kind}, #{skill.source_scope}, #{skill.trust_status})"
      end)
      |> Enum.join("\n")

    """
    Right now I can inspect these registry-backed skills and read-only capabilities:

    #{skill_lines}

    Skill activation and action-backed execution stay separate. I cannot execute shell commands, scripts, package installs, or external services from a skill declaration.
    """
    |> String.trim()
  end

  defp skill_summary(skill) do
    %{
      name: skill.name,
      title: skill.title,
      description: skill.description,
      kind: skill.kind,
      source_scope: skill.source_scope,
      trust_status: skill.trust_status,
      activation_mode: skill.activation_mode,
      aliases: skill.aliases,
      plugin_id: skill.plugin_id,
      status: skill.status,
      permission: skill.permission,
      capability_contract: contract_summary(skill)
    }
  end

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
