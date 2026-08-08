defmodule AllbertAssist.Actions.Conversations.PersistAttachedFanoutReport do
  @moduledoc """
  Ensure the canonical conversation message for one attached Web fan-in report.

  The action is the write/authority boundary between `WorkspaceLive` and the
  durable fan-out/conversation models. It re-proves server-derived ownership,
  exact Web origin, authoritative join truth, and report identity on every
  call. Persistence is idempotent and deliberately does not acknowledge the
  delivery receipt; only the browser-mounted marker may do that.
  """

  use AllbertAssist.Action,
    registry_order: 202,
    permission: :conversation_write,
    exposure: :internal,
    execution_mode: :conversation_control,
    skill_backed?: false,
    confirmation: :not_required,
    retry_safety: :safe,
    name: "persist_attached_fanout_report",
    description: "Ensure one canonical assistant message for an owned Web fan-in report.",
    category: "conversations",
    tags: ["conversations", "objectives", "fanout", "write"],
    schema: [
      thread_id: [type: :string, required: true],
      parent_id: [type: :string, required: true],
      user_id: [type: :string, required: false]
    ],
    output_schema: [
      message: [type: :string, required: true],
      status: [type: :atom, required: true],
      parent_id: [type: :string, required: true],
      canonical_message_id: [type: :string, required: true],
      report_body: [type: :string, required: true],
      report_delivery_receipt: [type: :string, required: true],
      delivery_context: [type: :map, required: true],
      acknowledgement_required?: [type: :boolean, required: true],
      permission_decision: [type: :map, required: true],
      actions: [type: {:list, :map}, required: true]
    ]

  alias AllbertAssist.Actions.Jobs.Identity
  alias AllbertAssist.Conversations
  alias AllbertAssist.Objectives
  alias AllbertAssist.Objectives.Fanout
  alias AllbertAssist.Runtime.Response
  alias AllbertAssist.Security

  @permission :conversation_write
  @action_name "persist_attached_fanout_report"
  @allowed_delivery_states ~w[pending delivered]

  @impl true
  def run(params, context) when is_map(params) do
    permission_decision = Security.authorize(@permission, context)

    with {:allowed, true} <- {:allowed, Security.allowed?(permission_decision)},
         {:ok, user_id} <- Identity.user_id(%{}, context),
         {:ok, thread_id} <- required_param(params, :thread_id, :missing_thread_id),
         {:ok, parent_id} <- required_param(params, :parent_id, :missing_parent_id),
         {:ok, thread} <- Conversations.get_thread(user_id, thread_id),
         {:ok, parent} <- Objectives.get_objective(user_id, parent_id),
         :ok <- validate_parent(parent, thread.id),
         %{phase: :joined, authoritatively_joined?: true} = projection <-
           Fanout.parent_projection(parent),
         report = Fanout.report(projection),
         report_body = Fanout.format_report(report),
         {:ok, persisted} <-
           Conversations.ensure_assistant_message(
             thread,
             Conversations.fanout_report_message_id(parent.id),
             report_body,
             message_attrs(parent)
           ) do
      delivery_context = delivery_context(parent)

      {:ok,
       %{
         message: "Recorded the Web fan-in report on the conversation.",
         status: :completed,
         parent_id: parent.id,
         canonical_message_id: persisted.id,
         report_body: report_body,
         report_delivery_receipt: Fanout.receipt_for(:report, parent.id),
         delivery_context: delivery_context,
         acknowledgement_required?: parent.report_delivery_state == "pending",
         permission_decision: permission_decision,
         actions: [
           %{
             name: @action_name,
             status: :completed,
             permission: @permission,
             permission_decision: permission_decision,
             user_id: user_id,
             thread_id: thread.id,
             parent_id: parent.id,
             canonical_message_id: persisted.id
           }
         ]
       }}
    else
      {:allowed, false} ->
        {:ok, denied_response(permission_decision)}

      %{phase: phase} ->
        {:ok, error_response({:fanout_not_joined, phase}, permission_decision)}

      {:error, reason} ->
        {:ok, error_response(reason, permission_decision)}
    end
  end

  defp validate_parent(parent, thread_id) do
    cond do
      parent.fanout_role != "parent" ->
        {:error, :not_fanout_parent}

      parent.source_thread_id != thread_id ->
        {:error, :origin_thread_mismatch}

      parent.source_channel != "live_view" ->
        {:error, :not_attached_web_origin}

      parent.report_delivery_state not in @allowed_delivery_states ->
        {:error, {:report_not_ready, parent.report_delivery_state}}

      true ->
        :ok
    end
  end

  defp message_attrs(parent) do
    %{
      action_log: %{
        status: "completed",
        actions: [%{name: @action_name, status: "completed"}]
      },
      metadata: %{
        kind: "fanout_join_report",
        parent_objective_id: parent.id,
        channel: "live_view",
        source_thread_id: parent.source_thread_id
      }
    }
  end

  defp delivery_context(parent) do
    %{
      user_id: parent.user_id,
      channel: parent.source_channel,
      thread_id: parent.source_thread_id,
      origin_thread_ref_id: parent.origin_thread_ref_id,
      origin_thread_ref_digest: parent.origin_thread_ref_digest,
      origin_receiver_account_ref: parent.origin_receiver_account_ref
    }
    |> Enum.reject(fn {_key, value} -> is_nil(value) end)
    |> Map.new()
  end

  defp required_param(params, key, missing) do
    with value when is_binary(value) <- Identity.field(params, key),
         trimmed when trimmed != "" <- String.trim(value) do
      {:ok, trimmed}
    else
      _other -> {:error, missing}
    end
  end

  defp denied_response(permission_decision) do
    %{
      message: permission_decision.reason,
      status: Response.permission_status(permission_decision),
      permission_decision: permission_decision,
      actions: [
        %{
          name: @action_name,
          status: :denied,
          permission: @permission,
          permission_decision: permission_decision
        }
      ]
    }
  end

  defp error_response(reason, permission_decision) do
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
    }
  end

  defp error_message(:missing_user_id), do: "No user identity available for the write."
  defp error_message(:missing_thread_id), do: "A thread id is required."
  defp error_message(:missing_parent_id), do: "A fan-out parent id is required."
  defp error_message(:not_found), do: "Fan-out parent not found for this user."
  defp error_message({:thread_not_found, _id}), do: "Thread not found for this user."
  defp error_message(:not_fanout_parent), do: "The objective is not a fan-out parent."
  defp error_message(:origin_thread_mismatch), do: "The fan-out belongs to another thread."
  defp error_message(:not_attached_web_origin), do: "The fan-out did not originate in Web."
  defp error_message({:report_not_ready, _state}), do: "The fan-out report is not ready."
  defp error_message({:fanout_not_joined, _phase}), do: "The fan-out has not joined."
  defp error_message(reason), do: "Fan-in report persistence failed: #{inspect(reason)}"
end
