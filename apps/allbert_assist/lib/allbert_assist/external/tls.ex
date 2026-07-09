defmodule AllbertAssist.External.TLS do
  @moduledoc """
  Shared CA-trust resolution for outbound HTTPS (v0.63 M8.2).

  Precedence: `SSL_CERT_FILE` (operator override, authoritative) → the OS trust store
  (`:public_key.cacerts_get/0`) → the bundled `castore` PEM (offline-safe fallback).

  Before M8.2 no outbound path passed any CA option, so every HTTPS call relied on Mint's
  implicit resolution; on a host with an empty/unloadable OS store (common under a
  relocated/bundled ERTS), Mint fell back to `CAStore`, which was not a dependency and so
  raised *"default CA trust store not available; please add `:castore`"*. `SSL_CERT_FILE`
  did not help because nothing threaded it into the transport options. This helper makes
  the override authoritative, ships a bundled fallback, and guarantees no outbound path
  reaches Mint's hard castore crash.
  """

  @doc """
  Req/Mint connect options carrying the resolved CA trust. Merge into a Req option list:

      opts |> Keyword.merge(AllbertAssist.External.TLS.connect_options())
  """
  @spec connect_options() :: keyword()
  def connect_options do
    [connect_options: [transport_opts: transport_opts()]]
  end

  defp transport_opts do
    case System.get_env("SSL_CERT_FILE") do
      path when is_binary(path) and path != "" -> [cacertfile: path]
      _ -> os_or_bundled()
    end
  end

  # Mirror Mint's own OS-store attempt, but treat an empty/raising result as "use the
  # bundled castore PEM" rather than shipping an empty trust store that fails every TLS.
  defp os_or_bundled do
    case :public_key.cacerts_get() do
      [_ | _] = certs -> [cacerts: certs]
      _empty -> [cacertfile: CAStore.file_path()]
    end
  rescue
    _error -> [cacertfile: CAStore.file_path()]
  end
end
