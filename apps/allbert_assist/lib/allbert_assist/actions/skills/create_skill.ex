defmodule AllbertAssist.Actions.Skills.CreateSkill do
  @moduledoc """
  Create a local standard `SKILL.md` wrapper for an existing registered action.
  """

  use AllbertAssist.Action,
    permission: :skill_write,
    exposure: :agent,
    execution_mode: :skill_write,
    skill_backed?: false,
    confirmation: :required,
    resumable?: true,
    notes: "Operator helper; writes standard SKILL.md scaffolds only.",
    name: "create_skill",
    description: "Create a local Agent Skill wrapper for a registered Allbert action.",
    category: "skills",
    tags: ["skills", "scaffold", "skill_write"],
    schema: [
      name: [type: :string, required: true, doc: "Skill name to create."],
      action: [type: :string, required: true, doc: "Registered Allbert action name."],
      permission: [type: :string, required: true, doc: "Known Security Central permission class."],
      description: [type: :string, required: false, doc: "Skill description."],
      root: [type: :string, required: false, doc: "Parent directory for the skill folder."],
      overwrite: [
        type: :boolean,
        required: false,
        default: false,
        doc: "Replace an existing SKILL.md."
      ]
    ],
    output_schema: [
      message: [type: :string, required: true],
      status: [type: :atom, required: true],
      permission_decision: [type: :map, required: true],
      skill: [type: :map, required: false],
      actions: [type: {:list, :map}, required: true]
    ]

  alias AllbertAssist.Security.PermissionGate
  alias AllbertAssist.Skills.LocalHelper

  @impl true
  def run(params, context) do
    permission_decision = PermissionGate.authorize(:skill_write, context)

    if PermissionGate.allowed?(permission_decision) do
      create(params, permission_decision)
    else
      {:ok, denied_response(params, permission_decision)}
    end
  end

  defp create(params, permission_decision) do
    case LocalHelper.create_skill(params) do
      {:ok, skill} ->
        {:ok,
         %{
           message: "Created local skill #{skill.validation.name} at #{skill.skill_md_path}.",
           status: :completed,
           permission_decision: permission_decision,
           skill: skill,
           actions: [
             %{
               name: "create_skill",
               status: :completed,
               permission: :skill_write,
               permission_decision: permission_decision,
               skill_metadata: %{selected_skill: skill.validation.name, status: :created},
               path: skill.skill_md_path
             }
           ]
         }}

      {:error, reason} ->
        {:ok, error_response(params, permission_decision, reason)}
    end
  end

  defp denied_response(params, permission_decision) do
    %{
      message: "Local skill creation is not allowed by current policy.",
      status: PermissionGate.response_status(permission_decision),
      permission_decision: permission_decision,
      actions: [
        %{
          name: "create_skill",
          status: PermissionGate.response_status(permission_decision),
          permission: :skill_write,
          permission_decision: permission_decision,
          input: safe_input(params)
        }
      ]
    }
  end

  defp error_response(params, permission_decision, reason) do
    %{
      message: "Could not create local skill: #{inspect(reason)}",
      status: :error,
      error: reason,
      permission_decision: permission_decision,
      actions: [
        %{
          name: "create_skill",
          status: :error,
          permission: :skill_write,
          permission_decision: permission_decision,
          input: safe_input(params),
          error: inspect(reason)
        }
      ]
    }
  end

  defp safe_input(params), do: Map.take(params, [:name, :action, :permission, :root, :overwrite])
end
