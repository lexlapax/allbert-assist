defmodule AllbertAssist.Actions.Conversations.PersistApprovalMediaResponse do
  @moduledoc """
  Persist an assistant message recording an approval's media outputs
  (v0.62 M0.1 — the v0.61b audit's carried-in ticket).

  This was the one remaining direct context *write* from a LiveView
  (`WorkspaceLive` called `Conversations.get_thread/2` +
  `append_assistant_message/3` directly, pre-v0.61b). It now rides the
  registered-action spine: identity is server-derived (context ahead of
  params — the `rename_thread` precedent), the thread is fetched
  ownership-scoped, and the write appends exactly one assistant message with
  the caller-shaped (already redacted) action log and metadata.
  """

  use AllbertAssist.Action,
    permission: :conversation_write,
    exposure: :internal,
    execution_mode: :conversation_control,
    skill_backed?: false,
    confirmation: :not_required,
    name: "persist_approval_media_response",
    description:
      "Append an assistant message recording approval media outputs to an owned thread.",
    category: "conversations",
    tags: ["conversations", "threads", "write", "media"],
    schema: [
      thread_id: [type: :string, required: true],
      message: [type: :string, required: true],
      action_log: [type: :map, required: false],
      metadata: [type: :map, required: false],
      user_id: [type: :string, required: false]
    ],
    output_schema: [
      message: [type: :string, required: true],
      status: [type: :atom, required: true],
      permission_decision: [type: :map, required: true],
      actions: [type: {:list, :map}, required: true]
    ]

  alias AllbertAssist.Actions.Jobs.Identity
  alias AllbertAssist.Conversations
  alias AllbertAssist.Security.PermissionGate

  @permission :conversation_write
  @action_name "persist_approval_media_response"

  @impl true
  def run(params, context) when is_map(params) do
    permission_decision = PermissionGate.authorize(@permission, context)

    with {:allowed, true} <- {:allowed, PermissionGate.allowed?(permission_decision)},
         {:ok, user_id} <- Identity.user_id(%{}, context),
         {:ok, thread_id} <- required_param(params, :thread_id, :missing_thread_id),
         {:ok, message} <- required_param(params, :message, :missing_message),
         {:ok, thread} <- Conversations.get_thread(user_id, thread_id),
         {:ok, _persisted} <-
           Conversations.append_assistant_message(thread, message, %{
             action_log: Identity.field(params, :action_log) || %{},
             metadata: Identity.field(params, :metadata) || %{}
           }) do
      {:ok,
       %{
         message: "Recorded approval media response on the conversation.",
         status: :completed,
         permission_decision: permission_decision,
         actions: [
           %{
             name: @action_name,
             status: :completed,
             permission: @permission,
             permission_decision: permission_decision,
             user_id: user_id,
             thread_id: thread.id
           }
         ]
       }}
    else
      {:allowed, false} ->
        {:ok,
         %{
           message: permission_decision.reason,
           status: PermissionGate.response_status(permission_decision),
           permission_decision: permission_decision,
           actions: [
             %{
               name: @action_name,
               status: :denied,
               permission: @permission,
               permission_decision: permission_decision
             }
           ]
         }}

      {:error, reason} ->
        {:ok,
         %{
           message: error_message(reason),
           status: :error,
           error: reason,
           permission_decision: permission_decision,
           actions: [
             %{
               name: @action_name,
               status: :error,
               permission: @permission,
               permission_decision: permission_decision,
               error: reason
             }
           ]
         }}
    end
  end

  # Identity comes from the context only (empty params map): the schema accepts
  # a user_id param for interface parity, but it never scopes the write.
  defp required_param(params, key, missing) do
    with value when is_binary(value) <- Identity.field(params, key),
         trimmed when trimmed != "" <- String.trim(value) do
      {:ok, trimmed}
    else
      _other -> {:error, missing}
    end
  end

  defp error_message(:missing_user_id), do: "No user identity available for the write."
  defp error_message(:missing_thread_id), do: "A thread id is required."
  defp error_message(:missing_message), do: "A non-empty message is required."

  defp error_message({:thread_not_found, _id}),
    do: "Thread not found for this user."

  defp error_message(reason), do: "Persist failed: #{inspect(reason)}"
end
