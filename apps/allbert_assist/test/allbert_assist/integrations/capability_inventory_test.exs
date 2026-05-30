defmodule AllbertAssist.Integrations.CapabilityInventoryTest do
  use ExUnit.Case, async: false
  @moduletag :app_env_serial

  import ExUnit.CaptureIO

  alias AllbertAssist.Settings
  alias Mix.Tasks.Allbert.Settings, as: SettingsTask

  @doc_path Path.expand(
              "../../../../../docs/operator/mcp-servers.md",
              __DIR__
            )
  @integration_ids ~w(calendar mail github)

  setup do
    original_settings_config = Application.get_env(:allbert_assist, Settings)

    root =
      Path.join(
        System.tmp_dir!(),
        "allbert-v042-m6-inventory-#{System.unique_integer([:positive])}"
      )

    Application.put_env(:allbert_assist, Settings, root: root)
    Mix.Task.reenable("allbert.settings")

    on_exit(fn ->
      restore_env(Settings, original_settings_config)
      Mix.Task.reenable("allbert.settings")
      File.rm_rf!(root)
    end)

    :ok
  end

  test "operator integration config examples parse through Settings Central" do
    doc = File.read!(@doc_path)

    for integration_id <- @integration_ids do
      commands = config_commands(doc, integration_id)
      assert commands != []

      Enum.each(commands, fn command ->
        assert :ok = run_settings_command(command)
      end)
    end

    assert {:ok, "streamable_http"} = Settings.get("mcp.servers.calendar.transport")
    assert {:ok, "streamable_http"} = Settings.get("mcp.servers.mail.transport")
    assert {:ok, "stdio"} = Settings.get("mcp.servers.github.transport")
    assert {:ok, ["docker", "npx", "uvx"]} = Settings.get("mcp.stdio.allowed_launchers")
  end

  defp config_commands(doc, integration_id) do
    pattern =
      ~r/<!-- v0\.42-m6-config:#{Regex.escape(integration_id)}:start -->\s*```sh\s*(.*?)\s*```\s*<!-- v0\.42-m6-config:#{Regex.escape(integration_id)}:end -->/s

    case Regex.run(pattern, doc, capture: :all_but_first) do
      [block] ->
        block
        |> String.split("\n", trim: true)
        |> Enum.map(&String.trim/1)
        |> Enum.reject(&(&1 == "" or String.starts_with?(&1, "#")))

      _other ->
        []
    end
  end

  defp run_settings_command(command) do
    case OptionParser.split(command) do
      ["mix", "allbert.settings" | args] ->
        capture_io(fn -> SettingsTask.run(args) end)
        :ok

      other ->
        flunk("unexpected settings example command: #{inspect(other)}")
    end
  end

  defp restore_env(module, nil), do: Application.delete_env(:allbert_assist, module)
  defp restore_env(module, config), do: Application.put_env(:allbert_assist, module, config)
end
