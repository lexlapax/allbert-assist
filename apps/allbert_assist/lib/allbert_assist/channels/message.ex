defmodule AllbertAssist.Channels.Message do
  @moduledoc """
  Normalized inbound message shape shared by channel adapters.
  """

  @enforce_keys [:channel, :provider, :direction, :content_type, :external_event_id]
  defstruct [
    :channel,
    :provider,
    :direction,
    :content_type,
    :external_event_id,
    :external_user_id,
    :external_chat_id,
    :external_message_id,
    :text,
    :command_data,
    :callback_data,
    :subject,
    :in_reply_to,
    :raw_summary,
    metadata: %{}
  ]

  @type t :: %__MODULE__{}

  def new(attrs) when is_map(attrs) do
    attrs =
      attrs
      |> Enum.map(fn {key, value} -> {normalize_key(key), value} end)
      |> Map.new()

    struct!(__MODULE__, attrs)
  end

  defp normalize_key(key) when is_atom(key), do: key
  defp normalize_key(key) when is_binary(key), do: String.to_existing_atom(key)
end
