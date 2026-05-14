defmodule AllbertAssist.Channels.Email.SmtpClient do
  @moduledoc false

  def send(_from, _to, _subject, _body, _opts \\ []), do: {:error, :not_implemented}
end
