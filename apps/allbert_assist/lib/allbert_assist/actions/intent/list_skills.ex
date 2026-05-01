defmodule AllbertAssist.Actions.Intent.ListSkills do
  @moduledoc """
  Lists the static v0.01 skill declarations.
  """

  use Jido.Action,
    name: "list_skills",
    description: "List the v0.01-safe capabilities available to the intent agent.",
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
    skills = Skills.list()
    permission_decision = PermissionGate.authorize(:read_only, context)

    {:ok,
     %{
       message: message(skills),
       status: PermissionGate.response_status(permission_decision),
       permission_decision: permission_decision,
       skills: skills,
       actions: [
         %{
           name: "list_skills",
           status: :completed,
           permission: :read_only,
           permission_decision: permission_decision
         }
       ]
     }}
  end

  defp message(skills) do
    skill_lines =
      skills
      |> Enum.map(fn skill ->
        "- #{skill.name}: #{skill.description} (#{skill.status}, #{skill.permission})"
      end)
      |> Enum.join("\n")

    """
    Right now I can use these v0.01-safe capabilities:

    #{skill_lines}

    I cannot execute shell commands, call external services, or persist durable memory in M3.
    """
    |> String.trim()
  end
end
