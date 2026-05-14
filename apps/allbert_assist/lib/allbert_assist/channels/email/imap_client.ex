defmodule AllbertAssist.Channels.Email.ImapClient do
  @moduledoc false

  def connect(_host, _port, _opts), do: {:error, :not_implemented}
  def login(_conn, _username, _password), do: {:error, :not_implemented}
  def select_mailbox(_conn, _mailbox), do: {:error, :not_implemented}
  def search_unseen(_conn), do: {:error, :not_implemented}
  def fetch_message(_conn, _uid), do: {:error, :not_implemented}
  def mark_seen(_conn, _uid), do: {:error, :not_implemented}
  def logout(_conn), do: :ok
end
