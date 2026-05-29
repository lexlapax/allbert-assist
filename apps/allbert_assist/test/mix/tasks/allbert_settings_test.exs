defmodule Mix.Tasks.Allbert.SettingsTest do
  use ExUnit.Case, async: false
  @moduletag :app_env_serial

  import ExUnit.CaptureIO

  alias AllbertAssist.Settings
  alias Mix.Tasks.Allbert.Settings, as: SettingsTask

  setup do
    original_settings_config = Application.get_env(:allbert_assist, Settings)

    root =
      Path.join(System.tmp_dir!(), "allbert-settings-task-#{System.unique_integer([:positive])}")

    Application.put_env(:allbert_assist, Settings, root: root)

    on_exit(fn ->
      restore_env(Settings, original_settings_config)
      Mix.Task.reenable("allbert.settings")
      File.rm_rf!(root)
    end)

    {:ok, root: root}
  end

  test "lists, gets, explains, and sets settings" do
    list_output = capture_io(fn -> assert :ok = SettingsTask.run(["list"]) end)
    assert list_output =~ "operator.timezone"

    get_output = capture_io(fn -> assert :ok = SettingsTask.run(["get", "operator.timezone"]) end)
    assert get_output =~ "operator.timezone="
    assert get_output =~ "Source: default"

    explain_output =
      capture_io(fn -> assert :ok = SettingsTask.run(["explain", "operator.timezone"]) end)

    assert explain_output =~ "Layers:"

    set_output =
      capture_io(fn ->
        assert :ok = SettingsTask.run(["set", "operator.communication_style", "balanced"])
      end)

    assert set_output =~ "Updated: operator.communication_style=\"balanced\""
    assert set_output =~ "Audit:"
    assert {:ok, "balanced"} = Settings.get("operator.communication_style")

    list_set_output =
      capture_io(fn ->
        assert :ok =
                 SettingsTask.run(["set", "execution.local.allowed_roots", "/tmp,/private/tmp"])
      end)

    assert list_set_output =~
             "Updated: execution.local.allowed_roots=[\"/tmp\", \"/private/tmp\"]"

    assert {:ok, ["/tmp", "/private/tmp"]} = Settings.get("execution.local.allowed_roots")

    aliases_output =
      capture_io(fn ->
        assert :ok =
                 SettingsTask.run([
                   "set",
                   "model_profiles.coding_local.aliases",
                   "qwen2.5-coder,qwen-coder"
                 ])
      end)

    assert aliases_output =~
             "Updated: model_profiles.coding_local.aliases=[\"qwen2.5-coder\", \"qwen-coder\"]"

    assert {:ok, ["qwen2.5-coder", "qwen-coder"]} =
             Settings.get("model_profiles.coding_local.aliases")

    json_list_output =
      capture_io(fn ->
        assert :ok =
                 SettingsTask.run([
                   "set",
                   "mcp.stdio.allowed_launchers",
                   ~s(["npx","uvx"])
                 ])
      end)

    assert json_list_output =~ "Updated: mcp.stdio.allowed_launchers=[\"npx\", \"uvx\"]"
    assert {:ok, ["npx", "uvx"]} = Settings.get("mcp.stdio.allowed_launchers")

    assert {:ok, _setting} = Settings.put("mcp.servers.demo.enabled", false, %{audit?: false})

    json_map_output =
      capture_io(fn ->
        assert :ok =
                 SettingsTask.run([
                   "set",
                   "mcp.servers.demo.env",
                   ~s({"PATH":"/usr/bin"})
                 ])
      end)

    assert json_map_output =~ "Updated: mcp.servers.demo.env=%{\"PATH\" => \"/usr/bin\"}"
    assert {:ok, %{"PATH" => "/usr/bin"}} = Settings.get("mcp.servers.demo.env")

    json_allowlist_output =
      capture_io(fn ->
        assert :ok =
                 SettingsTask.run([
                   "set",
                   "mcp.servers.demo.tool_allowlist",
                   ~s(["search","read"])
                 ])
      end)

    assert json_allowlist_output =~
             "Updated: mcp.servers.demo.tool_allowlist=[\"search\", \"read\"]"

    assert {:ok, ["search", "read"]} = Settings.get("mcp.servers.demo.tool_allowlist")
  end

  test "provider list and set-key use stdin and redact raw key", %{root: root} do
    initial_output = capture_io(fn -> assert :ok = SettingsTask.run(["providers", "list"]) end)
    assert initial_output =~ "openai"
    assert initial_output =~ "credential=missing"

    set_key_output =
      capture_io("test-key\n", fn ->
        assert :ok = SettingsTask.run(["providers", "set-key", "openai"])
      end)

    assert set_key_output =~ "openai credential=configured"
    refute set_key_output =~ "test-key"

    provider_output = capture_io(fn -> assert :ok = SettingsTask.run(["providers", "list"]) end)
    assert provider_output =~ "openai"
    assert provider_output =~ "credential=configured"
    refute provider_output =~ "test-key"
    assert [] == Path.wildcard(Path.join([root, "**", "*test-key*"]))
  end

  test "provider set-key rejects positional secret argument" do
    assert_raise Mix.Error, ~r/stdin or an interactive prompt/, fn ->
      SettingsTask.run(["providers", "set-key", "openai", "test-key"])
    end
  end

  test "invalid and read-only writes raise Mix errors" do
    assert_raise Mix.Error, ~r/read_only_setting/, fn ->
      SettingsTask.run(["set", "agents.primary_intent.module", "Other"])
    end
  end

  defp restore_env(module, nil), do: Application.delete_env(:allbert_assist, module)
  defp restore_env(module, config), do: Application.put_env(:allbert_assist, module, config)
end
