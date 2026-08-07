defmodule AllbertAssistWeb.LiveSocketTest do
  use AllbertAssistWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  alias AllbertAssist.Settings
  alias AllbertAssistWeb.PackReadiness

  @endpoint AllbertAssistWeb.Endpoint

  test "uses the one targeted readiness-disconnect socket topic" do
    assert AllbertAssistWeb.LiveSocket.id(%Phoenix.Socket{}) == "allbert_pack_readiness"
  end

  test "connect retains the exact admitted E1 after Phoenix LiveView connect-info setup" do
    assert {:ok, epoch} = PackReadiness.admit()

    assert {:ok, socket} =
             AllbertAssistWeb.LiveSocket.connect(
               %{},
               %Phoenix.Socket{private: %{}},
               %{session: %{"fixture" => true}}
             )

    assert socket.private.connect_info.session == %{"fixture" => true}
    assert socket.private.connect_info.allbert_pack_epoch == epoch
  end

  test "readiness disconnect closes the actual /live websocket with code 1001" do
    {:ok, server} =
      Bandit.start_link(
        plug: @endpoint,
        ip: {127, 0, 0, 1},
        port: 0,
        startup_log: false
      )

    on_exit(fn ->
      if Process.alive?(server) do
        try do
          Supervisor.stop(server)
        catch
          :exit, _reason -> :ok
        end
      end
    end)

    {:ok, {_address, port}} = ThousandIsland.listener_info(server)
    assert {:ok, _epoch} = PackReadiness.admit()
    {:ok, tcp} = websocket_connect(port)
    websocket_text(tcp, ["1", "1", "phoenix", "heartbeat", %{}])

    assert_eventually(fn ->
      Registry.lookup(AllbertAssist.PubSub, "allbert_pack_readiness") != []
    end)

    PackReadiness.disconnect()

    assert websocket_close_code(tcp, System.monotonic_time(:millisecond) + 2_000) == 1001
  end

  test "readiness-disconnect transport retirement terminates the old LiveView root and upload channel",
       %{conn: conn} do
    assert {:ok, _resolved} =
             Settings.put(
               "vision.enabled",
               true,
               AllbertAssist.TestSupport.ReadyEffectContext.attach(%{audit?: false})
             )

    assert {:ok, _setting} =
             Settings.put(
               "model_preferences.capabilities.vision_input",
               ["vision_fake"],
               AllbertAssist.TestSupport.ReadyEffectContext.attach(%{
                 audit?: false
               })
             )

    {:ok, view, _html} = live(conn, "/workspace")

    upload =
      file_input(view, "#agent-form", :image_input, [
        %{name: "loss.png", content: "image", type: "image/png"}
      ])

    _rendered = render_upload(upload, "loss.png", 1)
    %{"loss.png" => upload_pid} = Phoenix.LiveViewTest.UploadClient.channel_pids(upload)

    root_pid = view.pid
    root_ref = Process.monitor(root_pid)
    upload_ref = Process.monitor(upload_pid)
    previous_trap = Process.flag(:trap_exit, true)
    on_exit(fn -> Process.flag(:trap_exit, previous_trap) end)

    PackReadiness.disconnect()

    # LiveViewTest has no Phoenix.Socket transport process subscribed to the
    # socket ID, so apply the exact shutdown reason produced by that real
    # transport (proved by the preceding loopback test) to its root channel.
    Process.exit(root_pid, {:shutdown, :disconnected})

    assert_receive {:DOWN, ^root_ref, :process, ^root_pid, _reason}, 2_000
    assert_receive {:DOWN, ^upload_ref, :process, ^upload_pid, _reason}, 2_000
    refute Process.alive?(root_pid)
    refute Process.alive?(upload_pid)
  end

  defp websocket_connect(port) do
    {:ok, socket} =
      :gen_tcp.connect({127, 0, 0, 1}, port, [:binary, active: false, packet: :raw], 2_000)

    key = Base.encode64(:crypto.strong_rand_bytes(16))

    request = [
      "GET /live/websocket?vsn=2.0.0 HTTP/1.1\r\n",
      "Host: localhost:#{port}\r\n",
      "Origin: http://localhost:#{port}\r\n",
      "Upgrade: websocket\r\n",
      "Connection: Upgrade\r\n",
      "Sec-WebSocket-Key: #{key}\r\n",
      "Sec-WebSocket-Version: 13\r\n\r\n"
    ]

    :ok = :gen_tcp.send(socket, request)
    {:ok, response} = :gen_tcp.recv(socket, 0, 2_000)
    assert response =~ "HTTP/1.1 101"
    {:ok, socket}
  end

  defp websocket_close_code(socket, deadline, buffer \\ <<>>) do
    case take_websocket_frame(buffer) do
      {:ok, 8, payload, remaining} ->
        <<code::16, _reason::binary>> = payload
        # Parse all accumulated bytes even when a text reply and close frame are
        # coalesced; `remaining` is intentionally consumed by the parser above.
        _ = remaining
        code

      {:ok, _other_opcode, _payload, remaining} ->
        websocket_close_code(socket, deadline, remaining)

      :more ->
        timeout = max(deadline - System.monotonic_time(:millisecond), 0)
        if timeout == 0, do: flunk("timed out waiting for readiness WebSocket close frame")

        case :gen_tcp.recv(socket, 0, timeout) do
          {:ok, bytes} -> websocket_close_code(socket, deadline, buffer <> bytes)
          {:error, reason} -> flunk("WebSocket closed without a close frame: #{inspect(reason)}")
        end
    end
  end

  defp websocket_text(socket, message) do
    payload = Jason.encode!(message)
    mask = :crypto.strong_rand_bytes(4)

    masked =
      payload
      |> :binary.bin_to_list()
      |> Enum.with_index()
      |> Enum.map(fn {byte, index} -> Bitwise.bxor(byte, :binary.at(mask, rem(index, 4))) end)
      |> :binary.list_to_bin()

    :ok = :gen_tcp.send(socket, [<<0x81, 0x80 + byte_size(payload)>>, mask, masked])
  end

  defp take_websocket_frame(
         <<fin::1, _reserved::3, opcode::4, masked::1, length::7, rest::binary>>
       )
       when fin == 1 do
    with {:ok, payload_length, rest} <- extended_length(length, rest),
         {:ok, mask, rest} <- frame_mask(masked, rest),
         true <- byte_size(rest) >= payload_length do
      <<payload::binary-size(payload_length), remaining::binary>> = rest
      {:ok, opcode, unmask(payload, mask), remaining}
    else
      _incomplete -> :more
    end
  end

  defp take_websocket_frame(_incomplete), do: :more

  defp extended_length(length, rest) when length < 126, do: {:ok, length, rest}
  defp extended_length(126, <<length::16, rest::binary>>), do: {:ok, length, rest}
  defp extended_length(127, <<length::64, rest::binary>>), do: {:ok, length, rest}
  defp extended_length(_length, _incomplete), do: :more

  defp frame_mask(0, rest), do: {:ok, nil, rest}
  defp frame_mask(1, <<mask::binary-size(4), rest::binary>>), do: {:ok, mask, rest}
  defp frame_mask(1, _incomplete), do: :more

  defp unmask(payload, nil), do: payload

  defp unmask(payload, mask) do
    payload
    |> :binary.bin_to_list()
    |> Enum.with_index()
    |> Enum.map(fn {byte, index} -> Bitwise.bxor(byte, :binary.at(mask, rem(index, 4))) end)
    |> :binary.list_to_bin()
  end

  defp assert_eventually(fun, attempts \\ 100)
  defp assert_eventually(fun, 0), do: assert(fun.())

  defp assert_eventually(fun, attempts) do
    if fun.() do
      :ok
    else
      Process.sleep(10)
      assert_eventually(fun, attempts - 1)
    end
  end
end
