defmodule AllbertAssist.Actions.Search.SearchConversations do
  @moduledoc """
  Registered read boundary for the central conversation Search API.

  Search query text is intentionally transient. `trace_safe_summary/2` runs in
  the shared Runner before requested/completed signals and emits only the
  Search-owned content-free summary.
  """

  use AllbertAssist.Action,
    registry_order: 60,
    permission: :read_only,
    exposure: :internal,
    execution_mode: :search_read,
    skill_backed?: false,
    confirmation: :not_required,
    name: "search_conversations",
    description: "Search currently authorized canonical conversation history.",
    category: "search",
    tags: ["search", "conversations", "read_only"],
    schema: [
      query: [type: :string, required: true],
      order: [type: :any, required: false],
      limit: [type: :integer, required: false],
      cursor: [type: :string, required: false],
      filters: [type: :map, required: false],
      query_chain_id: [type: :string, required: false]
    ],
    output_schema: [
      message: [type: :string, required: true],
      status: [type: :atom, required: true],
      permission_decision: [type: :map, required: true],
      search_page: [type: :map, required: false],
      actions: [type: {:list, :map}, required: true]
    ]

  alias AllbertAssist.Search
  alias AllbertAssist.Security.PermissionGate

  @impl true
  def run(params, context) do
    permission_decision = PermissionGate.authorize(:read_only, context)

    if PermissionGate.allowed?(permission_decision) do
      execute(params, context, permission_decision)
    else
      {:ok,
       %{
         message: permission_decision.reason,
         status: PermissionGate.response_status(permission_decision),
         permission_decision: permission_decision,
         actions: [action(:denied, permission_decision, nil)]
       }}
    end
  end

  def trace_safe_summary(:params, params), do: Search.trace_summary(params)

  def trace_safe_summary(:result, response) when is_map(response) do
    page = Map.get(response, :search_page, %{})

    %{
      status: Map.get(response, :status),
      error: safe_error(Map.get(response, :error)),
      result_count: page |> Map.get(:results, []) |> length(),
      generation_id: Map.get(page, :generation_id),
      projection_revision: Map.get(page, :projection_revision),
      freshness_ms: Map.get(page, :freshness_ms),
      scanned_count: Map.get(page, :scanned_count),
      filtered_count: Map.get(page, :filtered_count),
      incomplete: Map.get(page, :incomplete)
    }
  end

  def trace_safe_summary(_stage, _value), do: %{summary_unavailable: true}

  defp execute(params, context, permission_decision) do
    case Search.query(params, context) do
      {:ok, page} ->
        search_page = page_to_map(page)

        {:ok,
         %{
           message: "Found #{length(page.results)} authorized conversation result(s).",
           status: :completed,
           permission_decision: permission_decision,
           search_page: search_page,
           actions: [action(:completed, permission_decision, trace_page(search_page))]
         }}

      {:error, reason} ->
        {:ok,
         %{
           message: "Conversation search unavailable: #{safe_error(reason)}.",
           status: :error,
           error: reason,
           permission_decision: permission_decision,
           actions: [action(:error, permission_decision, %{error: safe_error(reason)})]
         }}
    end
  end

  defp page_to_map(page) do
    page
    |> Map.from_struct()
    |> Map.update!(:results, &Enum.map(&1, fn result -> Map.from_struct(result) end))
  end

  defp trace_page(page) do
    Map.take(page, [
      :generation_id,
      :projection_revision,
      :freshness_ms,
      :scanned_count,
      :filtered_count,
      :incomplete,
      :incomplete_reason
    ])
    |> Map.put(:result_count, length(page.results))
  end

  defp action(status, permission_decision, summary) do
    %{
      name: "search_conversations",
      status: status,
      permission: :read_only,
      permission_decision: permission_decision,
      search: summary
    }
  end

  defp safe_error(nil), do: nil
  defp safe_error(reason) when is_atom(reason), do: reason
  defp safe_error({reason, _detail}) when is_atom(reason), do: reason
  defp safe_error(_reason), do: :search_failed
end
