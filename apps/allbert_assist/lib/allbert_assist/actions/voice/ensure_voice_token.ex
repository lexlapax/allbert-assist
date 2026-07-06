defmodule AllbertAssist.Actions.Voice.EnsureVoiceToken do
  @moduledoc """
  Ensure the Allbert-owned local voice runtime authority token exists, through
  the action spine (v0.62 M8.15).

  `Auth.ensure_token!/0` is a mutation on first use: when no token file exists it
  generates a fresh token and persists it (`File.write!` + `chmod 0600`), so it
  must run through the Runner (PermissionGate + audit) rather than a direct call.
  On subsequent calls it is idempotent (returns the existing token). The raw
  token rides back under a `token`-named field so the CLI can print it; that
  field name is redacted by `AllbertAssist.Security.Redactor` in every logged
  signal and audit record. Action metadata carries only the token path and a
  redacted placeholder — never the raw token.
  """

  use AllbertAssist.Action,
    permission: :voice_local_runtime_manage,
    exposure: :internal,
    execution_mode: :voice_token,
    skill_backed?: false,
    confirmation: :not_required,
    name: "ensure_voice_token",
    description: "Ensure the local voice runtime authority token exists (local runtime manage).",
    category: "voice",
    tags: ["voice", "local_runtime", "token", "internal"],
    schema: [],
    output_schema: [
      message: [type: :string, required: true],
      status: [type: :atom, required: true],
      permission_decision: [type: :map, required: true],
      token: [type: :string, required: false],
      actions: [type: {:list, :map}, required: true]
    ]

  alias AllbertAssist.Security.PermissionGate
  alias AllbertAssist.Voice.LocalRuntime.Auth

  @permission :voice_local_runtime_manage

  @impl true
  def run(_params, context) do
    permission_decision = PermissionGate.authorize(@permission, context)

    if PermissionGate.allowed?(permission_decision) do
      ensure(permission_decision)
    else
      denied(permission_decision, :permission_denied)
    end
  end

  defp ensure(permission_decision) do
    completed(Auth.ensure_token!(), permission_decision)
  rescue
    exception ->
      failed(permission_decision, {exception.__struct__, Exception.message(exception)})
  end

  defp completed(token, permission_decision) do
    {:ok,
     %{
       message: "Local voice runtime authority token is ready.",
       status: :completed,
       permission_decision: permission_decision,
       # The `token` key is redacted by the Redactor in every logged signal/audit;
       # the in-memory response keeps the raw value so the CLI can print it.
       token: token,
       actions: [action(:completed, permission_decision)]
     }}
  end

  defp denied(permission_decision, reason) do
    {:ok,
     %{
       message: permission_decision.reason,
       status: PermissionGate.response_status(permission_decision),
       permission_decision: permission_decision,
       error: reason,
       actions: [action(PermissionGate.response_status(permission_decision), permission_decision)]
     }}
  end

  defp failed(permission_decision, reason) do
    {:ok,
     %{
       message: "Local voice runtime authority token could not be ensured.",
       status: :failed,
       permission_decision: permission_decision,
       error: reason,
       actions: [action(:failed, permission_decision)]
     }}
  end

  # Only the token path and a redacted placeholder — never the raw token.
  defp action(status, permission_decision) do
    %{
      name: "ensure_voice_token",
      status: status,
      permission: @permission,
      permission_decision: permission_decision,
      voice_local_runtime: %{
        token_path: Auth.token_path(),
        token: "[REDACTED]"
      }
    }
  end
end
