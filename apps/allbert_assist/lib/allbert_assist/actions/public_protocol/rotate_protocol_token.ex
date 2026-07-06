defmodule AllbertAssist.Actions.PublicProtocol.RotateProtocolToken do
  @moduledoc """
  Rotate a public-protocol bearer token through the action spine (v0.62 M8.15).

  Rotation mutates Settings-Secrets state (writes a fresh secret and disables
  the old one), so it runs through the Runner (PermissionGate + audit) instead
  of a direct `TokenAuth.rotate/3` call. The new raw token rides back under a
  `token`-named field inside `token_result` so the CLI can print it once; that
  field name is redacted by `AllbertAssist.Security.Redactor` in every logged
  signal and audit record. Action metadata carries only redacted/reference
  fields — never the raw token.
  """

  use AllbertAssist.Action,
    permission: :settings_secret_write,
    exposure: :internal,
    execution_mode: :public_protocol_token,
    skill_backed?: false,
    confirmation: :not_required,
    name: "rotate_protocol_token",
    description: "Rotate a public-protocol bearer token for a client (secret write).",
    category: "public_protocol",
    tags: ["public_protocol", "token", "secrets", "internal"],
    schema: [
      surface: [type: :string, required: true],
      client: [type: :string, required: true]
    ],
    output_schema: [
      message: [type: :string, required: true],
      status: [type: :atom, required: true],
      permission_decision: [type: :map, required: true],
      token_result: [type: :map, required: false],
      actions: [type: {:list, :map}, required: true]
    ]

  alias AllbertAssist.PublicProtocol.TokenAuth
  alias AllbertAssist.Security.PermissionGate

  @permission :settings_secret_write

  @impl true
  def run(%{surface: surface, client: client}, context) do
    permission_decision = PermissionGate.authorize(@permission, context)

    with true <- PermissionGate.allowed?(permission_decision),
         {:ok, result} <- TokenAuth.rotate(surface, client, context) do
      completed(result, permission_decision)
    else
      false -> denied(surface, client, permission_decision, :permission_denied)
      {:error, reason} -> failed(surface, client, permission_decision, reason)
    end
  end

  defp completed(result, permission_decision) do
    {:ok,
     %{
       message: "Rotated public protocol bearer token for #{result.surface}/#{result.client_id}.",
       status: :completed,
       permission_decision: permission_decision,
       # `token` inside `token_result` is redacted in logs/audit; the in-memory
       # response keeps the raw value so the CLI can print it once.
       token_result: result,
       actions: [action(:completed, permission_decision, result)]
     }}
  end

  defp denied(surface, client, permission_decision, reason) do
    {:ok,
     %{
       message:
         "Public protocol token rotation was denied for #{surface}/#{client}: #{inspect(reason)}",
       status: PermissionGate.response_status(permission_decision),
       permission_decision: permission_decision,
       error: reason,
       actions: [action(:denied, permission_decision, %{surface: surface, client_id: client})]
     }}
  end

  defp failed(surface, client, permission_decision, reason) do
    {:ok,
     %{
       message:
         "Public protocol token rotation failed for #{surface}/#{client}: #{inspect(reason)}",
       status: :failed,
       permission_decision: permission_decision,
       error: reason,
       actions: [action(:failed, permission_decision, %{surface: surface, client_id: client})]
     }}
  end

  # Only reference/redacted fields — never the raw token.
  defp action(status, permission_decision, result) do
    %{
      name: "rotate_protocol_token",
      status: status,
      permission: @permission,
      permission_decision: permission_decision,
      public_protocol_metadata: %{
        surface: Map.get(result, :surface),
        client_id: Map.get(result, :client_id),
        token_ref: Map.get(result, :token_ref),
        token: "[REDACTED]"
      }
    }
  end
end
