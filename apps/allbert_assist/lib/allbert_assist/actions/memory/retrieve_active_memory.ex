defmodule AllbertAssist.Actions.Memory.RetrieveActiveMemory do
  @moduledoc "Retrieves deterministic read-only Active Memory chunks."

  use AllbertAssist.Action,
    permission: :read_only,
    exposure: :internal,
    execution_mode: :memory_read,
    skill_backed?: false,
    confirmation: :not_required,
    name: "retrieve_active_memory",
    description: "Retrieve deterministic top-K reviewed memory chunks for direct-answer context.",
    category: "memory",
    tags: ["memory", "active_memory", "read_only"],
    schema: [
      query: [type: :string, required: true],
      user_id: [type: :string, required: false],
      thread_id: [type: :string, required: false],
      active_app: [type: :string, required: false],
      identity_namespace: [type: :string, required: false],
      now: [type: :string, required: false]
    ],
    output_schema: [
      message: [type: :string, required: true],
      status: [type: :atom, required: true],
      permission_decision: [type: :map, required: true],
      active_memory: [type: :map, required: true],
      chunks: [type: {:list, :map}, required: true],
      actions: [type: {:list, :map}, required: true]
    ]

  alias AllbertAssist.Memory.ActiveMemory
  alias AllbertAssist.Security.PermissionGate

  @impl true
  def run(%{query: query} = params, context), do: do_run(query, params, context)
  def run(%{"query" => query} = params, context), do: do_run(query, params, context)

  def run(_params, context),
    do: error(PermissionGate.authorize(:read_only, context), :missing_query)

  defp do_run(query, params, context) do
    permission_decision = PermissionGate.authorize(:read_only, context)

    with {:allowed, true} <- {:allowed, PermissionGate.allowed?(permission_decision)},
         {:ok, active_memory} <- ActiveMemory.retrieve(query, retrieval_opts(params, context)) do
      {:ok,
       %{
         message: "Retrieved #{length(active_memory.chunks)} Active Memory chunk(s).",
         status: :completed,
         permission_decision: permission_decision,
         active_memory: active_memory,
         chunks: active_memory.chunks,
         actions: [
           action(:completed, permission_decision, ActiveMemory.trace_metadata(active_memory))
         ]
       }}
    else
      {:allowed, false} ->
        denied(permission_decision)

      {:error, reason} ->
        error(permission_decision, reason)
    end
  end

  defp retrieval_opts(params, context) do
    [
      user_id: value(params, context, :user_id),
      thread_id: value(params, context, :thread_id),
      active_app: value(params, context, :active_app),
      identity_namespace: value(params, context, :identity_namespace),
      now: value(params, context, :now)
    ]
    |> Enum.reject(fn {_key, value} -> is_nil(value) end)
  end

  defp value(params, context, key) do
    Map.get(params, key) ||
      Map.get(params, Atom.to_string(key)) ||
      Map.get(context, key) ||
      get_in(context, [:request, key]) ||
      get_in(context, [:request, Atom.to_string(key)])
  end

  defp denied(permission_decision) do
    active_memory = disabled_metadata(:permission_denied)

    {:ok,
     %{
       message: permission_decision.reason,
       status: PermissionGate.response_status(permission_decision),
       permission_decision: permission_decision,
       active_memory: active_memory,
       chunks: [],
       actions: [action(:denied, permission_decision, active_memory)]
     }}
  end

  defp error(permission_decision, reason) do
    active_memory = disabled_metadata(reason)

    {:ok,
     %{
       message: "Unable to retrieve Active Memory: #{inspect(reason)}",
       status: :error,
       error: reason,
       permission_decision: permission_decision,
       active_memory: active_memory,
       chunks: [],
       actions: [action(:error, permission_decision, active_memory)]
     }}
  end

  defp disabled_metadata(reason) do
    %{
      status: :unavailable,
      enabled?: false,
      error: reason,
      retrieved_chunks: [],
      excluded_chunks_sample: []
    }
  end

  defp action(status, permission_decision, active_memory) do
    %{
      name: "retrieve_active_memory",
      status: status,
      permission: :read_only,
      permission_decision: permission_decision,
      active_memory: active_memory
    }
  end
end
