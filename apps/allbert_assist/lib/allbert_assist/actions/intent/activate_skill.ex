defmodule AllbertAssist.Actions.Intent.ActivateSkill do
  @moduledoc """
  Activates one trusted skill for v0.03 progressive disclosure.
  """

  use AllbertAssist.Action,
    permission: :read_only,
    exposure: :agent,
    execution_mode: :read_only,
    skill_backed?: false,
    confirmation: :not_required,
    notes: "Progressive disclosure only; does not run the activated skill.",
    name: "activate_skill",
    description:
      "Load trusted skill instructions and resource inventory without executing resources.",
    category: "intent",
    tags: ["intent", "skills", "read_only"],
    schema: [
      name: [type: :string, required: true, doc: "Skill name, title, or alias."]
    ],
    output_schema: [
      message: [type: :string, required: true],
      status: [type: :atom, required: true],
      permission_decision: [type: :map, required: true],
      activation: [type: :map, required: false],
      actions: [type: {:list, :map}, required: true]
    ]

  alias AllbertAssist.Security.PermissionGate
  alias AllbertAssist.Skills

  @impl true
  def run(%{name: name}, context) do
    permission_decision = PermissionGate.authorize(:read_only, context)

    case Skills.activate(name, context) do
      {:ok, activation} ->
        activation = Map.put(activation, :permission_decision, permission_decision)

        {:ok,
         %{
           message: activation.instructions,
           status: PermissionGate.response_status(permission_decision),
           permission_decision: permission_decision,
           activation: activation,
           actions: [
             %{
               name: "activate_skill",
               status: :completed,
               permission: :read_only,
               permission_decision: permission_decision,
               input: %{name: name},
               selected_skill: activation.name,
               skill_metadata: skill_metadata(activation)
             }
           ]
         }}

      {:error, :not_found} ->
        {:ok, not_found_response(name, permission_decision)}
    end
  end

  defp not_found_response(name, permission_decision) do
    %{
      message: "I do not have a trusted enabled skill named #{inspect(name)} to activate.",
      status: :not_found,
      permission_decision: permission_decision,
      actions: [
        %{
          name: "activate_skill",
          status: :not_found,
          permission: :read_only,
          permission_decision: permission_decision,
          input: %{name: name},
          skill_metadata: %{selected_skill: name, status: :not_found}
        }
      ]
    }
  end

  defp skill_metadata(activation) do
    %{
      selected_skill: activation.name,
      source_scope: activation.source_scope,
      source_path: activation.source_path,
      trust_status: activation.trust_status,
      kind: activation.kind,
      activation_mode: activation.activation_mode,
      diagnostics: activation.diagnostics,
      resource_inventory: resource_summary(activation.resource_inventory),
      capability_contract: activation.capability_contract
    }
  end

  defp resource_summary(resources) do
    %{
      count: length(resources),
      paths: Enum.map(resources, & &1.path),
      kinds: resources |> Enum.map(& &1.kind) |> Enum.uniq()
    }
  end
end
