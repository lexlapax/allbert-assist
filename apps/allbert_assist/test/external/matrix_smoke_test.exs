defmodule AllbertAssist.External.MatrixSmokeTest do
  use ExUnit.Case, async: false
  @moduletag :external_runtime_serial
  @moduletag :home_fs_serial

  if System.get_env("ALLBERT_MATRIX_EXTERNAL_SMOKE") != "1" do
    @moduletag skip: "set ALLBERT_MATRIX_EXTERNAL_SMOKE=1 to run the real Matrix smoke"
  end

  alias AllbertAssist.Channels.Matrix.Client
  alias AllbertAssist.Channels.Matrix.Renderer
  alias AllbertAssist.Conversations
  alias AllbertAssist.Conversations.ChannelThread
  alias AllbertAssist.Paths
  alias AllbertAssist.Plugin.Registry, as: PluginRegistry
  alias AllbertAssist.Plugins.Matrix, as: MatrixPlugin
  alias AllbertAssist.Repo
  alias AllbertAssist.Settings
  alias AllbertAssist.Settings.Fragments
  alias AllbertAssist.Settings.Secrets

  @required [
    "ALLBERT_MATRIX_HOMESERVER_URL",
    "ALLBERT_MATRIX_ACCESS_TOKEN",
    "ALLBERT_MATRIX_ROOM_ID"
  ]

  setup_all do
    missing = Enum.filter(@required, &(System.get_env(&1) in [nil, ""]))

    if missing != [] do
      flunk("missing required Matrix smoke env vars: #{Enum.join(missing, ", ")}")
    end

    home =
      System.get_env("ALLBERT_HOME") ||
        Path.join(System.tmp_dir!(), "allbert-matrix-smoke")

    original_paths_config = Application.get_env(:allbert_assist, Paths)
    original_settings_config = Application.get_env(:allbert_assist, Settings)
    original_plugins = PluginRegistry.registered_plugins()

    Application.put_env(:allbert_assist, Paths, home: home)
    Application.put_env(:allbert_assist, Settings, root: Path.join(home, "settings"))

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
      restore_env(Settings, original_settings_config)
      restore_plugins(original_plugins)
      Fragments.clear_cache()
    end)

    %{
      home: home,
      homeserver_url: System.fetch_env!("ALLBERT_MATRIX_HOMESERVER_URL"),
      access_token: System.fetch_env!("ALLBERT_MATRIX_ACCESS_TOKEN"),
      room_id: System.fetch_env!("ALLBERT_MATRIX_ROOM_ID")
    }
  end

  setup do
    :ok = Ecto.Adapters.SQL.Sandbox.checkout(Repo)
    Ecto.Adapters.SQL.Sandbox.mode(Repo, {:shared, self()})
    :ok
  end

  test "real Matrix homeserver accepts whoami and room send", context do
    started_at = DateTime.utc_now()
    marker = "Allbert v0.53 Matrix smoke #{DateTime.to_iso8601(started_at)}"

    assert {:ok, account} = Client.whoami(context.homeserver_url, context.access_token)

    assert {:ok, thread} =
             Conversations.create_general_thread("external-smoke", "v0.53 Matrix smoke")

    txn_id = Ecto.UUID.generate()
    content = Renderer.message_content(marker)

    assert {:ok, %{"event_id" => event_id}} =
             Client.send_message(
               context.homeserver_url,
               context.access_token,
               context.room_id,
               txn_id,
               content
             )

    assert {:ok, assistant} = Conversations.append_assistant_message(thread, "Matrix sent")
    receiver = matrix_receiver(context.homeserver_url, context.room_id)

    assert {:ok, _ref} =
             ChannelThread.record_message_ref(%{
               channel: "matrix",
               receiver_account_ref: receiver,
               provider_thread_ref: %{
                 provider: "matrix",
                 room_id: context.room_id,
                 provider_thread_root: event_id
               },
               canonical_thread_id: thread.id,
               canonical_message_id: assistant.id,
               provider_message_id: event_id,
               direction: :out
             })

    assert ChannelThread.echo?(%{
             channel: "matrix",
             receiver_account_ref: receiver,
             provider_message_id: event_id
           })

    evidence_path =
      write_evidence!(context.home, started_at, %{
        account_user_id: Map.get(account, "user_id"),
        room_id: context.room_id,
        event_id: event_id,
        echo_suppression_recorded?: true
      })

    IO.puts("matrix external smoke evidence: #{evidence_path}")
  end

  defp write_evidence!(home, started_at, matrix_evidence) do
    evidence_dir = Path.join(home, "release_evidence/v053")
    File.mkdir_p!(evidence_dir)

    evidence = %{
      gate: "mix allbert.test external-smoke -- matrix",
      version: "v0.53",
      status: "passed",
      generated_at: DateTime.utc_now() |> DateTime.to_iso8601(),
      started_at: DateTime.to_iso8601(started_at),
      matrix: matrix_evidence,
      secret_material: "redacted; access token stored only through Settings Central secret refs"
    }

    path = Path.join(evidence_dir, "external-smoke-matrix-#{DateTime.to_unix(started_at)}.json")
    File.write!(path, Jason.encode!(evidence, pretty: true))
    path
  end

  defp matrix_receiver(homeserver_url, room_id) do
    homeserver_ref = ChannelThread.provider_thread_key(homeserver_url)
    "matrix:homeserver:#{homeserver_ref}:room:#{room_id}"
  end

  defp put_secret!(secret_ref, value) do
    assert {:ok, _secret} = Secrets.put_secret(secret_ref, value, %{audit?: false})
  end

  defp restore_plugins(original_plugins) do
    PluginRegistry.clear()
    Enum.each(original_plugins, &PluginRegistry.register_entry/1)
  end

  defp restore_env(module, nil), do: Application.delete_env(:allbert_assist, module)
  defp restore_env(module, value), do: Application.put_env(:allbert_assist, module, value)
end
