defmodule AllbertAssist.Actions.Intent.ExternalNetworkRequest do
  @moduledoc """
  Handles external-network-shaped requests without making network calls.

  M4 introduces the permission class and explicit decision; it does not add a
  network adapter or confirmation UI.
  """

  use Jido.Action,
    name: "external_network_request",
    description:
      "Mark an external network request as requiring confirmation without calling out.",
    category: "intent",
    tags: ["intent", "network", "external_network", "safe"],
    schema: [
      request: [type: :string, required: true, doc: "The requested network task or URL."],
      source_text: [type: :string, required: false, doc: "The original user prompt."]
    ],
    output_schema: [
      message: [type: :string, required: true],
      status: [type: :atom, required: true],
      permission_decision: [type: :map, required: true],
      actions: [type: {:list, :map}, required: true]
    ]

  alias AllbertAssist.Confirmations
  alias AllbertAssist.Security.PermissionGate

  @impl true
  def run(%{request: request} = params, context) do
    request = String.trim(request)
    permission_decision = PermissionGate.authorize(:external_network, context)

    with {:ok, confirmation} <-
           maybe_create_confirmation(request, params, context, permission_decision) do
      {:ok,
       %{
         message: message(request, permission_decision, confirmation),
         status: PermissionGate.response_status(permission_decision),
         permission_decision: permission_decision,
         confirmation: confirmation,
         confirmation_id: confirmation_id(confirmation),
         actions: [
           %{
             name: "external_network_request",
             status: :not_executed,
             permission: :external_network,
             permission_decision: permission_decision,
             execution: :not_available,
             confirmation_id: confirmation_id(confirmation),
             confirmation_metadata: confirmation_metadata(confirmation),
             input: %{request: request, source_text: Map.get(params, :source_text)}
           }
         ]
       }}
    else
      {:error, reason} -> confirmation_error(request, permission_decision, reason)
    end
  end

  defp maybe_create_confirmation(
         request,
         params,
         context,
         %{decision: :needs_confirmation} = decision
       ) do
    Confirmations.create(%{
      origin: origin(context),
      target_action: %{name: "external_network_request", module: inspect(__MODULE__)},
      target_permission: :external_network,
      target_execution_mode: :external_network_unavailable,
      selected_skill: selected_skill(context),
      capability_contract: capability_contract(context),
      security_decision: decision,
      source_signal_id: source_signal_id(context),
      source_trace_id: source_trace_id(context),
      runner_metadata: runner_metadata(context),
      params_summary: %{request: request, source_text: Map.get(params, :source_text)},
      resume_params_ref: %{
        action: "external_network_request",
        request: request,
        source_text: Map.get(params, :source_text)
      }
    })
  end

  defp maybe_create_confirmation(_request, _params, _context, _decision), do: {:ok, nil}

  defp message(request, permission_decision, confirmation) do
    """
    I will not use external network access from this milestone.

    Requested network task:
    #{request}

    Permission gate decision: #{permission_decision.decision} for external_network.
    Confirmation request: #{confirmation_id(confirmation) || "not created"}.
    A future adapter milestone must exist before approval can make a request.
    """
    |> String.trim()
  end

  defp confirmation_error(request, permission_decision, reason) do
    {:ok,
     %{
       message:
         "Could not create confirmation request for external network task #{inspect(request)}.",
       status: :error,
       error: reason,
       permission_decision: permission_decision,
       actions: [
         %{
           name: "external_network_request",
           status: :error,
           permission: :external_network,
           permission_decision: permission_decision,
           execution: :not_available,
           error: reason
         }
       ]
     }}
  end

  defp confirmation_id(%{"id" => id}), do: id
  defp confirmation_id(_confirmation), do: nil

  defp confirmation_metadata(nil), do: nil

  defp confirmation_metadata(confirmation) do
    %{
      id: Map.get(confirmation, "id"),
      status: Map.get(confirmation, "status"),
      origin: Map.get(confirmation, "origin"),
      expires_at: Map.get(confirmation, "expires_at"),
      audit_path: Map.get(confirmation, "audit_path")
    }
  end

  defp origin(context) do
    request = Map.get(context, :request, %{})

    %{
      actor: Map.get(request, :operator_id, Map.get(context, :actor, "local")),
      channel: Map.get(request, :channel, Map.get(context, :channel, :unknown)),
      surface: Map.get(context, :surface, "external_network_request"),
      session_id: Map.get(request, :session_id, Map.get(context, :session_id)),
      response_target: Map.get(context, :response_target)
    }
  end

  defp selected_skill(context) do
    metadata = Map.get(context, :skill_metadata, %{})

    %{
      name: Map.get(context, :selected_skill),
      source_scope: Map.get(metadata, :source_scope),
      trust_status: Map.get(metadata, :trust_status),
      capability_contract: Map.get(metadata, :capability_contract)
    }
  end

  defp capability_contract(context) do
    context
    |> Map.get(:skill_metadata, %{})
    |> Map.get(:capability_contract, %{})
  end

  defp source_signal_id(context) do
    Map.get(context, :runner_requested_signal_id) ||
      get_in(context, [:request, :input_signal_id])
  end

  defp source_trace_id(context) do
    Map.get(context, :trace_id) ||
      get_in(context, [:request, :trace_id])
  end

  defp runner_metadata(context) do
    %{
      requested_signal_id: Map.get(context, :runner_requested_signal_id),
      selected_skill: Map.get(context, :selected_skill),
      selected_action: Map.get(context, :selected_action),
      action_capability: Map.get(context, :action_capability)
    }
  end
end
