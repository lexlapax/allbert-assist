defmodule AllbertAssist.Actions.Intent.EvalRun do
  @moduledoc false

  use AllbertAssist.Action,
    permission: :read_only,
    exposure: :internal,
    execution_mode: :intent_operator_read,
    skill_backed?: false,
    confirmation: :not_required,
    name: "intent_eval_run",
    description: "Run the deterministic intent eval harness and return the redacted DTO.",
    category: "intent",
    tags: ["intent", "eval", "operator", "read_only"],
    schema: [surface: [type: :string, required: false]],
    output_schema: [
      message: [type: :string, required: true],
      status: [type: :atom, required: true],
      permission_decision: [type: :map, required: true],
      eval_result: [type: :map, required: true],
      actions: [type: {:list, :map}, required: true]
    ]

  alias AllbertAssist.Actions.Intent.OperatorSupport
  alias AllbertAssist.Actions.Operator.Support

  @impl true
  def run(params, context) do
    Support.read_only(name(), context, fn permission_decision ->
      case OperatorSupport.eval_result(surface: surface(params)) do
        {:ok, eval_result} ->
          message = OperatorSupport.render_eval_result(eval_result)

          {:ok,
           %{
             message: message,
             model_payload: "Intent eval run result.",
             surface_payload: message,
             status: :completed,
             permission_decision: permission_decision,
             eval_result: eval_result,
             actions: [
               Support.action(name(), :completed, permission_decision, %{
                 gate: eval_result.gate.status,
                 accuracy: eval_result.score.overall_accuracy
               })
             ]
           }}

        {:error, reason} ->
          message = "intent eval run failed: #{inspect(reason)}"

          {:ok,
           %{
             message: message,
             model_payload: "Intent eval run failed.",
             surface_payload: message,
             status: :error,
             permission_decision: permission_decision,
             eval_result: %{error: reason},
             actions: [
               Support.action(name(), :error, permission_decision, %{error: reason})
             ]
           }}
      end
    end)
  end

  defp surface(params) do
    case Map.get(params, :surface, Map.get(params, "surface")) do
      value when value in [nil, "", "any", :any] -> :any
      value when is_atom(value) -> value
      value when is_binary(value) -> String.to_existing_atom(value)
    end
  rescue
    ArgumentError -> :any
  end
end
