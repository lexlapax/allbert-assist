defmodule AllbertAssist.Runtime.AttachTUIClientTest do
  use ExUnit.Case, async: false

  alias AllbertAssist.Paths
  alias AllbertAssist.Runtime.Attach
  alias AllbertAssist.Runtime.Attach.TUIProtocol

  @moduletag :app_env_serial

  @token String.duplicate("t", 43)
  @session_id :binary.copy(<<17>>, 32)
  @terminal %{columns: 100, rows: 30, color: :ansi256, unicode?: true}

  setup do
    saved_paths = Application.get_env(:allbert_assist, Paths)

    home =
      Path.join(
        System.tmp_dir!(),
        "allbert-tui-client-#{System.unique_integer([:positive])}"
      )

    Application.put_env(:allbert_assist, Paths, home: home)
    File.mkdir_p!(Attach.runtime_dir())
    File.write!(Attach.token_path(), @token <> "\n")
    socket_path = Attach.socket_path()

    on_exit(fn ->
      File.rm(socket_path)
      File.rm_rf!(home)

      if saved_paths,
        do: Application.put_env(:allbert_assist, Paths, saved_paths),
        else: Application.delete_env(:allbert_assist, Paths)
    end)

    :ok
  end

  test "opens a passive bounded session with the exact authenticated packet" do
    snapshot = snapshot_frame()
    {listen_socket, server} = serve_once(:erlang.term_to_binary(snapshot))

    assert {:ok, socket, ^snapshot, flow} =
             Attach.open_tui_session("  work  ", @terminal)

    assert flow.session_id == @session_id
    assert flow.last_received_seq == 1
    assert flow.ack_to_send == 1
    assert {:ok, [active: false]} = :inet.getopts(socket, [:active])

    :ok = :gen_tcp.close(socket)
    :ok = :gen_tcp.close(listen_socket)

    assert {request, {:error, :closed}} = Task.await(server, 2_000)

    assert request ==
             Attach.identity()
             |> Map.merge(%{
               kind: :tui_session,
               frame: :open,
               session_protocol: TUIProtocol.session_protocol(),
               token: @token,
               profile: "work",
               terminal: @terminal
             })
  end

  test "returns the exact open rejection and closes the rejected socket" do
    rejection = TUIProtocol.open_close(:already_attached, "A TUI session is already attached.")
    {listen_socket, server} = serve_once(:erlang.term_to_binary(rejection))

    assert {:error, {:open_rejected, :already_attached, "A TUI session is already attached."}} =
             Attach.open_tui_session("default", @terminal)

    :ok = :gen_tcp.close(listen_socket)
    assert {_request, {:error, :closed}} = Task.await(server, 2_000)
  end

  test "closes the socket when the initial response is malformed" do
    malformed = %{frame: :snapshot, unexpected: true}
    {listen_socket, server} = serve_once(:erlang.term_to_binary(malformed))

    assert {:error, :protocol_error} = Attach.open_tui_session("default", @terminal)

    :ok = :gen_tcp.close(listen_socket)
    assert {_request, {:error, :closed}} = Task.await(server, 2_000)
  end

  test "bounds the initial packet before allocating or decoding an oversized body" do
    {listen_socket, server} = serve_once(:binary.copy(<<0>>, 64 * 1_024 + 1))

    assert {:error, :frame_too_large} = Attach.open_tui_session("default", @terminal)

    :ok = :gen_tcp.close(listen_socket)
    assert {_request, {:error, :closed}} = Task.await(server, 2_000)
  end

  test "normalizes an absent daemon socket without starting a runtime" do
    refute File.exists?(Attach.socket_path())
    assert {:error, :not_available} = Attach.open_tui_session("default", @terminal)
    refute File.exists?(Attach.socket_path())
  end

  defp serve_once(response) do
    File.rm(Attach.socket_path())

    {:ok, listen_socket} =
      :gen_tcp.listen(0, [
        :binary,
        packet: 4,
        active: false,
        ifaddr: {:local, Attach.socket_path()}
      ])

    server =
      Task.async(fn ->
        {:ok, socket} = :gen_tcp.accept(listen_socket, 2_000)
        {:ok, payload} = :gen_tcp.recv(socket, 0, 2_000)
        request = :erlang.binary_to_term(payload, [:safe])
        :ok = :gen_tcp.send(socket, response)
        closed = :gen_tcp.recv(socket, 0, 2_000)
        :gen_tcp.close(socket)
        {request, closed}
      end)

    {listen_socket, server}
  end

  defp snapshot_frame do
    %{
      kind: :tui_session,
      session_protocol: 1,
      frame: :snapshot,
      session_id: @session_id,
      seq: 1,
      ack: 0,
      payload: %{render_revision: 0, state: :idle, lines: [], gap?: false}
    }
  end
end
