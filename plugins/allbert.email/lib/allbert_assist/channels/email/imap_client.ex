defmodule AllbertAssist.Channels.Email.ImapClient do
  @moduledoc false

  @timeout 10_000

  defstruct [:socket]

  def connect(host, port, opts) do
    if Keyword.get(opts, :ssl, true) do
      ssl_opts = [
        :binary,
        active: false,
        verify: Keyword.get(opts, :verify, :verify_none)
      ]

      case :ssl.connect(to_charlist(host), port, ssl_opts, @timeout) do
        {:ok, socket} -> {:ok, %__MODULE__{socket: socket}}
        {:error, reason} -> {:error, reason}
      end
    else
      {:error, :plaintext_imap_rejected}
    end
  end

  def login(%__MODULE__{} = conn, username, password) do
    # `command/2` returns `{:ok, conn, response}`, but callers (Adapter, Doctor)
    # and the public client contract only need `{:ok, conn}` like `connect/3`.
    # The login response is not consumed; collapse to the 2-tuple so the real
    # client matches every caller and stub.
    with {:ok, conn, _response} <-
           command(conn, ~s(LOGIN "#{escape(username)}" "#{escape(password)}")) do
      {:ok, conn}
    end
  end

  def select_mailbox(%__MODULE__{} = conn, mailbox) do
    with {:ok, conn, _response} <- command(conn, ~s(SELECT "#{escape(mailbox)}")) do
      {:ok, conn}
    end
  end

  def search_unseen(%__MODULE__{} = conn) do
    with {:ok, _conn, response} <- command(conn, "SEARCH UNSEEN") do
      {:ok, search_uids(response)}
    end
  end

  defp search_uids(response) do
    response
    |> String.split(["\r\n", "\n"])
    |> Enum.find_value([], &search_uids_from_line/1)
  end

  defp search_uids_from_line(line) do
    case String.split(String.trim(line), " ") do
      ["*", "SEARCH" | ids] -> ids
      _other -> nil
    end
  end

  def fetch_message(%__MODULE__{} = conn, uid) do
    with {:ok, _conn, response} <- command(conn, "FETCH #{uid} BODY.PEEK[]") do
      {:ok, response}
    end
  end

  def mark_seen(%__MODULE__{} = conn, uid) do
    with {:ok, _conn, _response} <- command(conn, "STORE #{uid} +FLAGS (\\Seen)") do
      :ok
    end
  end

  def logout(%__MODULE__{socket: socket}) do
    :ssl.close(socket)
    :ok
  end

  # IMAP IDLE placeholder: a future idle/2 function can hold this connection
  # open and invoke a callback on EXISTS notifications. Polling remains the
  # only v0.16 behavior.

  defp command(%__MODULE__{} = conn, command) do
    tag_name = "A#{System.unique_integer([:positive])}"

    with :ok <- :ssl.send(conn.socket, "#{tag_name} #{command}\r\n"),
         {:ok, response} <- recv_until_tag(conn.socket, tag_name, "") do
      if String.contains?(response, "#{tag_name} OK") do
        {:ok, conn, response}
      else
        {:error, {:imap_command_failed, sanitize_response(response)}}
      end
    end
  end

  defp recv_until_tag(socket, tag_name, acc) do
    case :ssl.recv(socket, 0, @timeout) do
      {:ok, chunk} ->
        acc = acc <> chunk

        if String.contains?(acc, "#{tag_name} ") do
          {:ok, acc}
        else
          recv_until_tag(socket, tag_name, acc)
        end

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp escape(value) do
    value
    |> to_string()
    |> String.replace("\\", "\\\\")
    |> String.replace("\"", "\\\"")
  end

  defp sanitize_response(response), do: response |> to_string() |> String.slice(0, 500)
end
