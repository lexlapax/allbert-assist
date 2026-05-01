defmodule AllbertAssist.Actions.Intent.ReadSkill do
  @moduledoc """
  Reads one static v0.01 skill declaration.
  """

  use Jido.Action,
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

    case Skills.get(name) do
      {:ok, skill} ->
        {:ok,
         %{
           message: skill_message(skill),
           status: PermissionGate.response_status(permission_decision),
           permission_decision: permission_decision,
           actions: [
             %{
               name: "read_skill",
               status: :completed,
               permission: :read_only,
               permission_decision: permission_decision,
               input: %{name: name}
             }
           ]
         }}

      {:error, :not_found} ->
        {:ok,
         %{
           message: "I do not have a v0.01 skill declaration named #{inspect(name)}.",
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

  defp skill_message(skill) do
    """
    Skill: #{skill.title}
    Name: #{skill.name}
    Status: #{skill.status}
    Permission: #{skill.permission}

    #{skill.description}
    """
    |> String.trim()
  end
end
