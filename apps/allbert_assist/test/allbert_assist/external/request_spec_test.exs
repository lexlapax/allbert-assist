defmodule AllbertAssist.External.RequestSpecTest do
  use ExUnit.Case, async: false
  @moduletag :app_env_serial

  alias AllbertAssist.External.RequestSpec
  alias AllbertAssist.Kernel.Contract.TestProviders

  # RequestSpec reads external-service policy through the kernel settings
  # contract, so each row states the policy it needs rather than writing it
  # into a temporary Allbert Home through Settings Central.
  @external %{
    "external_services.enabled" => true,
    "external_services.allowed_hosts" => ["example.com"],
    "external_services.allowed_paths" => ["/status"],
    "external_services.max_response_bytes" => 4096
  }

  test "disabled external services deny before confirmation" do
    stub!(%{})

    assert {:error, spec} = RequestSpec.normalize(%{url: "https://example.com/status"})
    assert spec.denial_reason == :external_services_disabled
  end

  test "normalizes allowed requests with redacted summaries" do
    stub!(@external)

    assert {:ok, spec} =
             RequestSpec.normalize(%{
               method: "get",
               url: "https://example.com/status?state=secret",
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
    stub!(
      Map.put(@external, "external_services.profiles", %{
        "test_echo" => %{
          "enabled" => true,
          "base_url" => "https://example.com",
          "allowed_hosts" => ["example.com"],
          "allowed_paths" => ["/status"],
          "allowed_methods" => ["GET"]
        }
      })
    )

    assert {:ok, spec} = RequestSpec.normalize(%{profile: "test_echo", path: "/status"})
    assert spec.profile == "test_echo"
    assert spec.url == "https://example.com/status"
  end

  test "denies unsafe request shapes" do
    stub!(@external)

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

  defp stub!(values) do
    restore = TestProviders.stub_settings!(values)
    on_exit(restore)
    :ok
  end
end
