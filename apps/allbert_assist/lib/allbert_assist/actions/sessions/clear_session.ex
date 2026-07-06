defmodule AllbertAssist.Actions.Sessions.ClearSession do
  @moduledoc """
  Clear one of the local operator's own session scratchpads (v0.62 M8.15).

  Session clearing is a mutation, so it rides the one spine: a registered
  action behind the existing `:conversation_write` permission with a
  server-derived identity (context ahead of params — a client cannot clear
  another user's session via the request body). The scratchpad is scoped by the
  derived `user_id`; the `%{removed?: boolean}` clear result is returned verbatim
  so the CLI renders identically.
  """

  use AllbertAssist.Action,
    permission: :conversation_write,
    exposure: :internal,
    execution_mode: :session_control,
    skill_backed?: false,
    confirmation: :not_required,
    name: "clear_session",
    description: "Clear a session scratchpad owned by the local user.",
    category: "sessions",
    tags: ["sessions", "session_control", "write"],
    schema: [
      session_id: [type: :string, required: true],
      user_id: [type: :string, required: false]
    ],
    output_schema: [
      message: [type: :string, required: true],
      status: [type: :atom, required: true],
      permission_decision: [type: :map, required: true],
      result: [type: :map, required: false],
      actions: [type: {:list, :map}, required: true]
    ]

  alias AllbertAssist.Actions.Jobs.Identity
  alias AllbertAssist.Security.PermissionGate
  alias AllbertAssist.Session

  @permission :conversation_write

  @impl true
  def run(params, context) when is_map(params) do
    permission_decision = PermissionGate.authorize(@permission, context)

    with {:allowed, true} <- {:allowed, PermissionGate.allowed?(permission_decision)},
         {:ok, user_id} <- Identity.user_id(%{}, context),
         {:ok, session_id} <- required_param(params, :session_id, :missing_session_id),
         {:ok, result} <- Session.clear(user_id, session_id) do
      {:ok, completed(permission_decision, user_id, session_id, result)}
    else
      {:allowed, false} -> {:ok, denied(permission_decision)}
      {:error, reason} -> {:ok, errored(permission_decision, reason)}
    end
  end

  defp completed(permission_decision, user_id, session_id, result) do
    %{
      message: "Session #{user_id}/#{session_id} cleared (removed=#{result.removed?}).",
      status: :completed,
      permission_decision: permission_decision,
      result: result,
      actions: [
        %{
          name: "clear_session",
          status: :completed,
          permission: @permission,
          permission_decision: permission_decision,
          user_id: user_id,
          session_id: session_id
        }
      ]
    }
  end

  defp denied(permission_decision) do
    %{
      message: permission_decision.reason,
      status: PermissionGate.response_status(permission_decision),
      permission_decision: permission_decision,
      actions: [
        %{
          name: "clear_session",
          status: :denied,
          permission: @permission,
          permission_decision: permission_decision
        }
      ]
    }
  end

  defp errored(permission_decision, reason) do
    %{
      message: error_message(reason),
      status: :error,
      error: reason,
      permission_decision: permission_decision,
      actions: [
        %{
          name: "clear_session",
          status: :error,
          permission: @permission,
          permission_decision: permission_decision,
          error: reason
        }
      ]
    }
  end

  defp required_param(params, key, missing) do
    with value when is_binary(value) <- Identity.field(params, key),
         trimmed when trimmed != "" <- String.trim(value) do
      {:ok, trimmed}
    else
      _other -> {:error, missing}
    end
  end

  defp error_message(:missing_user_id), do: "No user identity available for the session clear."
  defp error_message(:missing_session_id), do: "A session id is required."
  defp error_message(reason), do: "Session clear failed: #{inspect(reason)}"
end
