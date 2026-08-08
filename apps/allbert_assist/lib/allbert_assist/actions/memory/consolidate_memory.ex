defmodule AllbertAssist.Actions.Memory.ConsolidateMemory do
  @moduledoc "Run one bounded local-only Memory consolidation pass."

  use AllbertAssist.Action,
    registry_order: 164,
    permission: :memory_propose,
    exposure: :internal,
    execution_mode: :memory_propose,
    skill_backed?: false,
    confirmation: :not_required,
    retry_safety: :safe,
    resumable?: true,
    name: "consolidate_memory",
    description: "Collect bounded authorized conversation evidence into inert Memory proposals.",
    category: "memory",
    tags: ["memory", "consolidation", "managed-job", "memory_propose"],
    schema: [
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
  alias AllbertAssist.Memory.Consolidator
  alias AllbertAssist.Runtime.Response
  alias AllbertAssist.Security

  @impl true
  def run(params, context) do
    permission = Security.authorize(:memory_propose, context)

    with true <- Security.allowed?(permission),
         {:ok, user_id} <- Context.user_id(params, context),
         {:ok, result} <- Consolidator.run(user_id) do
      {:ok,
       %{
         message: message(result),
         status: :completed,
         permission_decision: permission,
         result: result,
         actions: [action(:completed, permission, result)]
       }}
    else
      false ->
        response(
          permission,
          Response.permission_status(permission),
          permission.reason
        )

      {:error, reason} ->
        response(
          permission,
          :error,
          "Unable to consolidate Memory: #{inspect(reason)}",
          reason
        )
    end
  end

  defp message(%{status: "no_op", stopped_reason: reason}),
    do: "Memory consolidation performed no source read: #{reason}."

  defp message(result),
    do:
      "Memory consolidation scanned #{result.scanned} source(s) and created #{result.created} proposal(s)."

  defp response(permission, status, message, error \\ nil) do
    body = %{
      message: message,
      status: status,
      permission_decision: permission,
      actions: [action(status, permission, %{error: error})]
    }

    {:ok, if(error, do: Map.put(body, :error, error), else: body)}
  end

  defp action(status, permission, result) do
    %{
      name: "consolidate_memory",
      status: status,
      permission: :memory_propose,
      permission_decision: permission,
      result: result
    }
  end
end
