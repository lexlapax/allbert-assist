defmodule AllbertAssist.Actions.Conversations.CompleteThread do
  @moduledoc """
  Complete one of the local operator's own conversation threads (v0.62 M8.15).

  Completing a thread is a mutation, so it rides the one spine: a registered
  action behind the existing `:conversation_write` permission with a
  server-derived identity (context ahead of params — a client cannot complete
  another user's thread via the request body). The thread is fetched
  ownership-scoped inside `Conversations.complete_thread/2`; the completed thread
  is returned so the CLI renders identically.
  """

  use AllbertAssist.Action,
    permission: :conversation_write,
    exposure: :internal,
    execution_mode: :conversation_control,
    skill_backed?: false,
    confirmation: :not_required,
    name: "complete_thread",
    description: "Complete a conversation thread owned by the local user.",
    category: "conversations",
    tags: ["conversations", "threads", "write"],
    schema: [
      thread_id: [type: :string, required: true],
      user_id: [type: :string, required: false]
    ],
    output_schema: [
      message: [type: :string, required: true],
      status: [type: :atom, required: true],
      permission_decision: [type: :map, required: true],
      thread: [type: :map, required: false],
      actions: [type: {:list, :map}, required: true]
    ]

  alias AllbertAssist.Actions.Jobs.Identity
  alias AllbertAssist.Conversations
  alias AllbertAssist.Security.PermissionGate

  @permission :conversation_write

  @impl true
  def run(params, context) when is_map(params) do
    permission_decision = PermissionGate.authorize(@permission, context)

    with {:allowed, true} <- {:allowed, PermissionGate.allowed?(permission_decision)},
         {:ok, user_id} <- Identity.user_id(%{}, context),
         {:ok, thread_id} <- required_param(params, :thread_id, :missing_thread_id),
         {:ok, thread} <- Conversations.complete_thread(user_id, thread_id) do
      {:ok, completed(permission_decision, user_id, thread)}
    else
      {:allowed, false} -> {:ok, denied(permission_decision)}
      {:error, reason} -> {:ok, errored(permission_decision, reason)}
    end
  end

  defp completed(permission_decision, user_id, thread) do
    %{
      message: "Completed thread #{thread.id}.",
      status: :completed,
      permission_decision: permission_decision,
      thread: %{id: thread.id, completed_at: thread.completed_at},
      actions: [
        %{
          name: "complete_thread",
          status: :completed,
          permission: @permission,
          permission_decision: permission_decision,
          user_id: user_id,
          thread_id: thread.id
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
          name: "complete_thread",
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
          name: "complete_thread",
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

  defp error_message(:missing_user_id), do: "No user identity available for the completion."
  defp error_message(:missing_thread_id), do: "A thread id is required."
  defp error_message({:thread_not_found, _id}), do: "Thread not found for this user."
  defp error_message(reason), do: "Thread completion failed: #{inspect(reason)}"
end
