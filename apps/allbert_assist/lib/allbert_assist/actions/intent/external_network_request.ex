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

  alias AllbertAssist.Security.PermissionGate

  @impl true
  def run(%{request: request} = params, context) do
    request = String.trim(request)
    permission_decision = PermissionGate.authorize(:external_network, context)

    {:ok,
     %{
       message: message(request, permission_decision),
       status: PermissionGate.response_status(permission_decision),
       permission_decision: permission_decision,
       actions: [
         %{
           name: "external_network_request",
           status: :not_executed,
           permission: :external_network,
           permission_decision: permission_decision,
           execution: :not_available,
           input: %{request: request, source_text: Map.get(params, :source_text)}
         }
       ]
     }}
  end

  defp message(request, permission_decision) do
    """
    I will not use external network access from this milestone.

    Requested network task:
    #{request}

    Permission gate decision: #{permission_decision.decision} for external_network.
    A future confirmation flow must approve this before any adapter can make a request.
    """
    |> String.trim()
  end
end
