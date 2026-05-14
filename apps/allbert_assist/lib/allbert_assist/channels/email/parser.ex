defmodule AllbertAssist.Channels.Email.Parser do
  @moduledoc false

  def parse_email(_raw_bytes), do: {:error, :not_implemented}
  def detect_command(_text_body), do: :regular_text
end
