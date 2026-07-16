defmodule AllbertAssist.PublicProtocol.AcpMappingTest do
  use AllbertAssist.DataCase, async: false, lane: :external_runtime_serial

  alias AllbertAssist.Confirmations
  alias AllbertAssist.Paths
  alias AllbertAssist.PublicProtocol.Acp.Mapping
  alias AllbertAssist.Settings

  setup do
    original_paths_config = Application.get_env(:allbert_assist, Paths)
    original_settings_config = Application.get_env(:allbert_assist, Settings)
    original_confirmations_config = Application.get_env(:allbert_assist, Confirmations)

    root =
      Path.join(
        System.tmp_dir!(),
        "allbert-acp-mapping-#{System.unique_integer([:positive])}"
      )

    Application.put_env(:allbert_assist, Paths, home: root)
    Application.put_env(:allbert_assist, Settings, root: Path.join(root, "settings"))
    Application.put_env(:allbert_assist, Confirmations, root: Path.join(root, "confirmations"))

    on_exit(fn ->
      restore_env(Paths, original_paths_config)
      restore_env(Settings, original_settings_config)
      restore_env(Confirmations, original_confirmations_config)
      File.rm_rf!(root)
    end)

    :ok
  end

  test "initialize advertises only the implemented text-session ACP subset" do
    result =
      Mapping.initialize_result(%{
        "protocolVersion" => 1,
        "clientInfo" => %{"name" => "zed-fixture"}
      })

    assert result["protocolVersion"] == 1
    assert result["agentInfo"]["name"] == "allbert-assist"
    assert result["authMethods"] == []
    assert result["agentCapabilities"]["promptCapabilities"] == %{}
    assert result["agentCapabilities"]["sessionCapabilities"] == %{}
    refute Map.has_key?(result["agentCapabilities"], "mcpCapabilities")
  end

  test "session metadata cannot grant MCP, filesystem, or permission authority" do
    assert {:error, mcp_error} =
             Mapping.validate_session_params(%{
               "cwd" => "/tmp/project",
               "mcpServers" => [%{"name" => "filesystem", "command" => "mcp"}]
             })

    assert mcp_error.data["code"] == "mcpservers_no_authority"
    assert mcp_error.data["param"] == "mcpServers"

    assert {:error, dir_error} =
             Mapping.validate_session_params(%{
               "additionalDirectories" => ["/tmp/other"]
             })

    assert dir_error.data["code"] == "additional_directories_no_authority"

    assert {:error, mode_error} =
             Mapping.validate_session_params(%{"permissionMode" => "acceptEdits"})

    assert mode_error.data["code"] == "permission_mode_no_authority"

    assert {:ok, %{cwd: "/tmp/project"}} =
             Mapping.validate_session_params(%{"cwd" => "/tmp/project", "mcpServers" => []})
  end

  test "flattens text prompt blocks and rejects resource or media content" do
    assert {:ok, text} =
             Mapping.flatten_prompt(%{
               "prompt" => [
                 %{"type" => "text", "text" => "First"},
                 %{"type" => "text", "text" => "Second"}
               ]
             })

    assert text == "First\nSecond"

    assert {:error, resource_error} =
             Mapping.flatten_prompt(%{
               "prompt" => [
                 %{
                   "type" => "resource_link",
                   "uri" => "file:///tmp/project/main.ex",
                   "name" => "main.ex"
                 }
               ]
             })

    assert resource_error.data["code"] == "unsupported_content_block"

    assert {:error, audio_error} =
             Mapping.flatten_prompt(%{
               "prompt" => [%{"type" => "audio", "mimeType" => "audio/wav", "data" => "abc"}]
             })

    assert audio_error.data["code"] == "unsupported_content_block"
  end

  test "runtime request maps ACP session identity without using protocol metadata as authority" do
    request =
      Mapping.runtime_request("Explain this.", %{
        id: "acp_sess_fixture",
        client_id: "zed-fixture",
        cwd: "/tmp/project"
      })

    assert request.channel == :acp_stdio
    assert request.user_id == "public-protocol:zed-fixture"
    assert request.operator_id == "public-protocol:zed-fixture"
    assert request.session_id == "acp_sess_fixture"
    assert get_in(request.metadata, [:public_protocol, :surface]) == "acp_stdio"
    assert get_in(request.metadata, [:public_protocol, :client_id]) == "zed-fixture"
    assert get_in(request.metadata, [:acp, :cwd]) == "/tmp/project"
  end

  test "surface enablement reads Settings Central only" do
    refute Mapping.surface_enabled?()

    assert {:ok, _setting} = Settings.put("acp_server.enabled", true, %{audit?: false})
    assert {:ok, _setting} = Settings.put("acp_server.stdio.enabled", true, %{audit?: false})

    assert Mapping.surface_enabled?()
  end

  defp restore_env(module, nil), do: Application.delete_env(:allbert_assist, module)
  defp restore_env(module, config), do: Application.put_env(:allbert_assist, module, config)
end
