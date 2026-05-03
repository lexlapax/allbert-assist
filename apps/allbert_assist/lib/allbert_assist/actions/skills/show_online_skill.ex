defmodule AllbertAssist.Actions.Skills.ShowOnlineSkill do
  @moduledoc """
  Confirmed online skill detail fetch over a configured source profile.
  """

  use Jido.Action,
    name: "show_online_skill",
    description: "Fetch or display details for a configured online skill source result.",
    category: "skills",
    tags: ["skills", "online", "external_network"],
    schema: [
      source: [type: :string, required: true, doc: "Configured online skill source."],
      id: [type: :string, required: true, doc: "Source-local skill identifier."]
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
    source_id = param(params, :source)
    id = params |> param(:id) |> to_string() |> String.trim()
    permission_decision = PermissionGate.authorize(:external_network, context)

    with {:ok, source} <- Source.load(source_id, context),
         :ok <- Source.validate_enabled(source) do
      cond do
        permission_decision.decision == :denied ->
          denied_response(id, source, permission_decision, :permission_denied)

        approval_resume?(context) ->
          execute_show(id, source, permission_decision)

        true ->
          create_confirmation(id, source, context, permission_decision)
      end
    else
      {:error, reason} ->
        denied_response(id, %Source{id: to_string(source_id)}, permission_decision, reason)
    end
  end

  defp param(params, key), do: Map.get(params, key) || Map.get(params, Atom.to_string(key))

  defp execute_show(id, source, permission_decision) do
    case RegistryClient.show(source, id) do
      {:ok, detail} ->
        summary = detail_summary(detail)

        {:ok,
         %{
           message: "Online skill detail fetched for #{id}.",
           status: :completed,
           permission_decision: permission_decision,
           online_skill_detail: summary,
           result: summary,
           actions: [
             %{
               name: "show_online_skill",
               status: :completed,
               permission: :external_network,
               permission_decision: permission_decision,
               execution: :online_skill_detail,
               target_resumed?: true,
               online_skill_detail: summary
             }
           ]
         }}

      {:error, reason} ->
        failed_response(id, source, permission_decision, reason)
    end
  end

  defp create_confirmation(id, source, context, permission_decision) do
    attrs = %{
      origin: origin(context),
      target_action: %{name: "show_online_skill", module: inspect(__MODULE__)},
      target_permission: :external_network,
      target_execution_mode: :online_skill_detail,
      security_decision: permission_decision,
      params_summary: %{source: Source.summary(source), id: id},
      resume_params_ref: %{source: source.id, id: id}
    }

    case Confirmations.create(attrs) do
      {:ok, confirmation} ->
        {:ok,
         %{
           message:
             "Online skill detail is ready for approval. Confirmation request: #{confirmation["id"]}. Nothing has fetched yet.",
           status: :needs_confirmation,
           permission_decision: permission_decision,
           confirmation: confirmation,
           confirmation_id: confirmation["id"],
           actions: [
             %{
               name: "show_online_skill",
               status: :needs_confirmation,
               permission: :external_network,
               permission_decision: permission_decision,
               execution: :pending_confirmation,
               confirmation_id: confirmation["id"],
               online_skill: %{source: Source.summary(source), id: id}
             }
           ]
         }}

      {:error, reason} ->
        denied_response(id, source, permission_decision, reason)
    end
  end

  defp denied_response(id, source, permission_decision, reason) do
    result = %{
      source: Source.summary(source),
      id: id,
      status: :denied,
      denial_reason: reason_summary(reason)
    }

    {:ok,
     %{
       message: "Online skill detail was denied: #{inspect(reason)}.",
       status: :denied,
       permission_decision: permission_decision,
       online_skill_detail: result,
       result: result,
       actions: [
         %{
           name: "show_online_skill",
           status: :denied,
           permission: :external_network,
           permission_decision: permission_decision,
           execution: :not_started,
           online_skill_detail: result,
           denial_reason: reason
         }
       ]
     }}
  end

  defp failed_response(id, source, permission_decision, reason) do
    result = %{
      source: Source.summary(source),
      id: id,
      status: :failed,
      failure_reason: reason_summary(reason)
    }

    {:ok,
     %{
       message: "Online skill detail failed after approval: #{inspect(reason)}.",
       status: :failed,
       permission_decision: permission_decision,
       online_skill_detail: result,
       result: result,
       actions: [
         %{
           name: "show_online_skill",
           status: :failed,
           permission: :external_network,
           permission_decision: permission_decision,
           execution: :online_skill_detail,
           target_resumed?: true,
           online_skill_detail: result,
           failure_reason: reason
         }
       ]
     }}
  end

  defp reason_summary({code, detail}), do: %{code: code, detail: inspect(detail)}
  defp reason_summary(reason) when is_atom(reason), do: Atom.to_string(reason)
  defp reason_summary(reason) when is_binary(reason), do: reason
  defp reason_summary(reason), do: inspect(reason)

  defp detail_summary(detail) do
    %{
      id: detail.id,
      source: detail.source,
      source_url: detail.source_url,
      candidate: Map.drop(detail.candidate, [:raw]),
      files: detail.files |> Map.keys() |> Enum.sort(),
      skill_md_present?: is_binary(detail.skill_md),
      fetched_at: detail.fetched_at
    }
  end

  defp origin(context) do
    request = Map.get(context, :request, %{})

    %{
      actor: Map.get(request, :operator_id, Map.get(context, :actor, "local")),
      channel: Map.get(request, :channel, Map.get(context, :channel, :unknown)),
      surface: Map.get(context, :surface, "show_online_skill"),
      session_id: Map.get(request, :session_id, Map.get(context, :session_id)),
      response_target: Map.get(context, :response_target)
    }
  end

  defp approval_resume?(context) do
    get_in(context, [:confirmation, :approved?]) == true ||
      get_in(context, ["confirmation", "approved?"]) == true
  end
end
