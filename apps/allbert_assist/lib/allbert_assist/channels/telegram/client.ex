defmodule AllbertAssist.Channels.Telegram.Client do
  @moduledoc false

  def get_updates(_token, _offset, _timeout_seconds), do: {:error, :not_implemented}
  def send_message(_token, _chat_id, _text, _opts \\ []), do: {:error, :not_implemented}

  def answer_callback_query(_token, _callback_query_id, _text \\ nil),
    do: {:error, :not_implemented}
end
