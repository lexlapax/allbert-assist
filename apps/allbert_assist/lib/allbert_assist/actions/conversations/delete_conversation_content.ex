defmodule AllbertAssist.Actions.Conversations.DeleteConversationContent do
  @moduledoc """
  Destructively confirmed deletion of one canonical message or thread.

  The action owns no cascade logic. It derives the canonical operator identity,
  presents the content-free bound preview, and resumes the exact Repo operation
  through the generic confirmation path.
  """

  use AllbertAssist.Action,
    registry_order: 66,
    permission: :conversation_write,
    exposure: :internal,
    execution_mode: :conversation_delete,
    skill_backed?: false,
    confirmation: :required,
    resumable?: true,
    name: "delete_conversation_content",
    description: "Delete one exact canonical conversation message or thread after confirmation.",
    category: "conversations",
    tags: ["conversations", "delete", "destructive", "confirmation"],
    schema: [
      target_kind: [
        type: :any,
        required: true,
        doc: "Closed message | thread target; accepts the serialized confirmation form."
      ],
      target_id: [type: :string, required: true],
      user_id: [type: :string, required: false],
      expected_digest: [type: :string, required: false],
      preview_binding: [type: :string, required: false],
      key_ref: [type: :string, required: false],
      key_version: [type: :integer, required: false],
      message_count: [type: :integer, required: false],
      reference_count: [type: :integer, required: false],
      retained_thread_title?: [type: :boolean, required: false]
    ],
    output_schema: [
      message: [type: :string, required: true],
      status: [type: :atom, required: true],
      permission_decision: [type: :map, required: true],
      confirmation_id: [type: :string, required: false],
      preview: [type: :map, required: false],
      output_data: [type: :map, required: false],
      actions: [type: {:list, :map}, required: true]
    ]

  alias AllbertAssist.Actions.Jobs.Identity
  alias AllbertAssist.Confirmations
  alias AllbertAssist.Confirmations.Origin
  alias AllbertAssist.Conversations.Deletion
  alias AllbertAssist.Security.PermissionGate

  @action_name "delete_conversation_content"
  @permission :conversation_write

  @impl true
  def run(params, context) when is_map(params) do
    permission_decision = PermissionGate.authorize(@permission, context)

    with {:denied, false} <- {:denied, permission_decision.decision == :denied},
         {:ok, user_id} <- Identity.user_id(%{}, context),
         {:ok, target_kind} <- target_kind(params),
         {:ok, target_id} <- required_string(params, :target_id) do
      if approved_resume?(context) do
        delete_now(user_id, params, permission_decision)
      else
        preview_and_confirm(
          user_id,
          target_kind,
          target_id,
          value(params, :expected_digest),
          context,
          permission_decision
        )
      end
    else
      {:denied, true} -> {:ok, denied(permission_decision)}
      {:error, reason} -> {:ok, failed(permission_decision, reason)}
    end
  end

  def run(_params, context),
    do: {:ok, failed(PermissionGate.authorize(@permission, context), :invalid_params)}

  defp preview_and_confirm(
         user_id,
         target_kind,
         target_id,
         expected_digest,
         context,
         permission_decision
       ) do
    with {:ok, bound} <- Deletion.preview(user_id, target_kind, target_id, expected_digest),
         {:ok, confirmation} <- create_confirmation(bound, user_id, context, permission_decision) do
      preview = bound.preview
      confirmation_id = confirmation["id"] || confirmation[:id]

      {:ok,
       response_needs_confirmation(
         disclosure_message(preview, confirmation_id),
         %{
           permission_decision: permission_decision,
           confirmation: confirmation,
           confirmation_id: confirmation_id,
           preview: preview,
           actions: [action(:needs_confirmation, permission_decision, preview, confirmation_id)]
         }
       )}
    else
      {:error, reason} -> {:ok, failed(permission_decision, reason)}
    end
  end

  defp create_confirmation(bound, user_id, context, permission_decision) do
    preview = bound.preview

    Confirmations.create(
      %{
        origin: Origin.from_context(context, @action_name),
        target_action: %{name: @action_name, module: inspect(__MODULE__)},
        target_permission: @permission,
        target_execution_mode: :conversation_delete,
        security_decision: permission_decision,
        params_summary: Map.put(preview, :user_id, user_id),
        resume_params_ref: %{
          user_id: user_id,
          target_kind: preview.target_kind,
          target_id: preview.target_id,
          preview_binding: preview.preview_binding,
          key_ref: bound.key_ref,
          key_version: bound.key_version,
          message_count: preview.message_count,
          reference_count: preview.reference_count,
          retained_thread_title?: preview.retained_thread_title?
        }
      },
      context
    )
  end

  defp delete_now(user_id, params, permission_decision) do
    with :ok <- approved_user(params, user_id),
         {:ok, result} <- Deletion.delete_approved(user_id, params) do
      {:ok,
       %{
         message: result_message(result),
         status: :completed,
         permission_decision: permission_decision,
         output_data: result,
         actions: [action(:completed, permission_decision, result, nil)]
       }}
    else
      {:error, reason} ->
        {:ok, failed(permission_decision, reason)}
    end
  end

  defp approved_user(params, current_user_id) do
    case value(params, :user_id) do
      ^current_user_id -> :ok
      _other -> {:error, :unauthorized}
    end
  end

  defp disclosure_message(preview, confirmation_id) do
    retained =
      if preview.retained_thread_title?,
        do: " The existing thread title is retained.",
        else: " The thread title is deleted with the thread."

    "Confirmation #{confirmation_id} will delete #{preview.message_count} canonical message(s) " <>
      "and #{preview.reference_count} conversation reference row(s).#{retained} " <>
      "Memory claims, provider/server copies, exports, backups, snapshots, traces, filesystem " <>
      "remnants, and unknown plugin copies are not deleted."
  end

  defp result_message(%{outcome: :already_deleted, target_kind: kind, target_id: id}),
    do: "Canonical #{kind} #{id} was already deleted; downstream reconciliation was re-driven."

  defp result_message(%{target_kind: kind, target_id: id}),
    do: "Deleted canonical #{kind} #{id}; separately governed records were retained."

  defp denied(permission_decision) do
    %{
      message: permission_decision.reason,
      status: PermissionGate.response_status(permission_decision),
      permission_decision: permission_decision,
      actions: [action(:denied, permission_decision, nil, nil)]
    }
  end

  defp failed(permission_decision, reason) do
    %{
      message: error_message(reason),
      status: :failed,
      error: reason,
      permission_decision: permission_decision,
      actions: [action(:failed, permission_decision, %{error: reason}, nil)]
    }
  end

  defp action(status, permission_decision, data, confirmation_id) do
    %{
      name: @action_name,
      status: status,
      permission: @permission,
      permission_decision: permission_decision,
      confirmation_id: confirmation_id,
      metadata: data
    }
    |> Map.reject(fn {_key, value} -> is_nil(value) end)
  end

  defp target_kind(params) do
    case value(params, :target_kind) do
      value when value in [:message, "message"] -> {:ok, :message}
      value when value in [:thread, "thread"] -> {:ok, :thread}
      _other -> {:error, :invalid_target_kind}
    end
  end

  defp required_string(params, key) do
    case value(params, key) do
      value when is_binary(value) ->
        case String.trim(value) do
          "" -> {:error, :missing_target_id}
          value -> {:ok, value}
        end

      _other ->
        {:error, :missing_target_id}
    end
  end

  defp approved_resume?(%{confirmation: %{approved?: true}}), do: true
  defp approved_resume?(%{"confirmation" => %{"approved?" => true}}), do: true
  defp approved_resume?(_context), do: false
  defp value(map, key), do: Map.get(map, key, Map.get(map, Atom.to_string(key)))

  defp error_message(:not_found), do: "The canonical conversation target was not found."
  defp error_message(:stale), do: "The approved conversation deletion preview is stale."

  defp error_message({:live_dependency, blockers}),
    do: "The thread has live dependent work: #{inspect(blockers)}. Finish, cancel, or rehome it."

  defp error_message(:unauthorized),
    do: "The canonical conversation target is not owned by this operator."

  defp error_message(reason), do: "Conversation deletion failed: #{inspect(reason)}"
end
