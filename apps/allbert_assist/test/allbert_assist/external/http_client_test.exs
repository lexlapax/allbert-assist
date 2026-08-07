defmodule AllbertAssist.External.HttpClientTest do
  use ExUnit.Case, async: false
  @moduletag :external_runtime_serial

  alias AllbertAssist.External.HttpClient
  alias AllbertAssist.External.RequestSpec
  alias AllbertAssist.Pack.EffectGuard
  alias AllbertAssist.Paths
  alias AllbertAssist.Settings

  defmodule Readiness do
    use GenServer

    def start_link(opts),
      do: GenServer.start_link(__MODULE__, :ok, name: Keyword.fetch!(opts, :name))

    def replace(server), do: GenServer.call(server, :replace)

    @impl true
    def init(:ok), do: {:ok, %{epoch: :e1, e1: spawn_epoch(), e2: spawn_epoch()}}

    @impl true
    def handle_call(:replace, _from, state), do: {:reply, :ok, %{state | epoch: :e2}}

    @impl true
    def handle_call(:status, _from, state) do
      {:reply,
       {:ok,
        %{
          phase: :ready,
          barrier_pid: Map.fetch!(state, state.epoch),
          snapshot_digest: String.duplicate("a", 64),
          expected_ids: [],
          subscribed_ids: [],
          acked_ids: [],
          diagnostics: []
        }}, state}
    end

    @impl true
    def terminate(_reason, state) do
      Process.exit(state.e1, :kill)
      Process.exit(state.e2, :kill)
    end

    defp spawn_epoch, do: spawn(fn -> Process.sleep(:infinity) end)
  end

  setup {Req.Test, :verify_on_exit!}

  setup do
    original_paths_config = Application.get_env(:allbert_assist, Paths)
    original_settings_config = Application.get_env(:allbert_assist, Settings)

    root =
      Path.join(
        System.tmp_dir!(),
        "allbert-external-http-client-#{System.unique_integer([:positive])}"
      )

    Application.put_env(:allbert_assist, Paths, home: root)
    Application.put_env(:allbert_assist, Settings, root: Path.join(root, "settings"))

    original_readiness = Process.whereis(AllbertAssist.Pack.Readiness)
    true = Process.unregister(AllbertAssist.Pack.Readiness)
    {:ok, readiness} = Readiness.start_link(name: AllbertAssist.Pack.Readiness)
    assert {:ok, epoch} = EffectGuard.admit_ready()
    configure_external(%{allbert_pack_epoch: epoch, audit?: false})

    on_exit(fn ->
      restore_env(Paths, original_paths_config)
      restore_env(Settings, original_settings_config)

      if Process.whereis(AllbertAssist.Pack.Readiness) == readiness,
        do: Process.unregister(AllbertAssist.Pack.Readiness)

      if Process.alive?(readiness), do: GenServer.stop(readiness)

      if Process.alive?(original_readiness) and
           is_nil(Process.whereis(AllbertAssist.Pack.Readiness)),
         do: Process.register(original_readiness, AllbertAssist.Pack.Readiness)

      File.rm_rf!(root)
    end)

    %{readiness: readiness}
  end

  test "executes through Req.Test and caps response body" do
    Req.Test.stub(__MODULE__, fn conn ->
      conn
      |> Plug.Conn.put_resp_header("set-cookie", "session=secret")
      |> Plug.Conn.send_resp(200, "hello world")
    end)

    assert {:ok, spec} =
             RequestSpec.normalize(%{url: "https://example.com/status", max_response_bytes: 5})

    assert {:ok, epoch} = EffectGuard.admit_ready()

    assert {:ok, result} =
             HttpClient.request(spec,
               plug: {Req.Test, __MODULE__},
               allbert_pack_epoch: epoch
             )

    assert result.status == :completed
    assert result.http_status == 200
    assert result.body_preview == "hello"
    assert result.truncated?

    assert Enum.any?(
             result.response_headers,
             &(&1.name == "set-cookie" and &1.value == "[REDACTED]")
           )
  end

  test "does not follow redirects by default" do
    Req.Test.expect(__MODULE__, fn conn ->
      conn
      |> Plug.Conn.put_resp_header("location", "https://example.com/other")
      |> Plug.Conn.send_resp(302, "redirect")
    end)

    assert {:ok, spec} = RequestSpec.normalize(%{url: "https://example.com/status"})
    assert {:ok, epoch} = EffectGuard.admit_ready()

    assert {:ok, result} =
             HttpClient.request(spec, plug: {Req.Test, __MODULE__}, allbert_pack_epoch: epoch)

    assert result.http_status == 302
  end

  test "does not retry by default" do
    Req.Test.expect(__MODULE__, fn conn ->
      Plug.Conn.send_resp(conn, 500, "server error")
    end)

    assert {:ok, spec} = RequestSpec.normalize(%{url: "https://example.com/status"})
    assert {:ok, epoch} = EffectGuard.admit_ready()

    assert {:ok, result} =
             HttpClient.request(spec, plug: {Req.Test, __MODULE__}, allbert_pack_epoch: epoch)

    assert result.status == :failed
    assert result.http_status == 500
  end

  test "returns structured transport errors" do
    Req.Test.expect(__MODULE__, &Req.Test.transport_error(&1, :timeout))

    assert {:ok, spec} = RequestSpec.normalize(%{url: "https://example.com/status"})
    assert {:ok, epoch} = EffectGuard.admit_ready()

    assert {:ok, result} =
             HttpClient.request(spec, plug: {Req.Test, __MODULE__}, allbert_pack_epoch: epoch)

    assert result.status == :failed
    assert result.transport_error =~ "timeout"
  end

  test "missing, malformed, activation, and stale epochs do not invoke the Req plug", %{
    readiness: readiness
  } do
    test_pid = self()

    Req.Test.stub(__MODULE__, fn conn ->
      send(test_pid, :transport_called)
      Plug.Conn.send_resp(conn, 200, "unexpected")
    end)

    assert {:ok, spec} = RequestSpec.normalize(%{url: "https://example.com/status"})
    assert {:ok, epoch} = EffectGuard.admit_ready()

    for opts <- [
          [],
          [allbert_pack_epoch: :malformed],
          [allbert_pack_activation: :boot],
          [allbert_pack_epoch: epoch]
        ] do
      if opts == [allbert_pack_epoch: epoch], do: :ok = Readiness.replace(readiness)

      assert {:error, reason} =
               HttpClient.request(spec, Keyword.merge([plug: {Req.Test, __MODULE__}], opts))

      assert reason in [:product_not_ready, :stale_epoch]
      refute_received :transport_called
    end
  end

  defp configure_external(context) do
    assert {:ok, _setting} = Settings.put("external_services.enabled", true, context)

    assert {:ok, _setting} =
             Settings.put("external_services.allowed_hosts", ["example.com"], context)

    assert {:ok, _setting} =
             Settings.put("external_services.allowed_paths", ["/status"], context)
  end

  defp restore_env(module, nil), do: Application.delete_env(:allbert_assist, module)
  defp restore_env(module, config), do: Application.put_env(:allbert_assist, module, config)
end
