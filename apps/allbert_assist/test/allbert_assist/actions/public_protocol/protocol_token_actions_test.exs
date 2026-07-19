defmodule AllbertAssist.Actions.PublicProtocol.ProtocolTokenActionsTest do
  @moduledoc """
  v0.62 M8.15: the create/rotate/revoke protocol-token mutations run on-spine
  through the Runner (PermissionGate + audit). These exercise the allowed path,
  the redaction property (raw token never in action metadata), and the failed
  (non-completed) path the CLI renders as an error.

  Note: `:settings_secret_write` is allowed-by-default and carries no Settings
  override key, so a pure permission-denied decision is not expressible through
  Settings for this class; the failed-surface case covers the non-completed
  rendering branch instead.
  """
  use ExUnit.Case, async: false
  @moduletag :app_env_serial

  alias AllbertAssist.Actions.Runner
  alias AllbertAssist.PublicProtocol.TokenAuth
  alias AllbertAssist.Settings
  alias AllbertAssist.Settings.Secrets

  setup do
    original_settings_config = Application.get_env(:allbert_assist, Settings)
    root = temp_root("protocol-token-actions")

    File.rm_rf!(root)
    Application.put_env(:allbert_assist, Settings, root: root)

    on_exit(fn ->
      restore_env(Settings, original_settings_config)
      File.rm_rf!(root)
    end)

    :ok
  end

  test "create_protocol_token issues a token on-spine and keeps it out of action metadata" do
    assert {:ok, response} =
             Runner.run("create_protocol_token", %{surface: "mcp_http", client: "claude"}, ctx())

    assert response.status == :completed
    assert response.permission_decision.permission == :settings_secret_write
    assert response.permission_decision.decision == :allowed

    result = response.token_result
    assert result.surface == "mcp_http"
    assert result.client_id == "claude"
    assert result.token_ref == "secret://public_protocol/mcp_http/claude/bearer_token"
    refute result.token == "[REDACTED]"
    assert Secrets.status(result.token_ref) == :configured

    # The raw token is renderable from the in-memory response but must never
    # appear in the action metadata that flows to logs/audit.
    [action] = response.actions
    assert action.public_protocol_metadata.token == "[REDACTED]"
    refute inspect(action) =~ result.token
    assert response.permission_decision.decision == :allowed
  end

  test "rotate_protocol_token replaces the token on-spine" do
    assert {:ok, created} =
             Runner.run("create_protocol_token", %{surface: "mcp_http", client: "claude"}, ctx())

    assert {:ok, rotated} =
             Runner.run("rotate_protocol_token", %{surface: "mcp_http", client: "claude"}, ctx())

    assert rotated.status == :completed
    refute rotated.token_result.token == created.token_result.token

    assert {:error, :invalid_token} =
             TokenAuth.verify("mcp_http", "claude", created.token_result.token)

    assert {:ok, _verified} = TokenAuth.verify("mcp_http", "claude", rotated.token_result.token)
    [action] = rotated.actions
    assert action.public_protocol_metadata.token == "[REDACTED]"
  end

  test "revoke_protocol_token disables the client on-spine and returns no raw token" do
    assert {:ok, created} =
             Runner.run("create_protocol_token", %{surface: "mcp_http", client: "claude"}, ctx())

    assert {:ok, revoked} =
             Runner.run("revoke_protocol_token", %{surface: "mcp_http", client: "claude"}, ctx())

    assert revoked.status == :completed
    assert revoked.token_result.status == :revoked
    refute Map.has_key?(revoked.token_result, :token)

    assert {:error, :client_disabled} =
             TokenAuth.verify("mcp_http", "claude", created.token_result.token)
  end

  test "create_protocol_token fails (non-completed) for an invalid surface" do
    assert {:ok, response} =
             Runner.run("create_protocol_token", %{surface: "not_a_surface", client: "x"}, ctx())

    assert response.status == :failed
    assert match?({:invalid_surface, _}, response.error)
    refute Map.has_key?(response, :token_result)
  end

  defp ctx, do: %{actor: "operator", user_id: "operator", channel: :cli, audit?: false}

  defp temp_root(prefix) do
    Path.join(
      System.tmp_dir!(),
      "allbert-#{prefix}-#{System.pid()}-#{System.unique_integer([:positive])}"
    )
  end

  defp restore_env(module, nil), do: Application.delete_env(:allbert_assist, module)
  defp restore_env(module, config), do: Application.put_env(:allbert_assist, module, config)
end
