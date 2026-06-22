defmodule AllbertAssist.External.WhatsAppSmokeTest do
  use ExUnit.Case, async: false
  @moduletag :external_runtime_serial
  @moduletag :home_fs_serial

  if System.get_env("ALLBERT_WHATSAPP_EXTERNAL_SMOKE") != "1" do
    @moduletag skip: "set ALLBERT_WHATSAPP_EXTERNAL_SMOKE=1 to run the real WhatsApp smoke"
  end

  alias AllbertAssist.Channels.WhatsApp.Client
  alias AllbertAssist.Paths
  alias AllbertAssist.Plugin.Registry, as: PluginRegistry
  alias AllbertAssist.Plugins.WhatsApp, as: WhatsAppPlugin
  alias AllbertAssist.Repo
  alias AllbertAssist.Settings
  alias AllbertAssist.Settings.Fragments
  alias AllbertAssist.Settings.Secrets
  alias Ecto.Adapters.SQL.Sandbox

  @required [
    "ALLBERT_WHATSAPP_ACCESS_TOKEN",
    "ALLBERT_WHATSAPP_PHONE_NUMBER_ID",
    "ALLBERT_WHATSAPP_TO_PHONE"
  ]

  setup_all do
    missing = Enum.filter(@required, &(System.get_env(&1) in [nil, ""]))

    if missing != [] do
      flunk("missing required WhatsApp smoke env vars: #{Enum.join(missing, ", ")}")
    end

    home =
      System.get_env("ALLBERT_HOME") ||
        Path.join(System.tmp_dir!(), "allbert-whatsapp-smoke")

    original_paths_config = Application.get_env(:allbert_assist, Paths)
    original_settings_config = Application.get_env(:allbert_assist, Settings)
    original_plugins = PluginRegistry.registered_plugins()

    Application.put_env(:allbert_assist, Paths, home: home)
    Application.put_env(:allbert_assist, Settings, root: Path.join(home, "settings"))

    PluginRegistry.clear()
    assert {:ok, _} = PluginRegistry.register_module(WhatsAppPlugin)
    Fragments.clear_cache()

    Mix.Task.reenable("ecto.migrate.allbert")
    Mix.Task.run("ecto.migrate.allbert", ["--quiet"])

    put_secret!(
      "secret://channels/whatsapp/access_token",
      System.fetch_env!("ALLBERT_WHATSAPP_ACCESS_TOKEN")
    )

    on_exit(fn ->
      restore_env(Paths, original_paths_config)
      restore_env(Settings, original_settings_config)
      restore_plugins(original_plugins)
      Fragments.clear_cache()
    end)

    %{
      home: home,
      access_token: System.fetch_env!("ALLBERT_WHATSAPP_ACCESS_TOKEN"),
      phone_number_id: System.fetch_env!("ALLBERT_WHATSAPP_PHONE_NUMBER_ID"),
      to_phone: System.fetch_env!("ALLBERT_WHATSAPP_TO_PHONE")
    }
  end

  setup do
    :ok = Sandbox.checkout(Repo)
    Sandbox.mode(Repo, {:shared, self()})
    :ok
  end

  test "real WhatsApp Cloud API accepts phone lookup and text send", context do
    started_at = DateTime.utc_now()
    marker = "Allbert v0.53 WhatsApp smoke #{DateTime.to_iso8601(started_at)}"

    assert {:ok, phone} = Client.phone_number(context.access_token, context.phone_number_id)

    assert {:ok, %{"messages" => [%{"id" => message_id} | _rest]}} =
             Client.send_text(
               context.access_token,
               context.phone_number_id,
               context.to_phone,
               marker
             )

    evidence_path =
      write_evidence!(context.home, started_at, %{
        phone_verified_name: Map.get(phone, "verified_name"),
        phone_quality_rating: Map.get(phone, "quality_rating"),
        provider_message_id: message_id,
        to_phone: "[REDACTED_PHONE]"
      })

    IO.puts("whatsapp external smoke evidence: #{evidence_path}")
  end

  defp write_evidence!(home, started_at, whatsapp_evidence) do
    evidence_dir = Path.join(home, "release_evidence/v053")
    File.mkdir_p!(evidence_dir)

    evidence = %{
      gate: "mix allbert.test external-smoke -- whatsapp",
      version: "v0.53",
      status: "passed",
      generated_at: DateTime.utc_now() |> DateTime.to_iso8601(),
      started_at: DateTime.to_iso8601(started_at),
      whatsapp: whatsapp_evidence,
      secret_material: "redacted; access token stored only through Settings Central secret refs"
    }

    path = Path.join(evidence_dir, "external-smoke-whatsapp-#{DateTime.to_unix(started_at)}.json")
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
