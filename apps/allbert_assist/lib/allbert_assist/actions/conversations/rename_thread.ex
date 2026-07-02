defmodule AllbertAssist.Actions.Conversations.RenameThread do
  @moduledoc """
  Rename one of the local operator's own conversation threads (v0.61b M4).

  Identity is server-derived (context ahead of params — the jobs/objectives
  precedence, so a client cannot rename another user's thread via the request
  body); the thread is fetched ownership-scoped via `Conversations.get_thread/2`;
  only the persisted `title` field value changes. The v0.58 no-internal-rename
  invariant (Thread modules/atoms/topics/keys) is untouched.
  """

  use AllbertAssist.Action,
    permission: :conversation_write,
    exposure: :internal,
    execution_mode: :conversation_control,
    skill_backed?: false,
    confirmation: :not_required,
    name: "rename_thread",
    description: "Rename a conversation thread owned by the local user.",
    category: "conversations",
    tags: ["conversations", "threads", "write"],
    schema: [
      thread_id: [type: :string, required: true],
      title: [type: :string, required: true],
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
         {:ok, title} <- required_param(params, :title, :missing_title),
         {:ok, thread} <- Conversations.rename_thread(user_id, thread_id, title) do
      {:ok,
       %{
         message: "Renamed thread to #{thread.title}.",
         status: :completed,
         permission_decision: permission_decision,
         thread: %{id: thread.id, title: thread.title},
         actions: [
           %{
             name: "rename_thread",
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
               name: "rename_thread",
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
               name: "rename_thread",
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
  # a user_id param for interface parity, but it never scopes the rename.
  defp required_param(params, key, missing) do
    with value when is_binary(value) <- Identity.field(params, key),
         trimmed when trimmed != "" <- String.trim(value) do
      {:ok, trimmed}
    else
      _other -> {:error, missing}
    end
  end

  defp error_message(:missing_user_id), do: "No user identity available for the rename."
  defp error_message(:missing_thread_id), do: "A thread id is required."
  defp error_message(:missing_title), do: "A non-empty title is required."

  defp error_message({:thread_not_found, _id}),
    do: "Thread not found for this user."

  defp error_message(%Ecto.Changeset{} = changeset) do
    "Title rejected: #{inspect(changeset.errors)}"
  end

  defp error_message(reason), do: "Rename failed: #{inspect(reason)}"
end
