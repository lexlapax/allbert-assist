defmodule AllbertAssist.External.MatrixInboundSmokeTest do
  use ExUnit.Case, async: false
  @moduletag :external_runtime_serial
  @moduletag timeout: :infinity

  if System.get_env("ALLBERT_MATRIX_INBOUND_EXTERNAL_SMOKE") != "1" do
    @moduletag skip:
                 "set ALLBERT_MATRIX_INBOUND_EXTERNAL_SMOKE=1 to run the real Matrix /sync inbound smoke"
  end

  alias AllbertAssist.Channels.Matrix.Adapter, as: MatrixAdapter
  alias AllbertAssist.Paths
  alias AllbertAssist.Plugin.Registry, as: PluginRegistry
  alias AllbertAssist.Plugins.Matrix, as: MatrixPlugin
  alias AllbertAssist.Repo
  alias AllbertAssist.Runtime
  alias AllbertAssist.Settings
  alias AllbertAssist.Settings.Fragments
  alias AllbertAssist.Settings.Secrets
  alias AllbertAssist.Trace
  alias Ecto.Adapters.SQL.Sandbox

  @required [
    "ALLBERT_MATRIX_HOMESERVER_URL",
    "ALLBERT_MATRIX_ACCESS_TOKEN",
    "ALLBERT_MATRIX_ROOM_ID",
    "ALLBERT_MATRIX_USER_ID"
  ]

  setup_all do
    missing = Enum.filter(@required, &(System.get_env(&1) in [nil, ""]))

    if missing != [] do
      flunk("missing required Matrix inbound smoke env vars: #{Enum.join(missing, ", ")}")
    end

    home =
      System.get_env("ALLBERT_HOME") ||
        Path.join(System.tmp_dir!(), "allbert-matrix-inbound-smoke")

    original_paths_config = Application.get_env(:allbert_assist, Paths)
    original_runtime_config = Application.get_env(:allbert_assist, Runtime)
    original_settings_config = Application.get_env(:allbert_assist, Settings)
    original_trace_config = Application.get_env(:allbert_assist, Trace)
    original_plugins = PluginRegistry.registered_plugins()

    Application.put_env(:allbert_assist, Paths, home: home)
    Application.put_env(:allbert_assist, Settings, root: Path.join(home, "settings"))
    Application.delete_env(:allbert_assist, Trace)

    PluginRegistry.clear()
    assert {:ok, _} = PluginRegistry.register_module(MatrixPlugin)
    Fragments.clear_cache()

    Mix.Task.reenable("ecto.migrate.allbert")
    Mix.Task.run("ecto.migrate.allbert", ["--quiet"])

    put_secret!(
      "secret://channels/matrix/access_token",
      System.fetch_env!("ALLBERT_MATRIX_ACCESS_TOKEN")
    )

    on_exit(fn ->
      restore_env(Paths, original_paths_config)
      restore_env(Runtime, original_runtime_config)
      restore_env(Settings, original_settings_config)
      restore_env(Trace, original_trace_config)
      restore_plugins(original_plugins)
      Fragments.clear_cache()
    end)

    %{
      home: home,
      homeserver_url: System.fetch_env!("ALLBERT_MATRIX_HOMESERVER_URL"),
      room_id: System.fetch_env!("ALLBERT_MATRIX_ROOM_ID"),
      mxid: System.fetch_env!("ALLBERT_MATRIX_USER_ID"),
      timeout_ms: timeout_ms()
    }
  end

  setup do
    :ok = Sandbox.checkout(Repo, ownership_timeout: 3_600_000)
    Sandbox.mode(Repo, {:shared, self()})

    parent = self()

    Application.put_env(:allbert_assist, Runtime,
      agent_runner: fn _signal, request ->
        Kernel.send(parent, {:runtime_request, request})
        {:ok, %{message: "Inbound smoke received: #{request.text}", status: :completed}}
      end
    )

    :ok
  end

  test "real Matrix /sync routes an operator-sent mapped-room message to the runtime",
       context do
    started_at = DateTime.utc_now()

    marker =
      case System.get_env("ALLBERT_SMOKE_MARKER") do
        value when value in [nil, ""] ->
          "allbert-v053-matrix-inbound-#{DateTime.to_unix(started_at)}"

        value ->
          value
      end

    adapter = start_matrix!(context)

    print_marker_instructions(context, marker)

    request = wait_for_runtime_request(marker, context.timeout_ms, context.home)

    evidence_path =
      write_evidence!(context.home, started_at, %{
        marker: marker,
        timeout_ms: context.timeout_ms,
        matrix: %{
          sync_poll_started?: true,
          room_id: context.room_id,
          mapped_mxid: context.mxid,
          runtime_request?: true,
          runtime_text: request.text
        },
        manual_followups_required: [
          "Matrix typed-command approval reply from the mapped MXID (resume post-v0.54)",
          "unmapped MXID rejection before runtime",
          "encrypted-room event recorded rejected with reason encrypted_not_supported"
        ]
      })

    :ok = GenServer.stop(adapter)
    IO.puts("matrix_inbound external smoke evidence: #{evidence_path}")
  end

  defp start_matrix!(context) do
    put_setting!("channels.matrix.homeserver_url", context.homeserver_url)
    put_setting!("channels.matrix.access_token_ref", "secret://channels/matrix/access_token")
    put_setting!("channels.matrix.allowed_room_ids", [context.room_id])

    put_setting!("channels.matrix.identity_map", [
      %{
        "external_user_id" => context.mxid,
        "user_id" => "external-smoke",
        "enabled" => true
      }
    ])

    put_setting!("channels.matrix.sync_poll_interval_ms", 1000)
    put_setting!("channels.matrix.sync_timeout_ms", 10_000)
    put_setting!("channels.matrix.enabled", true)

    assert {:ok, pid} = MatrixAdapter.start_link(name: nil)
    pid
  end

  defp print_marker_instructions(context, marker) do
    IO.puts("""
    matrix_inbound marker: #{marker}
    Send from mapped Matrix user #{context.mxid} in the allowlisted room #{context.room_id}:
      #{marker} matrix
    Waiting up to #{context.timeout_ms}ms for the provider-delivered inbound event.
    """)
  end

  defp wait_for_runtime_request(marker, timeout_ms, home) do
    deadline = System.monotonic_time(:millisecond) + timeout_ms
    do_wait_for_runtime_request(marker, deadline, home)
  end

  defp do_wait_for_runtime_request(marker, deadline, home) do
    remaining = max(deadline - System.monotonic_time(:millisecond), 0)

    receive do
      {:runtime_request, request} ->
        if matching_request?(request, marker) do
          request
        else
          do_wait_for_runtime_request(marker, deadline, home)
        end
    after
      remaining ->
        diag = dump_inbound_diagnostics(home)

        flunk(
          "timed out waiting for a Matrix inbound runtime request containing #{inspect(marker)}\n" <>
            "--- recorded channel_events ---\n#{diag}"
        )
    end
  end

  defp matching_request?(request, marker) do
    channel = to_string(Map.get(request, :channel))
    text = to_string(Map.get(request, :text))

    channel == "matrix" and String.contains?(text, marker)
  end

  defp dump_inbound_diagnostics(home) do
    import Ecto.Query

    rows =
      Repo.all(
        from(e in AllbertAssist.Channels.Event,
          where: e.channel == "matrix",
          order_by: [desc: e.inserted_at],
          limit: 20
        )
      )

    text =
      if rows == [] do
        "(none - no Matrix channel_events recorded; check the access token, homeserver URL, " <>
          "allowed_room_ids, identity map, and that the marker was sent in the allowlisted room)"
      else
        Enum.map_join(rows, "\n", fn e ->
          "#{e.inserted_at} dir=#{e.direction} status=#{e.status} " <>
            "ext_user=#{e.external_user_id} ext_chat=#{e.external_chat_id} reason=#{e.reason}"
        end)
      end

    path = Path.join(home, "matrix-inbound-diagnostics.txt")
    File.mkdir_p!(home)
    File.write!(path, text)
    IO.puts("matrix inbound diagnostics written: #{path}")
    text
  end

  defp write_evidence!(home, started_at, evidence) do
    evidence_dir = Path.join(home, "release_evidence/v053")
    File.mkdir_p!(evidence_dir)

    body =
      Map.merge(evidence, %{
        gate: "mix allbert.test external-smoke -- inbound_matrix",
        version: "v0.53",
        status: "passed",
        generated_at: DateTime.utc_now() |> DateTime.to_iso8601(),
        started_at: DateTime.to_iso8601(started_at),
        secret_material: "redacted; access token stored only through Settings Central secret refs"
      })

    path =
      Path.join(
        evidence_dir,
        "external-smoke-inbound-matrix-#{DateTime.to_unix(started_at)}.json"
      )

    File.write!(path, Jason.encode!(body, pretty: true))
    path
  end

  defp timeout_ms do
    case System.get_env("ALLBERT_MATRIX_INBOUND_TIMEOUT_MS") do
      value when value in [nil, ""] -> 120_000
      value -> String.to_integer(value)
    end
  end

  defp put_secret!(secret_ref, value) do
    assert {:ok, _secret} = Secrets.put_secret(secret_ref, value, %{audit?: false})
  end

  defp put_setting!(key, value) do
    assert {:ok, _setting} = Settings.put(key, value, %{audit?: false})
  end

  defp restore_plugins(original_plugins) do
    PluginRegistry.clear()
    Enum.each(original_plugins, &PluginRegistry.register_entry/1)
  end

  defp restore_env(module, nil), do: Application.delete_env(:allbert_assist, module)
  defp restore_env(module, value), do: Application.put_env(:allbert_assist, module, value)
end
