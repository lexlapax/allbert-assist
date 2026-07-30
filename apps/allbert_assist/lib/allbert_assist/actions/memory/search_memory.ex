defmodule AllbertAssist.Actions.Memory.SearchMemory do
  @moduledoc "Searches canonical Memory through its projection or bounded Markdown fallback."

  use AllbertAssist.Action,
    permission: :read_only,
    exposure: :internal,
    execution_mode: :memory_read,
    skill_backed?: false,
    confirmation: :not_required,
    name: "search_memory",
    description: "Search markdown memory entries by keyword and recency.",
    category: "memory",
    tags: ["memory", "search", "read_only"],
    schema: [
      query: [type: :string, required: true],
      user_id: [type: :string, required: false],
      category: [type: :string, required: false],
      limit: [type: :integer, required: false]
    ],
    output_schema: [
      message: [type: :string, required: true],
      status: [type: :atom, required: true],
      permission_decision: [type: :map, required: true],
      entries: [type: {:list, :map}, required: true],
      actions: [type: {:list, :map}, required: true]
    ]

  alias AllbertAssist.Actions.Memory.Context
  alias AllbertAssist.Memory.Projection
  alias AllbertAssist.Memory.Retrieval
  alias AllbertAssist.Security.PermissionGate
  alias AllbertAssist.Settings
  alias AllbertAssist.Validation

  @impl true
  def run(%{query: query} = params, context), do: do_run(query, params, context)
  def run(%{"query" => query} = params, context), do: do_run(query, params, context)

  def run(_params, context),
    do: error(PermissionGate.authorize(:read_only, context), :missing_query)

  defp do_run(query, params, context) do
    permission_decision = PermissionGate.authorize(:read_only, context)

    with {:allowed, true} <- {:allowed, PermissionGate.allowed?(permission_decision)},
         {:ok, user_id} <- Context.user_id(params, context),
         {:ok, entries, source} <- search(query, params, user_id, context) do
      {:ok,
       %{
         message: "Found #{length(entries)} memory search result(s).",
         status: :completed,
         permission_decision: permission_decision,
         entries: entries,
         actions: [
           %{
             name: "search_memory",
             status: :completed,
             permission: :read_only,
             permission_decision: permission_decision,
             source: source,
             user_id: user_id,
             result_count: length(entries)
           }
         ]
       }}
    else
      {:allowed, false} -> denied(permission_decision)
      {:error, reason} -> error(permission_decision, reason)
    end
  end

  defp search(query, params, user_id, context) do
    opts = [user_id: user_id, categories: category(params), limit: limit(params)]

    case projection_for_search(context) do
      {:ok, projection} -> search_projection(query, Keyword.put(opts, :projection, projection))
      :fallback -> search_markdown(query, opts)
    end
  end

  defp projection_for_search(context) do
    projection = Map.get(context, :memory_projection) || Process.whereis(Projection)

    if index_enabled?() and not is_nil(projection), do: {:ok, projection}, else: :fallback
  end

  defp search_projection(query, opts) do
    case Retrieval.projection_search(query, opts) do
      {:ok, result} -> {:ok, result.entries, :projection}
      {:error, :memory_projection_not_ready} -> search_markdown(query, opts)
      {:error, reason} -> {:error, reason}
    end
  end

  defp search_markdown(query, opts) do
    with {:ok, result} <- Retrieval.markdown_search(query, opts) do
      {:ok, result.entries, :markdown}
    end
  end

  defp index_enabled? do
    case Settings.get("memory.index_enabled") do
      {:ok, false} -> false
      _other -> true
    end
  end

  defp category(params), do: Map.get(params, :category) || Map.get(params, "category")

  defp limit(params) do
    case Map.get(params, :limit) || Map.get(params, "limit") do
      value when is_integer(value) -> Validation.clamp_limit(value, 1, 50)
      _other -> 10
    end
  end

  defp denied(permission_decision) do
    {:ok,
     %{
       message: permission_decision.reason,
       status: PermissionGate.response_status(permission_decision),
       permission_decision: permission_decision,
       entries: [],
       actions: [action(:denied, permission_decision, nil)]
     }}
  end

  defp error(permission_decision, reason) do
    {:ok,
     %{
       message: "Unable to search memory: #{inspect(reason)}",
       status: :error,
       error: reason,
       permission_decision: permission_decision,
       entries: [],
       actions: [action(:error, permission_decision, reason)]
     }}
  end

  defp action(status, permission_decision, error) do
    %{
      name: "search_memory",
      status: status,
      permission: :read_only,
      permission_decision: permission_decision,
      error: error
    }
    |> Enum.reject(fn {_key, value} -> is_nil(value) end)
    |> Map.new()
  end
end
