defmodule AllbertAssist.External.HttpClientTest do
  use ExUnit.Case, async: false
  @moduletag :external_runtime_serial

  alias AllbertAssist.External.HttpClient
  alias AllbertAssist.External.RequestSpec
  alias AllbertAssist.Paths
  alias AllbertAssist.Settings

  setup {Req.Test, :verify_on_exit!}

  setup do
    original_paths_config = Application.get_env(:allbert_assist, Paths)
    original_settings_config = Application.get_env(:allbert_assist, Settings)

    root =
      Path.join(
        System.tmp_dir!(),
        "allbert-external-http-client-#{System.unique_integer([:positive])}"
      )

    Application.put_env(:allbert_assist, Paths, home: root)
    Application.put_env(:allbert_assist, Settings, root: Path.join(root, "settings"))
    configure_external()

    on_exit(fn ->
      restore_env(Paths, original_paths_config)
      restore_env(Settings, original_settings_config)
      File.rm_rf!(root)
    end)

    :ok
  end

  test "executes through Req.Test and caps response body" do
    Req.Test.stub(__MODULE__, fn conn ->
      conn
      |> Plug.Conn.put_resp_header("set-cookie", "session=secret")
      |> Plug.Conn.send_resp(200, "hello world")
    end)

    assert {:ok, spec} =
             RequestSpec.normalize(%{url: "https://example.com/status", max_response_bytes: 5})

    assert {:ok, result} = HttpClient.request(spec, plug: {Req.Test, __MODULE__})
    assert result.status == :completed
    assert result.http_status == 200
    assert result.body_preview == "hello"
    assert result.truncated?

    assert Enum.any?(
             result.response_headers,
             &(&1.name == "set-cookie" and &1.value == "[REDACTED]")
           )
  end

  test "does not follow redirects by default" do
    Req.Test.expect(__MODULE__, fn conn ->
      conn
      |> Plug.Conn.put_resp_header("location", "https://example.com/other")
      |> Plug.Conn.send_resp(302, "redirect")
    end)

    assert {:ok, spec} = RequestSpec.normalize(%{url: "https://example.com/status"})
    assert {:ok, result} = HttpClient.request(spec, plug: {Req.Test, __MODULE__})
    assert result.http_status == 302
  end

  test "does not retry by default" do
    Req.Test.expect(__MODULE__, fn conn ->
      Plug.Conn.send_resp(conn, 500, "server error")
    end)

    assert {:ok, spec} = RequestSpec.normalize(%{url: "https://example.com/status"})
    assert {:ok, result} = HttpClient.request(spec, plug: {Req.Test, __MODULE__})
    assert result.status == :failed
    assert result.http_status == 500
  end

  test "returns structured transport errors" do
    Req.Test.expect(__MODULE__, &Req.Test.transport_error(&1, :timeout))

    assert {:ok, spec} = RequestSpec.normalize(%{url: "https://example.com/status"})
    assert {:ok, result} = HttpClient.request(spec, plug: {Req.Test, __MODULE__})
    assert result.status == :failed
    assert result.transport_error =~ "timeout"
  end

  defp configure_external do
    assert {:ok, _setting} = Settings.put("external_services.enabled", true, %{audit?: false})

    assert {:ok, _setting} =
             Settings.put("external_services.allowed_hosts", ["example.com"], %{audit?: false})

    assert {:ok, _setting} =
             Settings.put("external_services.allowed_paths", ["/status"], %{audit?: false})
  end

  defp restore_env(module, nil), do: Application.delete_env(:allbert_assist, module)
  defp restore_env(module, config), do: Application.put_env(:allbert_assist, module, config)
end
