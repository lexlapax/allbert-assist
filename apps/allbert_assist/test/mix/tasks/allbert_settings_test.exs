defmodule Mix.Tasks.Allbert.SettingsTest do
  use ExUnit.Case, async: false
  @moduletag :app_env_serial

  import ExUnit.CaptureIO

  alias AllbertAssist.Settings
  alias AllbertAssist.TestSupport.ProviderPreconditions
  alias Mix.Tasks.Allbert.Settings, as: SettingsTask

  setup do
    original_settings_config = Application.get_env(:allbert_assist, Settings)

    root =
      Path.join(System.tmp_dir!(), "allbert-settings-task-#{System.unique_integer([:positive])}")

    Application.put_env(:allbert_assist, Settings, root: root)
    ProviderPreconditions.ensure_tui_settings_schema!()

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

    preferences_output =
      capture_io(fn ->
        assert :ok =
                 SettingsTask.run([
                   "set",
                   "model_preferences.capabilities.speech_to_text",
                   "voice_stt_fake"
                 ])
      end)

    assert preferences_output =~
             "Updated: model_preferences.capabilities.speech_to_text=[\"voice_stt_fake\"]"

    assert {:ok, ["voice_stt_fake"]} =
             Settings.get("model_preferences.capabilities.speech_to_text")

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

    identity_map_output =
      capture_io(fn ->
        assert :ok =
                 SettingsTask.run([
                   "set",
                   "channels.tui.identity_map",
                   ~s([{"external_user_id":"default","user_id":"local","enabled":true}])
                 ])
      end)

    assert identity_map_output =~ "Updated: channels.tui.identity_map=["

    assert {:ok, [%{"external_user_id" => "default", "user_id" => "local"} = entry]} =
             Settings.get("channels.tui.identity_map")

    assert entry["enabled"] == true
  end

  test "sets public protocol list settings from comma-separated CLI values" do
    mcp_tools_output =
      capture_io(fn ->
        assert :ok =
                 SettingsTask.run([
                   "set",
                   "mcp_server.tools_enabled",
                   "direct_answer,external_network_request,get_public_call_result"
                 ])
      end)

    assert mcp_tools_output =~
             "Updated: mcp_server.tools_enabled=[\"direct_answer\", \"external_network_request\", \"get_public_call_result\"]"

    assert {:ok, ["direct_answer", "external_network_request", "get_public_call_result"]} =
             Settings.get("mcp_server.tools_enabled")

    mcp_namespaces_output =
      capture_io(fn ->
        assert :ok =
                 SettingsTask.run([
                   "set",
                   "mcp_server.memory_namespaces_enabled",
                   "stocksage.stocksage"
                 ])
      end)

    assert mcp_namespaces_output =~
             "Updated: mcp_server.memory_namespaces_enabled=[\"stocksage.stocksage\"]"

    assert {:ok, ["stocksage.stocksage"]} =
             Settings.get("mcp_server.memory_namespaces_enabled")

    models_output =
      capture_io(fn ->
        assert :ok =
                 SettingsTask.run([
                   "set",
                   "openai_api.models_enabled",
                   "local"
                 ])
      end)

    assert models_output =~ "Updated: openai_api.models_enabled=[\"local\"]"
    assert {:ok, ["local"]} = Settings.get("openai_api.models_enabled")

    openai_tools_output =
      capture_io(fn ->
        assert :ok =
                 SettingsTask.run([
                   "set",
                   "openai_api.tools_enabled",
                   "direct_answer,external_network_request,get_public_call_result"
                 ])
      end)

    assert openai_tools_output =~
             "Updated: openai_api.tools_enabled=[\"direct_answer\", \"external_network_request\", \"get_public_call_result\"]"

    assert {:ok, ["direct_answer", "external_network_request", "get_public_call_result"]} =
             Settings.get("openai_api.tools_enabled")

    acp_tools_output =
      capture_io(fn ->
        assert :ok =
                 SettingsTask.run([
                   "set",
                   "acp_server.tools_enabled",
                   "direct_answer,external_network_request,get_public_call_result"
                 ])
      end)

    assert acp_tools_output =~
             "Updated: acp_server.tools_enabled=[\"direct_answer\", \"external_network_request\", \"get_public_call_result\"]"

    assert {:ok, ["direct_answer", "external_network_request", "get_public_call_result"]} =
             Settings.get("acp_server.tools_enabled")

    acp_namespaces_output =
      capture_io(fn ->
        assert :ok =
                 SettingsTask.run([
                   "set",
                   "acp_server.memory_namespaces_enabled",
                   "stocksage.stocksage"
                 ])
      end)

    assert acp_namespaces_output =~
             "Updated: acp_server.memory_namespaces_enabled=[\"stocksage.stocksage\"]"

    assert {:ok, ["stocksage.stocksage"]} =
             Settings.get("acp_server.memory_namespaces_enabled")
  end

  test "model-doctor renders the per-purpose recommendation matrix" do
    assert {:ok, _setting} =
             Settings.put("providers.local_ollama.base_url", "http://127.0.0.1:1/v1", %{
               audit?: false
             })

    output = capture_io(fn -> assert :ok = SettingsTask.run(["model-doctor"]) end)

    assert output =~ "model doctor ok="
    assert output =~ "intent_embedding"
    assert output =~ "intent_escalation"
    refute output =~ "secret://"
    refute output =~ "api_key"
  end

  test "doctor renders the settings version contract inventory" do
    output = capture_io(fn -> assert :ok = SettingsTask.run(["doctor"]) end)

    assert output =~ "settings version contract status=ok"
    assert output =~ "core:artifacts"
    assert output =~ "diagnostics=none"
    refute output =~ "secret://"
    refute output =~ "api_key"
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
