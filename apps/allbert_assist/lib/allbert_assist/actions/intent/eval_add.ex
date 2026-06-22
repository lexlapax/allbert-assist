defmodule AllbertAssist.Actions.Intent.EvalAdd do
  @moduledoc false

  use AllbertAssist.Action,
    permission: :settings_write,
    exposure: :internal,
    execution_mode: :intent_eval_write,
    skill_backed?: false,
    confirmation: :not_required,
    name: "intent_eval_add",
    description: "Promote a reviewed captured eval candidate into the committed fixture.",
    category: "intent",
    tags: ["intent", "eval", "operator", "write"],
    schema: [
      id: [type: :string, required: false],
      path: [type: :string, required: false],
      fixture_root: [type: :string, required: false],
      force: [type: :boolean, required: false]
    ],
    output_schema: [
      message: [type: :string, required: true],
      status: [type: :atom, required: true],
      permission_decision: [type: :map, required: true],
      eval_case: [type: :map, required: false],
      actions: [type: {:list, :map}, required: true]
    ]

  alias AllbertAssist.Actions.Intent.MutationSupport

  @impl true
  def run(params, context) do
    MutationSupport.write_action(name(), context, fn permission_decision ->
      with {:ok, result} <- MutationSupport.add_capture(params) do
        MutationSupport.finish(name(), result, permission_decision, %{
          path: Map.get(result, :path),
          source_path: Map.get(result, :source_path),
          error: Map.get(result, :error)
        })
      end
    end)
  end
end
