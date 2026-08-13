defmodule AllbertAssist.Pack.EffectGuardSettingsChannelsTest do
  use AllbertAssist.DataCase, async: false

  alias AllbertAssist.Channels
  alias AllbertAssist.Channels.Event
  alias AllbertAssist.Pack.EffectGuard
  alias AllbertAssist.Repo
  alias AllbertAssist.Settings
  alias AllbertAssist.Settings.Audit
  alias AllbertAssist.Settings.Secrets
  alias AllbertAssist.Settings.Store
  alias AllbertAssist.Surface.EventRecorder
  alias AllbertAssist.TestSupport.ReadyEffectContext

  defmodule Readiness do
    use GenServer

    def start_link(opts),
      do: GenServer.start_link(__MODULE__, :ok, name: Keyword.fetch!(opts, :name))

    def replace(server), do: GenServer.call(server, :replace)

    @impl true
    def init(:ok) do
      {:ok, %{epoch: :e1, e1: spawn_epoch(), e2: spawn_epoch()}}
    end

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

  setup do
    root =
      Path.join(System.tmp_dir!(), "allbert-effect-guard-#{System.unique_integer([:positive])}")

    original_settings = Application.get_env(:allbert_assist, Settings)
    original_readiness = Process.whereis(AllbertAssist.Pack.Readiness)

    File.rm_rf!(root)
    Application.put_env(:allbert_assist, Settings, root: root)
    true = Process.unregister(AllbertAssist.Pack.Readiness)
    {:ok, readiness} = Readiness.start_link(name: AllbertAssist.Pack.Readiness)

    on_exit(fn ->
      if Process.whereis(AllbertAssist.Pack.Readiness) == readiness,
        do: Process.unregister(AllbertAssist.Pack.Readiness)

      if Process.alive?(readiness), do: GenServer.stop(readiness)

      if Process.alive?(original_readiness) and
           is_nil(Process.whereis(AllbertAssist.Pack.Readiness)),
         do: Process.register(original_readiness, AllbertAssist.Pack.Readiness)

      if original_settings,
        do: Application.put_env(:allbert_assist, Settings, original_settings),
        else: Application.delete_env(:allbert_assist, Settings)

      File.rm_rf!(root)
    end)

    %{readiness: readiness}
  end

  test "a live E1 permits Settings and Channels persistence" do
    assert {:ok, epoch} = EffectGuard.admit_ready()
    context = %{allbert_pack_epoch: epoch, audit?: false}

    assert {:ok, %{value: "dark"}} = Settings.put("workspace.theme.mode", "dark", context)
    assert {:ok, %Event{} = event} = Channels.create_event(event_attrs("live"), context)
    assert event.external_event_id == "live"
    assert {:ok, %{"workspace" => %{"theme" => %{"mode" => "dark"}}}} = Store.read_user_settings()
  end

  test "Settings honors an explicit readiness server and rejects its replacement" do
    context = ReadyEffectContext.attach(%{audit?: false})
    server = ReadyEffectContext.server(context)

    assert {:ok, %{value: "dark"}} = Settings.put("workspace.theme.mode", "dark", context)
    assert {:ok, %Event{}} = Channels.create_event(event_attrs("explicit-channels"), context)

    assert %Event{} =
             EventRecorder.record_inbound(
               "explicit-event-recorder",
               event_attrs("explicit-recorder"),
               context
             )

    assert :ok = ReadyEffectContext.replace(server)

    assert {:error, :stale_epoch} =
             Settings.put("workspace.theme.mode", "light", context)

    assert {:error, :stale_epoch} =
             Channels.create_event(event_attrs("stale-channels"), context)

    assert is_nil(
             EventRecorder.record_inbound(
               "stale-event-recorder",
               event_attrs("stale-recorder"),
               context
             )
           )

    assert {:ok, "dark"} = Settings.get("workspace.theme.mode")
  end

  test "caller-supplied readiness options cannot replace the trusted Pack barrier" do
    {:ok, fake_server} = ReadyEffectContext.start_link([])
    {:ok, fake_status} = GenServer.call(fake_server, :status)

    fake_epoch = %{
      barrier_pid: fake_status.barrier_pid,
      snapshot_digest: fake_status.snapshot_digest
    }

    forged_context = %{
      allbert_pack_epoch: fake_epoch,
      allbert_pack_effect_guard_opts: [server: fake_server],
      audit?: false
    }

    assert {:error, :stale_epoch} =
             Settings.put("workspace.theme.mode", "dark", forged_context)

    assert {:error, :stale_epoch} =
             Channels.create_event(event_attrs("forged-readiness"), forged_context)

    assert {:ok, "system"} = Settings.get("workspace.theme.mode")
    assert Repo.aggregate(Event, :count, :id) == 0
  end

  test "missing, malformed, activation, and stale contexts create no write, audit, or channel signal",
       %{
         readiness: readiness
       } do
    assert {:ok, e1} = EffectGuard.admit_ready()
    before = Store.read_user_settings()
    audit_path = Audit.audit_path()

    Enum.each(
      [%{}, %{allbert_pack_epoch: :malformed}, %{allbert_pack_activation: :boot}],
      fn context ->
        assert {:error, :product_not_ready} =
                 Settings.put("workspace.theme.mode", "dark", context)

        assert {:error, :product_not_ready} =
                 Channels.create_event(event_attrs("blocked-#{inspect(context)}"), context)
      end
    )

    :ok = Readiness.replace(readiness)

    assert {:error, :stale_epoch} =
             Settings.put("workspace.theme.mode", "dark", %{allbert_pack_epoch: e1})

    assert {:error, :stale_epoch} =
             Channels.create_event(event_attrs("stale"), %{allbert_pack_epoch: e1})

    assert Store.read_user_settings() == before
    assert Repo.aggregate(Event, :count, :id) == 0
    refute File.exists?(audit_path)
  end

  test "same-digest E1 replacement rejects the second TokenAuth settings effect without admitting E2",
       %{
         readiness: readiness
       } do
    assert {:ok, e1} = EffectGuard.admit_ready()

    assert {:ok, _secret} =
             Secrets.put_secret(
               "secret://public_protocol/mcp_http/epoch-client/bearer_token",
               "token-value",
               %{allbert_pack_epoch: e1, audit?: false}
             )

    :ok = Readiness.replace(readiness)

    assert {:error, :stale_epoch} =
             Settings.put(
               "mcp_server.clients",
               %{"epoch-client" => %{"enabled" => true}},
               %{allbert_pack_epoch: e1, audit?: false}
             )

    assert {:ok, clients} = Settings.get("mcp_server.clients")
    refute Map.has_key?(clients, "epoch-client")
    assert {:error, :stale_epoch} = EffectGuard.validate(e1)
  end

  defp event_attrs(external_event_id) do
    %{
      channel: "telegram",
      provider: "telegram_bot_api",
      direction: "inbound",
      external_event_id: external_event_id,
      status: "received"
    }
  end
end
