defmodule AllbertAssist.CLI.Areas.PublicProtocolAcpTest do
  # async: false — `acp status`/`handshake` read Settings (global runtime state).
  use ExUnit.Case, async: false
  @moduletag :global_process_serial

  alias AllbertAssist.CLI.Areas.PublicProtocol, as: Area
  alias AllbertAssist.PublicProtocol.Acp.Mapping
  alias AllbertAssist.Settings

  @moduledoc """
  v1.0.1 M4.4 (DIT-4(c)): the packaged CLI exposed token administration only —
  no wire-level ACP status/handshake — so the packaged revalidation could not
  promote ACP past PARTIAL. `acp status` mirrors `mix allbert.acp_server status`;
  `acp handshake` does a real in-process JSON-RPC `initialize` round-trip through
  the same `Acp.Server` line codec the stdio transport uses.
  """

  test "acp status reports enablement and protocol facts" do
    {output, code} = Area.dispatch(["acp", "status"])

    assert code == 0
    assert output =~ "acp_server.enabled="
    assert output =~ "acp_stdio.enabled="
    assert output =~ "acp_protocol_version=#{Mapping.protocol_version()}"
    assert output =~ "acp_transport=stdio_jsonrpc_ndjson"
    assert output =~ "acp_prompt_capabilities=text_only"
  end

  test "acp handshake round-trips initialize and exits 0 only when the surface is enabled" do
    original_enabled = Settings.get("acp_server.enabled")
    original_stdio = Settings.get("acp_server.stdio.enabled")

    on_exit(fn ->
      restore_setting("acp_server.enabled", original_enabled)
      restore_setting("acp_server.stdio.enabled", original_stdio)
    end)

    :ok = put_setting("acp_server.enabled", true)
    :ok = put_setting("acp_server.stdio.enabled", true)

    {output, code} = Area.dispatch(["acp", "handshake"])

    assert code == 0
    assert output =~ "handshake=ok"
    assert output =~ "handshake_result_protocol_version="

    :ok = put_setting("acp_server.enabled", false)

    {disabled_output, disabled_code} = Area.dispatch(["acp", "handshake"])

    assert disabled_code != 0
    assert disabled_output =~ "handshake verified the wire protocol"
    assert disabled_output =~ "acp_server.enabled"
  end

  test "usage advertises the acp subcommands" do
    {usage, _code} = Area.dispatch(["help"])

    assert usage =~ "acp status"
    assert usage =~ "acp handshake"
  end

  defp put_setting(key, value) do
    case Settings.put(key, value, %{audit?: false}) do
      :ok -> :ok
      {:ok, _} -> :ok
      other -> other
    end
  end

  defp restore_setting(key, {:ok, value}), do: put_setting(key, value)
  defp restore_setting(key, _missing), do: put_setting(key, false)
end
