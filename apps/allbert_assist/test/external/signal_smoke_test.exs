defmodule AllbertAssist.External.SignalSmokeTest do
  use ExUnit.Case, async: false
  @moduletag :external_runtime_serial

  if System.get_env("ALLBERT_SIGNAL_EXTERNAL_SMOKE") != "1" do
    @moduletag skip: "set ALLBERT_SIGNAL_EXTERNAL_SMOKE=1 to run the real Signal smoke"
  end

  alias AllbertAssist.Channels.Signal.Client
  alias AllbertAssist.Paths
  alias AllbertAssist.Plugin.Registry, as: PluginRegistry
  alias AllbertAssist.Plugins.Signal, as: SignalPlugin
  alias AllbertAssist.Repo
  alias AllbertAssist.Settings
  alias AllbertAssist.Settings.Fragments
  alias AllbertAssist.Settings.Secrets
  alias Ecto.Adapters.SQL.Sandbox

  @required [
    "ALLBERT_SIGNAL_ACCOUNT",
    "ALLBERT_SIGNAL_RECIPIENT",
    "ALLBERT_SIGNAL_CONTROL_HTTP_BASE_URL",
    "ALLBERT_SIGNAL_CONTROL_AUTH"
  ]

  setup_all do
    missing = Enum.filter(@required, &(System.get_env(&1) in [nil, ""]))

    if missing != [] do
      flunk("missing required Signal smoke env vars: #{Enum.join(missing, ", ")}")
    end

    home =
      System.get_env("ALLBERT_HOME") ||
        Path.join(System.tmp_dir!(), "allbert-signal-smoke")

    original_paths_config = Application.get_env(:allbert_assist, Paths)
    original_settings_config = Application.get_env(:allbert_assist, Settings)
    original_plugins = PluginRegistry.registered_plugins()

    Application.put_env(:allbert_assist, Paths, home: home)
    Application.put_env(:allbert_assist, Settings, root: Path.join(home, "settings"))

    PluginRegistry.clear()
    assert {:ok, _} = PluginRegistry.register_module(SignalPlugin)
    Fragments.clear_cache()

    Mix.Task.reenable("ecto.migrate.allbert")
    Mix.Task.run("ecto.migrate.allbert", ["--quiet"])

    put_secret!(
      "secret://channels/signal/control_auth",
      System.fetch_env!("ALLBERT_SIGNAL_CONTROL_AUTH")
    )

    on_exit(fn ->
      restore_env(Paths, original_paths_config)
      restore_env(Settings, original_settings_config)
      restore_plugins(original_plugins)
      Fragments.clear_cache()
    end)

    %{
      home: home,
      account: System.fetch_env!("ALLBERT_SIGNAL_ACCOUNT"),
      recipient: System.fetch_env!("ALLBERT_SIGNAL_RECIPIENT"),
      base_url: System.fetch_env!("ALLBERT_SIGNAL_CONTROL_HTTP_BASE_URL")
    }
  end

  setup do
    :ok = Sandbox.checkout(Repo)
    Sandbox.mode(Repo, {:shared, self()})
    :ok
  end

  test "real signal-cli daemon accepts JSON-RPC account list and text send", context do
    started_at = DateTime.utc_now()
    marker = "Allbert v0.53 Signal smoke #{DateTime.to_iso8601(started_at)}"

    opts = [
      mode: :loopback_http,
      base_url: context.base_url,
      auth_ref: "secret://channels/signal/control_auth"
    ]

    assert {:ok, _accounts} = Client.list_accounts(opts)

    assert {:ok, response} =
             Client.send_message(context.account, context.recipient, marker, opts)

    evidence_path =
      write_evidence!(context.home, started_at, %{
        provider_response: response,
        recipient: "[REDACTED_SIGNAL_RECIPIENT]"
      })

    IO.puts("signal external smoke evidence: #{evidence_path}")
  end

  defp write_evidence!(home, started_at, signal_evidence) do
    evidence_dir = Path.join(home, "release_evidence/v053")
    File.mkdir_p!(evidence_dir)

    evidence = %{
      gate: "mix allbert.test external-smoke -- signal",
      version: "v0.53",
      status: "passed",
      generated_at: DateTime.utc_now() |> DateTime.to_iso8601(),
      started_at: DateTime.to_iso8601(started_at),
      signal: signal_evidence,
      secret_material: "redacted; control auth stored only through Settings Central secret refs"
    }

    path = Path.join(evidence_dir, "external-smoke-signal-#{DateTime.to_unix(started_at)}.json")
    File.write!(path, Jason.encode!(evidence, pretty: true))
    path
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
