defmodule AllbertAssist.Actions.Sessions.SweepExpiredSessions do
  @moduledoc """
  Sweep expired session scratchpads (v0.62 M8.15).

  Sweeping evicts expired sessions, so it rides the one spine: a registered
  action behind the existing `:conversation_write` permission. The sweep spans
  every session (`Session.sweep_expired/0` takes no user), so identity is only
  used for the audit trail — the removed count is returned so the CLI renders
  identically.
  """

  use AllbertAssist.Action,
    permission: :conversation_write,
    exposure: :internal,
    execution_mode: :session_control,
    skill_backed?: false,
    confirmation: :not_required,
    name: "sweep_expired_sessions",
    description: "Remove expired session scratchpads.",
    category: "sessions",
    tags: ["sessions", "session_control", "write"],
    schema: [
      user_id: [type: :string, required: false]
    ],
    output_schema: [
      message: [type: :string, required: true],
      status: [type: :atom, required: true],
      permission_decision: [type: :map, required: true],
      count: [type: :integer, required: false],
      actions: [type: {:list, :map}, required: true]
    ]

  alias AllbertAssist.Actions.Jobs.Identity
  alias AllbertAssist.Security.PermissionGate
  alias AllbertAssist.Session

  @permission :conversation_write

  @impl true
  def run(_params, context) when is_map(context) do
    permission_decision = PermissionGate.authorize(@permission, context)

    with {:allowed, true} <- {:allowed, PermissionGate.allowed?(permission_decision)},
         {:ok, count} <- Session.sweep_expired() do
      {:ok, completed(permission_decision, context, count)}
    else
      {:allowed, false} -> {:ok, denied(permission_decision)}
      {:error, reason} -> {:ok, errored(permission_decision, reason)}
    end
  end

  defp completed(permission_decision, context, count) do
    %{
      message: "Expired sessions removed=#{count}.",
      status: :completed,
      permission_decision: permission_decision,
      count: count,
      actions: [
        %{
          name: "sweep_expired_sessions",
          status: :completed,
          permission: @permission,
          permission_decision: permission_decision,
          user_id: operator_id(context),
          count: count
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
          name: "sweep_expired_sessions",
          status: :denied,
          permission: @permission,
          permission_decision: permission_decision
        }
      ]
    }
  end

  defp errored(permission_decision, reason) do
    %{
      message: "Session sweep failed: #{inspect(reason)}",
      status: :error,
      error: reason,
      permission_decision: permission_decision,
      actions: [
        %{
          name: "sweep_expired_sessions",
          status: :error,
          permission: @permission,
          permission_decision: permission_decision,
          error: reason
        }
      ]
    }
  end

  defp operator_id(context) do
    case Identity.user_id(%{}, context) do
      {:ok, user_id} -> user_id
      {:error, _reason} -> nil
    end
  end
end
