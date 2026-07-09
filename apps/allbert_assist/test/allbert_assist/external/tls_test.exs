defmodule AllbertAssist.External.TLSTest do
  use ExUnit.Case, async: false

  alias AllbertAssist.External.TLS

  @moduledoc """
  M8.2: outbound HTTPS must resolve CA trust explicitly — `SSL_CERT_FILE` authoritative,
  otherwise the OS store, otherwise the bundled castore PEM — so a hosted-provider probe
  never hits Mint's hard "castore missing" crash and the operator's override actually works.
  """

  setup do
    original = System.get_env("SSL_CERT_FILE")

    on_exit(fn ->
      if original,
        do: System.put_env("SSL_CERT_FILE", original),
        else: System.delete_env("SSL_CERT_FILE")
    end)

    :ok
  end

  test "SSL_CERT_FILE is authoritative when set" do
    System.put_env("SSL_CERT_FILE", "/etc/ssl/cert.pem")
    assert [connect_options: [transport_opts: transport]] = TLS.connect_options()
    assert transport[:cacertfile] == "/etc/ssl/cert.pem"
    refute Keyword.has_key?(transport, :cacerts)
  end

  test "without SSL_CERT_FILE it carries a real CA source (OS store or bundled castore)" do
    System.delete_env("SSL_CERT_FILE")
    assert [connect_options: [transport_opts: transport]] = TLS.connect_options()

    cond do
      is_list(transport[:cacerts]) -> assert transport[:cacerts] != []
      is_binary(transport[:cacertfile]) -> assert File.exists?(transport[:cacertfile])
      true -> flunk("expected either :cacerts or a real :cacertfile, got #{inspect(transport)}")
    end
  end

  test "the bundled castore PEM exists (offline-safe fallback ships with the release)" do
    assert File.exists?(CAStore.file_path())
  end
end
