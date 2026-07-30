defmodule AllbertAssist.Actions.Memory.ReviewMemoryProposalBatch do
  @moduledoc "Freeze or resume an exact ordinary Memory Keep All batch."

  use AllbertAssist.Action,
    permission: :memory_write,
    exposure: :internal,
    execution_mode: :memory_write,
    skill_backed?: false,
    confirmation: :not_required,
    retry_safety: :safe,
    resumable?: true,
    name: "review_memory_proposal_batch",
    description: "Freeze and apply an exact ordinary Memory proposal Keep All set.",
    category: "memory",
    tags: ["memory", "proposals", "batch", "review", "memory_write"],
    schema: [
      bindings: [type: {:list, :map}, required: false],
      batch_id: [type: :string, required: false],
      namespace: [type: :string, required: false],
      user_id: [type: :string, required: false]
    ],
    output_schema: [
      message: [type: :string, required: true],
      status: [type: :atom, required: true],
      permission_decision: [type: :map, required: true],
      result: [type: :map, required: false],
      actions: [type: {:list, :map}, required: true]
    ]

  alias AllbertAssist.Actions.Memory.Context
  alias AllbertAssist.Memory.ProposalReview
  alias AllbertAssist.Memory.Proposals
  alias AllbertAssist.Security.PermissionGate

  @impl true
  def run(params, context) do
    permission = PermissionGate.authorize(:memory_write, context)

    with true <- PermissionGate.allowed?(permission),
         {:ok, user_id} <- Context.user_id(params, context),
         actor <- "operator:" <> user_id,
         {:ok, batch_id} <- batch_id(params, user_id, actor),
         {:ok, result} <- ProposalReview.resume_batch(batch_id, actor) do
      {:ok,
       %{
         message:
           "Memory proposal batch #{batch_id} completed with #{length(result.results)} result(s).",
         status: :completed,
         permission_decision: permission,
         result: result,
         actions: [action(:completed, permission, batch_id)]
       }}
    else
      false ->
        response(permission, PermissionGate.response_status(permission), permission.reason)

      {:error, reason} ->
        response(
          permission,
          :error,
          "Unable to review Memory proposal batch: #{inspect(reason)}",
          reason
        )
    end
  end

  defp batch_id(params, user_id, actor) do
    case value(params, :batch_id) do
      batch_id when is_binary(batch_id) and batch_id != "" -> {:ok, batch_id}
      _other -> freeze(params, user_id, actor)
    end
  end

  defp freeze(params, user_id, actor) do
    namespace = value(params, :namespace) || "default"

    case Proposals.freeze_batch(user_id, namespace, value(params, :bindings), actor) do
      {:ok, batch} -> {:ok, batch.id}
      {:error, reason} -> {:error, reason}
    end
  end

  defp response(permission, status, message, error \\ nil) do
    body = %{
      message: message,
      status: status,
      permission_decision: permission,
      actions: [action(status, permission, nil, error)]
    }

    {:ok, if(error, do: Map.put(body, :error, error), else: body)}
  end

  defp action(status, permission, batch_id, error \\ nil) do
    %{
      name: "review_memory_proposal_batch",
      status: status,
      permission: :memory_write,
      permission_decision: permission
    }
    |> maybe_put(:batch_id, batch_id)
    |> maybe_put(:error, error)
  end

  defp maybe_put(map, _key, nil), do: map
  defp maybe_put(map, key, value), do: Map.put(map, key, value)
  defp value(params, key), do: Map.get(params, key) || Map.get(params, Atom.to_string(key))
end
