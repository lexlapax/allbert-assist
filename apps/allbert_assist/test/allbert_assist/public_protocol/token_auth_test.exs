defmodule AllbertAssist.PublicProtocol.TokenAuthTest do
  use ExUnit.Case, async: false
  @moduletag :app_env_serial

  import ExUnit.CaptureIO

  alias AllbertAssist.PublicProtocol.TokenAuth
  alias AllbertAssist.Settings
  alias AllbertAssist.Settings.Secrets
  alias Mix.Tasks.Allbert.PublicProtocol, as: PublicProtocolTask

  setup do
    original_settings_config = Application.get_env(:allbert_assist, Settings)
    root = temp_root("public-token-auth")

    Application.put_env(:allbert_assist, Settings, root: root)

    on_exit(fn ->
      restore_env(Settings, original_settings_config)
      Mix.Task.reenable("allbert.public_protocol")
      File.rm_rf!(root)
    end)

    :ok
  end

  test "creates, verifies, rotates, lists, and revokes bearer tokens" do
    assert {:ok, created} = TokenAuth.create(:mcp_http, "claude", context())
    assert created.token_ref == "secret://public_protocol/mcp_http/claude/bearer_token"
    assert created.redacted_token == "[REDACTED]"
    refute created.token == "[REDACTED]"

    assert Secrets.status(created.token_ref) == :configured
    assert {:ok, verified} = TokenAuth.verify("mcp_http", "claude", created.token)
    assert verified.client_id == "claude"

    assert {:ok, listed} = TokenAuth.list("mcp_http")
    assert [%{client_id: "claude", redacted_token: "[REDACTED]"}] = listed
    refute inspect(listed) =~ created.token

    assert {:ok, rotated} = TokenAuth.rotate("mcp_http", "claude", context())
    refute rotated.token == created.token
    assert {:error, :invalid_token} = TokenAuth.verify("mcp_http", "claude", created.token)
    assert {:ok, _verified} = TokenAuth.verify("mcp_http", "claude", rotated.token)

    assert {:ok, revoked} = TokenAuth.revoke("mcp_http", "claude", context())
    assert revoked.status == :revoked
    assert {:error, :client_disabled} = TokenAuth.verify("mcp_http", "claude", rotated.token)
  end

  test "token CLI prints raw token only for issuance and redacts list output" do
    create_output =
      capture_io(fn ->
        assert :ok =
                 PublicProtocolTask.run([
                   "token",
                   "create",
                   "--surface",
                   "openai_api",
                   "--client",
                   "local"
                 ])
      end)

    assert create_output =~ "surface=openai_api"
    assert create_output =~ "client=local"
    assert create_output =~ "token_ref=secret://public_protocol/openai_api/local/bearer_token"
    assert create_output =~ "token="
    refute create_output =~ "token=[REDACTED]"

    token =
      create_output
      |> String.split("\n", trim: true)
      |> Enum.find_value(fn line ->
        if String.starts_with?(line, "token="), do: String.replace_prefix(line, "token=", "")
      end)

    Mix.Task.reenable("allbert.public_protocol")

    list_output =
      capture_io(fn ->
        assert :ok =
                 PublicProtocolTask.run([
                   "token",
                   "list",
                   "--surface",
                   "openai_api"
                 ])
      end)

    assert list_output =~ "token=[REDACTED]"
    refute list_output =~ token
  end

  defp context, do: %{actor: "test", channel: "test", audit?: false}

  defp temp_root(prefix) do
    Path.join(System.tmp_dir!(), "allbert-#{prefix}-#{System.unique_integer([:positive])}")
  end

  defp restore_env(module, nil), do: Application.delete_env(:allbert_assist, module)
  defp restore_env(module, config), do: Application.put_env(:allbert_assist, module, config)
end
