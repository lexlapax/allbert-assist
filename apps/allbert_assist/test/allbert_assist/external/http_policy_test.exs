defmodule AllbertAssist.External.HttpPolicyTest do
  use ExUnit.Case, async: false
  @moduletag :app_env_serial

  alias AllbertAssist.External.RequestSpec
  alias AllbertAssist.Paths
  alias AllbertAssist.Settings

  setup do
    original_paths_config = Application.get_env(:allbert_assist, Paths)
    original_settings_config = Application.get_env(:allbert_assist, Settings)

    root =
      Path.join(
        System.tmp_dir!(),
        "allbert-external-http-policy-#{System.unique_integer([:positive])}"
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

  test "denies metadata, private, link-local, and loopback targets" do
    for {url, reason} <- [
          {"https://metadata.google.internal/status",
           {:metadata_host_denied, "metadata.google.internal"}},
          {"https://10.0.0.1/status", {:private_host_denied, "10.0.0.1"}},
          {"https://169.254.169.254/status", {:private_host_denied, "169.254.169.254"}},
          {"https://localhost/status", {:private_host_denied, "localhost"}},
          {"https://[::ffff:127.0.0.1]/status", {:private_host_denied, "::ffff:127.0.0.1"}},
          {"https://[::ffff:10.0.0.1]/status", {:private_host_denied, "::ffff:10.0.0.1"}},
          {"https://[::ffff:169.254.169.254]/status",
           {:private_host_denied, "::ffff:169.254.169.254"}},
          {"https://[::ffff:0.0.0.0]/status", {:private_host_denied, "::ffff:0.0.0.0"}},
          {"https://[::ffff:100.64.0.1]/status", {:private_host_denied, "::ffff:100.64.0.1"}},
          {"https://[::ffff:240.0.0.1]/status", {:private_host_denied, "::ffff:240.0.0.1"}},
          {"https://[::1]/status", {:private_host_denied, "::1"}},
          {"https://[fc00::1]/status", {:private_host_denied, "fc00::1"}},
          {"https://[fe80::1]/status", {:private_host_denied, "fe80::1"}},
          {"https://[ff00::1]/status", {:private_host_denied, "ff00::1"}}
        ] do
      assert {:error, spec} = RequestSpec.normalize(%{url: url})
      assert spec.denial_reason == reason
    end

    for host <- ["::ffff:8.8.8.8", "2001:4860:4860::8888"] do
      assert {:ok, spec} = RequestSpec.normalize(%{url: "https://[#{host}]/status"})
      assert spec.host == host
    end
  end

  test "denies method and path drift" do
    assert {:error, spec} =
             RequestSpec.normalize(%{method: "POST", url: "https://example.com/status"})

    assert spec.denial_reason == {:method_not_allowed, "POST"}

    assert {:error, spec} = RequestSpec.normalize(%{url: "https://example.com/private"})
    assert spec.denial_reason == {:path_not_allowed, "/private"}
  end

  test "denies credential-shaped query parameter names before request execution" do
    for name <- ~w[token api_key key secret password bearer access_token auth] do
      assert {:error, spec} =
               RequestSpec.normalize(%{url: "https://example.com/status?#{name}=short"})

      assert spec.denial_reason == {:credentialed_remote_url, {:query_param, name}}
    end
  end

  test "denies opaque credential-shaped query values with explicit diagnostic" do
    assert {:error, spec} =
             RequestSpec.normalize(%{
               url: "https://example.com/status?token=abcdefghijklmnopqrstuvwxyz123456"
             })

    assert spec.denial_reason == {:credentialed_remote_url, {:opaque_query_param, "token"}}
  end

  test "preserves userinfo rejection" do
    assert {:error, spec} = RequestSpec.normalize(%{url: "https://user:pass@example.com/status"})
    assert spec.denial_reason == :url_credentials_not_allowed
  end

  defp configure_external do
    assert {:ok, _setting} =
             Settings.put(
               "external_services.enabled",
               true,
               AllbertAssist.TestSupport.ReadyEffectContext.attach(%{audit?: false})
             )

    assert {:ok, _setting} =
             Settings.put(
               "external_services.allowed_hosts",
               [
                 "example.com",
                 "metadata.google.internal",
                 "10.0.0.1",
                 "169.254.169.254",
                 "localhost",
                 "::ffff:127.0.0.1",
                 "::ffff:10.0.0.1",
                 "::ffff:169.254.169.254",
                 "::ffff:0.0.0.0",
                 "::ffff:100.64.0.1",
                 "::ffff:240.0.0.1",
                 "::ffff:8.8.8.8",
                 "::1",
                 "fc00::1",
                 "fe80::1",
                 "ff00::1",
                 "2001:4860:4860::8888"
               ],
               AllbertAssist.TestSupport.ReadyEffectContext.attach(%{audit?: false})
             )

    assert {:ok, _setting} =
             Settings.put(
               "external_services.allowed_paths",
               ["/status"],
               AllbertAssist.TestSupport.ReadyEffectContext.attach(%{audit?: false})
             )
  end

  defp restore_env(module, nil), do: Application.delete_env(:allbert_assist, module)
  defp restore_env(module, config), do: Application.put_env(:allbert_assist, module, config)
end
