defmodule AllbertAssist.Actions.Skills.SearchOnlineSkills do
  @moduledoc """
  Confirmed online skill search over a configured source profile.
  """

  use Jido.Action,
    name: "search_online_skills",
    description: "Search a configured online skill source after confirmation.",
    category: "skills",
    tags: ["skills", "online", "external_network"],
    schema: [
      query: [type: :string, required: true, doc: "Search query."],
      source: [type: :string, required: false, doc: "Configured online skill source."]
    ],
    output_schema: [
      message: [type: :string, required: true],
      status: [type: :atom, required: true],
      permission_decision: [type: :map, required: true],
      actions: [type: {:list, :map}, required: true]
    ]

  alias AllbertAssist.Confirmations
  alias AllbertAssist.Security.PermissionGate
  alias AllbertAssist.Skills.Online.RegistryClient
  alias AllbertAssist.Skills.Online.Source

  @impl true
  def run(params, context) when is_map(params) do
    query = params |> param(:query) |> to_string() |> String.trim()
    source_id = param(params, :source) || "skills_sh"
    permission_decision = PermissionGate.authorize(:external_network, context)

    with {:ok, source} <- Source.load(source_id, context),
         :ok <- Source.validate_enabled(source) do
      cond do
        permission_decision.decision == :denied ->
          denied_response(query, source, permission_decision, :permission_denied)

        approval_resume?(context) ->
          execute_search(query, source, permission_decision)

        true ->
          create_confirmation(query, source, context, permission_decision)
      end
    else
      {:error, reason} ->
        denied_response(query, source_stub(source_id), permission_decision, reason)
    end
  end

  defp param(params, key), do: Map.get(params, key) || Map.get(params, Atom.to_string(key))

  defp execute_search(query, source, permission_decision) do
    case RegistryClient.search(source, query) do
      {:ok, result} ->
        {:ok,
         %{
           message: "Online skill search completed with #{length(result.results)} result(s).",
           status: :completed,
           permission_decision: permission_decision,
           online_skill_search: result,
           result: result,
           actions: [
             %{
               name: "search_online_skills",
               status: :completed,
               permission: :external_network,
               permission_decision: permission_decision,
               execution: :online_skill_search,
               target_resumed?: true,
               online_skill_search: result
             }
           ]
         }}

      {:error, reason} ->
        failed_response(query, source, permission_decision, reason)
    end
  end

  defp create_confirmation(query, source, context, permission_decision) do
    attrs =
      confirmation_attrs(
        "search_online_skills",
        :external_network,
        :online_skill_search,
        %{
          source: Source.summary(source),
          query: query
        },
        %{query: query, source: source.id},
        context,
        permission_decision
      )

    case Confirmations.create(attrs) do
      {:ok, confirmation} ->
        {:ok,
         %{
           message: confirmation_message("Online skill search", confirmation, source, query),
           status: :needs_confirmation,
           permission_decision: permission_decision,
           confirmation: confirmation,
           confirmation_id: confirmation["id"],
           actions: [
             %{
               name: "search_online_skills",
               status: :needs_confirmation,
               permission: :external_network,
               permission_decision: permission_decision,
               execution: :pending_confirmation,
               confirmation_id: confirmation["id"],
               online_skill: %{source: Source.summary(source), query: query}
             }
           ]
         }}

      {:error, reason} ->
        denied_response(query, source, permission_decision, reason)
    end
  end

  defp denied_response(query, source, permission_decision, reason) do
    result = %{
      source: Source.summary(source),
      query: query,
      status: :denied,
      denial_reason: reason_summary(reason)
    }

    {:ok,
     %{
       message: "Online skill search was denied: #{inspect(reason)}.",
       status: :denied,
       permission_decision: permission_decision,
       online_skill_search: result,
       result: result,
       actions: [
         %{
           name: "search_online_skills",
           status: :denied,
           permission: :external_network,
           permission_decision: permission_decision,
           execution: :not_started,
           online_skill_search: result,
           denial_reason: reason
         }
       ]
     }}
  end

  defp failed_response(query, source, permission_decision, reason) do
    result = %{
      source: Source.summary(source),
      query: query,
      status: :failed,
      failure_reason: reason_summary(reason)
    }

    {:ok,
     %{
       message: "Online skill search failed after approval: #{inspect(reason)}.",
       status: :failed,
       permission_decision: permission_decision,
       online_skill_search: result,
       result: result,
       actions: [
         %{
           name: "search_online_skills",
           status: :failed,
           permission: :external_network,
           permission_decision: permission_decision,
           execution: :online_skill_search,
           target_resumed?: true,
           online_skill_search: result,
           failure_reason: reason
         }
       ]
     }}
  end

  defp reason_summary({code, detail}), do: %{code: code, detail: inspect(detail)}
  defp reason_summary(reason) when is_atom(reason), do: Atom.to_string(reason)
  defp reason_summary(reason) when is_binary(reason), do: reason
  defp reason_summary(reason), do: inspect(reason)

  defp confirmation_attrs(name, permission, execution_mode, summary, resume, context, decision) do
    %{
      origin: origin(context),
      target_action: %{name: name, module: inspect(__MODULE__)},
      target_permission: permission,
      target_execution_mode: execution_mode,
      security_decision: decision,
      source_signal_id: get_in(context, [:request, :input_signal_id]),
      source_trace_id: Map.get(context, :trace_id) || get_in(context, [:request, :trace_id]),
      runner_metadata: %{selected_action: name},
      params_summary: summary,
      resume_params_ref: resume
    }
  end

  defp confirmation_message(kind, confirmation, source, query) do
    """
    #{kind} is ready for operator approval.

    Source: #{source.id}
    Query: #{query}
    Confirmation request: #{confirmation["id"]}.
    Nothing has fetched yet.
    """
    |> String.trim()
  end

  defp origin(context) do
    request = Map.get(context, :request, %{})

    %{
      actor: Map.get(request, :operator_id, Map.get(context, :actor, "local")),
      channel: Map.get(request, :channel, Map.get(context, :channel, :unknown)),
      surface: Map.get(context, :surface, "search_online_skills"),
      session_id: Map.get(request, :session_id, Map.get(context, :session_id)),
      response_target: Map.get(context, :response_target)
    }
  end

  defp approval_resume?(context) do
    get_in(context, [:confirmation, :approved?]) == true ||
      get_in(context, ["confirmation", "approved?"]) == true
  end

  defp source_stub(source_id), do: %Source{id: to_string(source_id)}
end
