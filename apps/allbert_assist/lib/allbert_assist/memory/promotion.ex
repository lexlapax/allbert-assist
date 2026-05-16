defmodule AllbertAssist.Memory.Promotion do
  @moduledoc """
  Converts an explicitly selected conversation message into memory attrs.
  """

  alias AllbertAssist.Conversations
  alias AllbertAssist.Conversations.Message

  @max_body_bytes 2_000

  @spec from_thread_message(String.t(), String.t(), String.t(), map()) ::
          {:ok, map()} | {:error, term()}
  def from_thread_message(user_id, thread_id, message_id, attrs \\ %{})

  def from_thread_message(user_id, thread_id, message_id, attrs)
      when is_binary(user_id) and is_binary(thread_id) and is_binary(message_id) and is_map(attrs) do
    with {:ok, %{messages: messages}} <- Conversations.show_thread(user_id, thread_id, limit: 100),
         {:ok, %Message{} = message} <- find_message(messages, message_id) do
      {:ok,
       %{
         category: category(attrs),
         body: body(message),
         summary: summary(message, attrs),
         source_signal_id: message.input_signal_id || message.response_signal_id || message.id,
         actor: user_id,
         agent: "AllbertAssist.Memory.Promotion",
         channel: "conversation",
         promotion: %{
           thread_id: thread_id,
           message_id: message_id,
           role: message.role,
           trace_id: message.trace_id
         }
       }}
    end
  end

  def from_thread_message(_user_id, _thread_id, _message_id, _attrs),
    do: {:error, :invalid_promotion_request}

  defp find_message(messages, message_id) do
    case Enum.find(messages, &(&1.id == message_id)) do
      %Message{} = message -> {:ok, message}
      nil -> {:error, {:message_not_found, message_id}}
    end
  end

  defp category(attrs) do
    case Map.get(attrs, :category, Map.get(attrs, "category", :notes)) do
      category when category in [:notes, :preferences, :traces, :skills] ->
        category

      category when is_binary(category) ->
        String.to_existing_atom(category)

      _other ->
        :notes
    end
  rescue
    ArgumentError -> :notes
  end

  defp summary(message, attrs) do
    case Map.get(attrs, :summary, Map.get(attrs, "summary")) do
      summary when is_binary(summary) and summary != "" ->
        String.slice(String.trim(summary), 0, 96)

      _other ->
        message.content
        |> String.replace(~r/\s+/, " ")
        |> String.trim()
        |> String.slice(0, 96)
    end
  end

  defp body(%Message{} = message) do
    message.content
    |> String.slice(0, @max_body_bytes)
  end
end
