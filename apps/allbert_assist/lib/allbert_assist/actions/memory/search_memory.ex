defmodule AllbertAssist.Actions.Memory.SearchMemory do
  @moduledoc "Searches markdown memory using the derived index when possible."

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
  alias AllbertAssist.Memory
  alias AllbertAssist.Memory.Entry
  alias AllbertAssist.Memory.Index
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
         {:ok, entries, source} <- search(query, params, user_id) do
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

  defp search(query, params, user_id) do
    root = Memory.root()

    if index_enabled?() and not Index.stale?(root) and index_searchable?(root) do
      search_index(root, query, params, user_id)
    else
      direct_search(query, params, user_id)
    end
  end

  defp index_searchable?(root) do
    case Index.load(root) do
      {:ok, _index} -> true
      {:error, _reason} -> false
    end
  end

  defp search_index(root, query, params, user_id) do
    with {:ok, index} <- Index.load(root),
         {:ok, entries} <-
           Index.query(
             index,
             query,
             user_id: user_id,
             categories: category(params),
             limit: limit(params)
           ) do
      {:ok, entries, :index}
    end
  end

  defp direct_search(query, params, user_id) do
    tokens = Index.tokens(query)

    with {:ok, entries} <-
           Memory.list_entries(
             user_id: user_id,
             category: category(params),
             limit: 500
           ) do
      results =
        entries
        |> Enum.reject(&(&1.review_status in [:flagged, :prune_nominated]))
        |> Enum.map(&score_entry(&1, tokens))
        |> Enum.filter(fn {score, _entry} -> score > 0 end)
        |> Enum.sort_by(fn {score, entry} -> {score, entry.timestamp, entry.path} end, :desc)
        |> Enum.take(limit(params))
        |> Enum.map(fn {score, entry} ->
          entry
          |> Entry.to_map(include_body: false)
          |> Map.put(:score, Float.round(score, 3))
          |> Map.put(:match_reasons, match_reasons(entry, tokens))
        end)

      {:ok, results, :markdown}
    end
  end

  defp score_entry(_entry, []), do: {0.0, nil}

  defp score_entry(entry, tokens) do
    haystack =
      [entry.summary, entry.body, Atom.to_string(entry.category)]
      |> Enum.join(" ")
      |> String.downcase()

    matches = Enum.count(tokens, &String.contains?(haystack, &1))
    {min(1.0, matches * 0.35), entry}
  end

  defp match_reasons(entry, tokens) do
    haystack =
      [entry.summary, entry.body, Atom.to_string(entry.category)]
      |> Enum.join(" ")
      |> String.downcase()

    tokens
    |> Enum.filter(&String.contains?(haystack, &1))
    |> Enum.map(&"keyword:#{&1}")
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
