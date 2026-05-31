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
          {"https://localhost/status", {:private_host_denied, "localhost"}}
        ] do
      assert {:error, spec} = RequestSpec.normalize(%{url: url})
      assert spec.denial_reason == reason
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
    assert {:ok, _setting} = Settings.put("external_services.enabled", true, %{audit?: false})

    assert {:ok, _setting} =
             Settings.put(
               "external_services.allowed_hosts",
               [
                 "example.com",
                 "metadata.google.internal",
                 "10.0.0.1",
                 "169.254.169.254",
                 "localhost"
               ],
               %{audit?: false}
             )

    assert {:ok, _setting} =
             Settings.put("external_services.allowed_paths", ["/status"], %{audit?: false})
  end

  defp restore_env(module, nil), do: Application.delete_env(:allbert_assist, module)
  defp restore_env(module, config), do: Application.put_env(:allbert_assist, module, config)
end
