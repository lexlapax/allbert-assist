defmodule AllbertAssist.Actions.Intent.PromoteDescriptor do
  @moduledoc false

  use AllbertAssist.Action,
    permission: :settings_write,
    exposure: :internal,
    execution_mode: :intent_descriptor_write,
    skill_backed?: false,
    confirmation: :not_required,
    name: "promote_intent_descriptor",
    description: "Promote a reviewed intent descriptor only after the routing gate passes.",
    category: "intent",
    tags: ["intent", "descriptor", "operator", "write"],
    schema: [
      action: [type: :string, required: true],
      from: [type: :string, required: false],
      to: [type: :string, required: false]
    ],
    output_schema: [
      message: [type: :string, required: true],
      status: [type: :atom, required: true],
      permission_decision: [type: :map, required: true],
      descriptor: [type: :map, required: false],
      actions: [type: {:list, :map}, required: true]
    ]

  alias AllbertAssist.Actions.Intent.MutationSupport

  @impl true
  def run(%{action: action} = params, context) do
    MutationSupport.write_action(name(), context, fn permission_decision ->
      with {:ok, result} <- MutationSupport.promote(action, params) do
        MutationSupport.finish(name(), result, permission_decision, %{
          descriptor: Map.get(result, :descriptor),
          error: Map.get(result, :error)
        })
      end
    end)
  end

  def run(_params, context) do
    MutationSupport.write_action(name(), context, fn permission_decision ->
      MutationSupport.finish(
        name(),
        %{message: "could not promote intent descriptor: :missing_action", status: :rejected},
        permission_decision
      )
    end)
  end
end
