defmodule AllbertAssist.External.RequestSpecTest do
  use ExUnit.Case, async: false

  alias AllbertAssist.External.RequestSpec
  alias AllbertAssist.Paths
  alias AllbertAssist.Settings

  setup do
    original_paths_config = Application.get_env(:allbert_assist, Paths)
    original_settings_config = Application.get_env(:allbert_assist, Settings)

    root =
      Path.join(
        System.tmp_dir!(),
        "allbert-external-request-spec-#{System.unique_integer([:positive])}"
      )

    Application.put_env(:allbert_assist, Paths, home: root)
    Application.put_env(:allbert_assist, Settings, root: Path.join(root, "settings"))

    on_exit(fn ->
      restore_env(Paths, original_paths_config)
      restore_env(Settings, original_settings_config)
      File.rm_rf!(root)
    end)

    {:ok, root: root}
  end

  test "disabled external services deny before confirmation" do
    assert {:error, spec} = RequestSpec.normalize(%{url: "https://example.com/status"})
    assert spec.denial_reason == :external_services_disabled
  end

  test "normalizes allowed requests with redacted summaries" do
    configure_external()

    assert {:ok, spec} =
             RequestSpec.normalize(%{
               method: "get",
               url: "https://example.com/status?token=secret",
               query: %{"page" => "1"},
               max_response_bytes: 128
             })

    assert spec.method == "GET"
    assert spec.host == "example.com"
    assert spec.path == "/status"
    assert spec.query =~ "page=1"

    summary = RequestSpec.summary(spec)
    assert summary.url == "https://example.com/status?[REDACTED]"
    assert summary.max_response_bytes == 128
    assert is_binary(summary.request_digest)
  end

  test "supports named external service profiles" do
    configure_external()

    assert {:ok, _profiles} =
             Settings.put(
               "external_services.profiles",
               %{
                 "test_echo" => %{
                   "enabled" => true,
                   "base_url" => "https://example.com",
                   "allowed_hosts" => ["example.com"],
                   "allowed_paths" => ["/status"],
                   "allowed_methods" => ["GET"]
                 }
               },
               %{audit?: false}
             )

    assert {:ok, spec} = RequestSpec.normalize(%{profile: "test_echo", path: "/status"})
    assert spec.profile == "test_echo"
    assert spec.url == "https://example.com/status"
  end

  test "denies unsafe request shapes" do
    configure_external()

    assert {:error, %{denial_reason: {:host_not_allowlisted, "not-example.com"}}} =
             RequestSpec.normalize(%{url: "https://not-example.com/status"})

    assert {:error, %{denial_reason: {:unsupported_scheme, "ftp"}}} =
             RequestSpec.normalize(%{url: "ftp://example.com/status"})

    assert {:error, %{denial_reason: :url_credentials_not_allowed}} =
             RequestSpec.normalize(%{url: "https://user:pass@example.com/status"})

    assert {:error, %{denial_reason: {:private_host_denied, "127.0.0.1"}}} =
             RequestSpec.normalize(%{url: "https://127.0.0.1/status"})

    assert {:error, %{denial_reason: {:path_not_allowed, "/admin"}}} =
             RequestSpec.normalize(%{url: "https://example.com/admin"})

    assert {:error, %{denial_reason: {:sensitive_header_requires_secret_ref, "authorization"}}} =
             RequestSpec.normalize(%{
               url: "https://example.com/status",
               headers: %{"authorization" => "Bearer secret"}
             })
  end

  defp configure_external do
    assert {:ok, _setting} = Settings.put("external_services.enabled", true, %{audit?: false})

    assert {:ok, _setting} =
             Settings.put("external_services.allowed_hosts", ["example.com"], %{audit?: false})

    assert {:ok, _setting} =
             Settings.put("external_services.allowed_paths", ["/status"], %{audit?: false})

    assert {:ok, _setting} =
             Settings.put("external_services.max_response_bytes", 4096, %{audit?: false})
  end

  defp restore_env(module, nil), do: Application.delete_env(:allbert_assist, module)
  defp restore_env(module, config), do: Application.put_env(:allbert_assist, module, config)
end
