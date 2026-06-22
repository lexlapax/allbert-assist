defmodule AllbertAssist.Actions.Intent.EvalCapture do
  @moduledoc false

  use AllbertAssist.Action,
    permission: :settings_write,
    exposure: :internal,
    execution_mode: :intent_eval_write,
    skill_backed?: false,
    confirmation: :not_required,
    name: "intent_eval_capture",
    description: "Capture a redacted reviewed routing observation as an eval candidate.",
    category: "intent",
    tags: ["intent", "eval", "operator", "write"],
    schema: [
      ref: [type: :string, required: false],
      source_ref: [type: :string, required: false],
      id: [type: :string, required: false],
      domain: [type: :string, required: false],
      surface: [type: :string, required: false],
      utterance: [type: :string, required: false],
      kind: [type: :string, required: false],
      action: [type: :string, required: false],
      negative: [type: :boolean, required: false],
      holdout: [type: :boolean, required: false],
      rationale: [type: :string, required: false],
      case: [type: :map, required: false]
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
      with {:ok, result} <- MutationSupport.capture(params) do
        MutationSupport.finish(name(), result, permission_decision, %{
          path: Map.get(result, :path),
          error: Map.get(result, :error)
        })
      end
    end)
  end
end
