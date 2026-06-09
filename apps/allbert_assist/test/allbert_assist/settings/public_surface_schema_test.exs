defmodule AllbertAssist.Settings.PublicSurfaceSchemaTest do
  use ExUnit.Case, async: false
  @moduletag :app_env_serial

  alias AllbertAssist.Settings

  setup do
    original_settings_config = Application.get_env(:allbert_assist, Settings)
    root = temp_root("public-surface-schema")

    Application.put_env(:allbert_assist, Settings, root: root)

    on_exit(fn ->
      restore_env(Settings, original_settings_config)
      File.rm_rf!(root)
    end)

    :ok
  end

  test "public protocol settings default off with empty allowlists" do
    assert {:ok, false} = Settings.get("mcp_server.enabled")
    assert {:ok, false} = Settings.get("mcp_server.stdio.enabled")
    assert {:ok, false} = Settings.get("mcp_server.streamable_http.enabled")
    assert {:ok, "127.0.0.1"} = Settings.get("mcp_server.streamable_http.bind_host")
    assert {:ok, nil} = Settings.get("mcp_server.streamable_http.port")
    assert {:ok, []} = Settings.get("mcp_server.tools_enabled")
    assert {:ok, []} = Settings.get("mcp_server.memory_namespaces_enabled")
    assert {:ok, %{}} = Settings.get("mcp_server.clients")

    assert {:ok, false} = Settings.get("openai_api.enabled")
    assert {:ok, "/v1"} = Settings.get("openai_api.path_prefix")
    assert {:ok, []} = Settings.get("openai_api.models_enabled")
    assert {:ok, %{}} = Settings.get("openai_api.clients")

    assert {:ok, false} = Settings.get("acp_server.enabled")
    assert {:ok, false} = Settings.get("acp_server.stdio.enabled")
    assert {:ok, []} = Settings.get("acp_server.tools_enabled")

    assert {:ok, 3_600_000} = Settings.get("public_protocol.result_readback_ttl_ms")
    assert {:ok, 1_048_576} = Settings.get("public_protocol.max_body_bytes")
  end

  test "public protocol settings are safe writes with bounded validation" do
    assert Settings.safe_write_key?("mcp_server.streamable_http.bind_host")
    assert Settings.safe_write_key?("mcp_server.clients.local.enabled")
    assert Settings.safe_write_key?("openai_api.clients.local.rate_limit.limit")
    assert Settings.safe_write_key?("permissions.public_surface_call_inbound")

    assert {:ok, resolved} =
             Settings.put("mcp_server.streamable_http.port", 4100, %{audit?: false})

    assert resolved.value == 4100

    assert {:error, {:invalid_setting, "mcp_server.streamable_http.port", _reason}} =
             Settings.put("mcp_server.streamable_http.port", 70_000, %{audit?: false})

    assert {:error, {:invalid_setting, "mcp_server.streamable_http.bind_host", _reason}} =
             Settings.put("mcp_server.streamable_http.bind_host", "0.0.0.0", %{audit?: false})

    assert {:error, {:invalid_setting, "openai_api.path_prefix", _reason}} =
             Settings.put("openai_api.path_prefix", "/v2", %{audit?: false})
  end

  test "client maps validate ids, token refs, and rate limits" do
    clients = %{
      "local" => %{
        "enabled" => true,
        "token_ref" => "secret://public_protocol/openai_api/local/bearer_token",
        "rate_limit" => %{"limit" => 5, "period_ms" => 1000, "burst" => 1}
      }
    }

    assert {:ok, resolved} = Settings.put("openai_api.clients", clients, %{audit?: false})
    assert resolved.value == clients

    invalid_ref =
      put_in(
        clients,
        ["local", "token_ref"],
        "secret://public_protocol/mcp_http/local/bearer_token"
      )

    assert {:error, {:invalid_setting, "openai_api.clients", _reason}} =
             Settings.put("openai_api.clients", invalid_ref, %{audit?: false})

    invalid_rate = put_in(clients, ["local", "rate_limit", "limit"], 0)

    assert {:error, {:invalid_setting, "openai_api.clients", _reason}} =
             Settings.put("openai_api.clients", invalid_rate, %{audit?: false})

    invalid_client_id = %{"bad id" => clients["local"]}

    assert {:error, {:invalid_setting, "openai_api.clients", _reason}} =
             Settings.put("openai_api.clients", invalid_client_id, %{audit?: false})
  end

  test "public tool allowlists reject non-exposable settings actions" do
    assert {:error, {:invalid_setting, "mcp_server.tools_enabled", _reason}} =
             Settings.put("mcp_server.tools_enabled", ["list_settings"], %{audit?: false})
  end

  defp temp_root(prefix) do
    Path.join(System.tmp_dir!(), "allbert-#{prefix}-#{System.unique_integer([:positive])}")
  end

  defp restore_env(module, nil), do: Application.delete_env(:allbert_assist, module)
  defp restore_env(module, config), do: Application.put_env(:allbert_assist, module, config)
end
