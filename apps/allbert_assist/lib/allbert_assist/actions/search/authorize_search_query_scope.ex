defmodule AllbertAssist.Actions.Search.AuthorizeSearchQueryScope do
  @moduledoc """
  Confirms one mapped-DM cross-surface Search request/cursor chain.

  Approval records the operator decision and returns a resubmit requirement; it
  never executes the query from durable confirmation state.
  """

  use AllbertAssist.Action,
    registry_order: 61,
    permission: :read_only,
    exposure: :internal,
    execution_mode: :search_scope_authorization,
    skill_backed?: false,
    confirmation: :required,
    resumable?: true,
    name: "authorize_search_query_scope",
    description: "Authorize one exact mapped-DM cross-surface Search query chain.",
    category: "search",
    tags: ["search", "authorization", "confirmation"],
    schema: [
      query: [type: :string, required: false],
      order: [type: :any, required: false],
      limit: [type: :integer, required: false],
      filters: [type: :map, required: false],
      source_message_id: [type: :string, required: false],
      operator_id: [type: :string, required: false],
      thread_id: [type: :string, required: false],
      origin: [type: :map, required: false],
      requested_scope: [type: :string, required: false],
      expires_at: [type: :integer, required: false],
      filter_kinds: [type: {:list, :string}, required: false],
      filter_count: [type: :integer, required: false],
      request_binding: [type: :string, required: false],
      key_ref: [type: :string, required: false],
      key_version: [type: :integer, required: false]
    ],
    output_schema: [
      message: [type: :string, required: true],
      status: [type: :atom, required: true],
      permission_decision: [type: :map, required: true],
      confirmation_id: [type: :string, required: false],
      output_data: [type: :map, required: false],
      actions: [type: {:list, :map}, required: true]
    ]

  alias AllbertAssist.Confirmations
  alias AllbertAssist.Confirmations.Origin
  alias AllbertAssist.Search.Query
  alias AllbertAssist.Search.QueryScope
  alias AllbertAssist.Security.PermissionGate

  @action_name "authorize_search_query_scope"

  @impl true
  def run(params, context) do
    decision = PermissionGate.authorize(:read_only, context)

    cond do
      not PermissionGate.allowed?(decision) -> denied(decision)
      approved_resume?(context) -> resubmit_required(context, decision)
      true -> request_confirmation(params, context, decision)
    end
  end

  def trace_safe_summary(:params, params) do
    case Query.parse(Map.take(params, [:query, :order, :limit, :filters])) do
      {:ok, query} -> Query.trace_summary(query)
      {:error, _reason} -> safe_resume_summary(params)
    end
  end

  def trace_safe_summary(:result, response) do
    %{
      status: Map.get(response, :status),
      outcome: get_in(response, [:output_data, :outcome]),
      confirmation_id: Map.get(response, :confirmation_id)
    }
  end

  defp request_confirmation(params, context, decision) do
    request = Map.take(params, [:query, :order, :limit, :filters])

    binding_context =
      Map.merge(
        context,
        Map.take(params, [:source_message_id, :operator_id, :thread_id, :origin])
      )

    with {:ok, query} <- Query.parse(request),
         {:ok, safe} <- QueryScope.bind(query, binding_context),
         {:ok, confirmation} <- create_confirmation(safe, context, decision) do
      confirmation_id = confirmation["id"]

      {:ok,
       response_needs_confirmation(
         "Cross-surface Search requires approval #{confirmation_id}; approval will require exact query resubmission.",
         %{
           permission_decision: decision,
           confirmation_id: confirmation_id,
           actions: [action(:needs_confirmation, decision, confirmation_id)]
         }
       )}
    else
      {:error, reason} -> failed(decision, reason)
    end
  end

  defp create_confirmation(safe, context, decision) do
    Confirmations.create(
      %{
        origin: Origin.from_context(context, @action_name),
        target_action: %{name: @action_name, module: inspect(__MODULE__)},
        target_permission: :read_only,
        target_execution_mode: :search_scope_authorization,
        security_decision: decision,
        params_summary: safe,
        resume_params_ref: safe
      },
      context
    )
  end

  defp resubmit_required(context, decision) do
    confirmation_id = get_in(context, [:confirmation, :id])

    {:ok,
     %{
       message: "Search scope approved; resubmit the exact query with chain #{confirmation_id}.",
       status: :completed,
       permission_decision: decision,
       confirmation_id: confirmation_id,
       output_data: %{outcome: :query_resubmit_required, query_chain_id: confirmation_id},
       actions: [action(:completed, decision, confirmation_id)]
     }}
  end

  defp denied(decision) do
    {:ok,
     %{
       message: decision.reason,
       status: PermissionGate.response_status(decision),
       permission_decision: decision,
       actions: [action(:denied, decision, nil)]
     }}
  end

  defp failed(decision, reason) do
    {:ok,
     %{
       message: "Unable to authorize Search scope: #{safe_error(reason)}.",
       status: :error,
       error: reason,
       permission_decision: decision,
       actions: [action(:error, decision, nil)]
     }}
  end

  defp action(status, decision, confirmation_id) do
    %{
      name: @action_name,
      status: status,
      permission: :read_only,
      permission_decision: decision,
      confirmation_id: confirmation_id
    }
  end

  defp safe_resume_summary(params) do
    %{
      requested_scope: Map.get(params, :requested_scope),
      expires_at: Map.get(params, :expires_at),
      filter_kinds: Map.get(params, :filter_kinds, []),
      filter_count: Map.get(params, :filter_count, 0),
      source_message_id: Map.get(params, :source_message_id)
    }
  end

  defp approved_resume?(context), do: get_in(context, [:confirmation, :approved?]) == true
  defp safe_error(reason) when is_atom(reason), do: reason
  defp safe_error(_reason), do: :scope_denied
end
