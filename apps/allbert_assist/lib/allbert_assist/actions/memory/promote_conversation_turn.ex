defmodule AllbertAssist.Actions.Memory.PromoteConversationTurn do
  @moduledoc "Promotes one explicitly selected conversation turn to markdown memory."

  use AllbertAssist.Action,
    permission: :memory_write,
    exposure: :internal,
    execution_mode: :memory_promotion,
    skill_backed?: false,
    confirmation: :required,
    resumable?: true,
    name: "promote_conversation_turn",
    description: "Promote one user-owned conversation message to markdown memory.",
    category: "memory",
    tags: ["memory", "conversation", "confirmation"],
    schema: [
      user_id: [type: :string, required: false],
      thread_id: [type: :string, required: true],
      message_id: [type: :string, required: true],
      category: [type: :string, required: false],
      summary: [type: :string, required: false]
    ],
    output_schema: [
      message: [type: :string, required: true],
      status: [type: :atom, required: true],
      permission_decision: [type: :map, required: true],
      confirmation_id: [type: :string, required: false],
      memory: [type: :map, required: false],
      actions: [type: {:list, :map}, required: true]
    ]

  alias AllbertAssist.Actions.Memory.Context
  alias AllbertAssist.Confirmations
  alias AllbertAssist.Memory
  alias AllbertAssist.Memory.Promotion
  alias AllbertAssist.Security.PermissionGate
  alias AllbertAssist.Settings

  @impl true
  def run(params, context) when is_map(params) do
    permission_decision = PermissionGate.authorize(:memory_write, context)

    with {:allowed, true} <- {:allowed, PermissionGate.allowed?(permission_decision)},
         {:ok, user_id} <- Context.user_id(params, context),
         {:ok, thread_id} <- required(params, :thread_id),
         {:ok, message_id} <- required(params, :message_id),
         {:ok, attrs} <- Promotion.from_thread_message(user_id, thread_id, message_id, params) do
      cond do
        approval_resume?(context) ->
          append_memory(attrs, permission_decision, :approval)

        confirmation_required?() ->
          create_confirmation(attrs, user_id, thread_id, message_id, context, permission_decision)

        true ->
          append_memory(attrs, permission_decision, :immediate)
      end
    else
      {:allowed, false} -> denied(permission_decision)
      {:error, reason} -> error(permission_decision, reason)
    end
  end

  defp append_memory(attrs, permission_decision, execution) do
    case Memory.append(attrs) do
      {:ok, entry} ->
        {:ok,
         %{
           message: "Promoted conversation turn to memory: #{entry.summary}",
           status: :completed,
           permission_decision: permission_decision,
           memory: entry,
           actions: [
             %{
               name: "promote_conversation_turn",
               status: :completed,
               permission: :memory_write,
               permission_decision: permission_decision,
               execution: execution,
               memory_path: entry.path,
               memory_category: entry.category
             }
           ]
         }}

      {:error, reason} ->
        error(permission_decision, reason)
    end
  end

  defp create_confirmation(attrs, user_id, thread_id, message_id, context, permission_decision) do
    preview = attrs.body |> String.replace(~r/\s+/, " ") |> String.slice(0, 240)

    case Confirmations.create(%{
           origin: origin(context, user_id),
           target_action: %{name: "promote_conversation_turn", module: inspect(__MODULE__)},
           target_permission: :memory_write,
           target_execution_mode: :memory_promotion,
           security_decision: permission_decision,
           params_summary: %{
             user_id: user_id,
             thread_id: thread_id,
             message_id: message_id,
             category: attrs.category,
             summary: attrs.summary,
             body_preview: preview
           },
           resume_params_ref: %{
             user_id: user_id,
             thread_id: thread_id,
             message_id: message_id,
             category: attrs.category,
             summary: attrs.summary
           }
         }) do
      {:ok, confirmation} ->
        {:ok,
         %{
           message:
             "Conversation turn promotion is ready for approval. Confirmation request: #{confirmation["id"]}. No memory was written.",
           status: :needs_confirmation,
           permission_decision: permission_decision,
           confirmation: confirmation,
           confirmation_id: confirmation["id"],
           actions: [
             %{
               name: "promote_conversation_turn",
               status: :needs_confirmation,
               permission: :memory_write,
               permission_decision: permission_decision,
               execution: :pending_confirmation,
               confirmation_id: confirmation["id"],
               thread_id: thread_id,
               message_id: message_id,
               user_id: user_id
             }
           ]
         }}

      {:error, reason} ->
        error(permission_decision, reason)
    end
  end

  defp denied(permission_decision) do
    {:ok,
     %{
       message: permission_decision.reason,
       status: PermissionGate.response_status(permission_decision),
       permission_decision: permission_decision,
       actions: [action(:denied, permission_decision, nil)]
     }}
  end

  defp error(permission_decision, reason) do
    {:ok,
     %{
       message: "Unable to promote conversation turn: #{inspect(reason)}",
       status: :error,
       error: reason,
       permission_decision: permission_decision,
       actions: [action(:error, permission_decision, reason)]
     }}
  end

  defp action(status, permission_decision, error) do
    %{
      name: "promote_conversation_turn",
      status: status,
      permission: :memory_write,
      permission_decision: permission_decision,
      error: error
    }
    |> Enum.reject(fn {_key, value} -> is_nil(value) end)
    |> Map.new()
  end

  defp required(params, key) do
    case Map.get(params, key) || Map.get(params, Atom.to_string(key)) do
      value when is_binary(value) and value != "" -> {:ok, value}
      _value -> {:error, {:missing_required, key}}
    end
  end

  defp confirmation_required? do
    case Settings.get("memory.promotion_requires_confirmation") do
      {:ok, false} -> false
      _other -> true
    end
  end

  defp approval_resume?(%{confirmation: %{approved?: true}}), do: true
  defp approval_resume?(%{"confirmation" => %{"approved?" => true}}), do: true
  defp approval_resume?(_context), do: false

  defp origin(context, user_id) do
    %{
      channel: Map.get(context, :channel, :unknown),
      actor: Map.get(context, :actor, user_id),
      user_id: user_id,
      session_id: Map.get(context, :session_id),
      surface: Map.get(context, :surface, "action")
    }
  end
end
