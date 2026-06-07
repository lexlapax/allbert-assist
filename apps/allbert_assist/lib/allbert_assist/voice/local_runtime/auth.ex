defmodule AllbertAssist.Voice.LocalRuntime.Auth do
  @moduledoc """
  Local authority token for the Allbert-owned loopback voice runtime.

  The token is not a provider credential. It is a per-Allbert-Home capability
  token that prevents arbitrary local processes from invoking the loopback STT
  and TTS service once the operator starts it.
  """

  alias AllbertAssist.Runtime.Paths
  alias AllbertAssist.Voice.LocalRuntime.Config

  @header "x-allbert-local-runtime-token"

  @spec header_name() :: String.t()
  def header_name, do: @header

  @spec ensure_token!() :: String.t()
  def ensure_token! do
    case read_token() do
      {:ok, token} ->
        token

      {:error, _reason} ->
        token = new_token()
        path = token_path()

        File.mkdir_p!(Path.dirname(path))
        File.write!(path, token)
        File.chmod(path, 0o600)
        token
    end
  end

  @spec read_token() :: {:ok, String.t()} | {:error, term()}
  def read_token do
    with {:ok, token} <- File.read(token_path()),
         token = String.trim(token),
         true <- token != "" do
      {:ok, token}
    else
      false -> {:error, :local_voice_runtime_token_empty}
      {:error, reason} -> {:error, reason}
    end
  end

  @spec token_path() :: String.t()
  def token_path, do: Path.join([Paths.tmp_root(), "local-voice-runtime", "token"])

  @spec header_for_base_url(String.t() | nil) :: [{String.t(), String.t()}]
  def header_for_base_url(base_url) when is_binary(base_url) do
    config = Config.build()

    if normalized_base_url(base_url) == normalized_base_url(config.base_url) do
      case read_token() do
        {:ok, token} -> [{@header, token}]
        {:error, _reason} -> []
      end
    else
      []
    end
  rescue
    _exception -> []
  end

  def header_for_base_url(_base_url), do: []

  @spec authorized?(Plug.Conn.t() | [{String.t(), String.t()}], map()) :: boolean()
  def authorized?(%Plug.Conn{req_headers: headers}, config), do: authorized?(headers, config)

  def authorized?(headers, _config) when is_list(headers) do
    with {:ok, expected} <- read_token(),
         actual when is_binary(actual) <- header_value(headers) do
      Plug.Crypto.secure_compare(actual, expected)
    else
      _missing -> false
    end
  end

  def authorized?(_headers, _config), do: false

  defp header_value(headers) do
    Enum.find_value(headers, fn
      {key, value} when is_binary(key) and is_binary(value) ->
        if String.downcase(key) == @header, do: value

      _other ->
        nil
    end)
  end

  defp new_token do
    32
    |> :crypto.strong_rand_bytes()
    |> Base.url_encode64(padding: false)
  end

  defp normalized_base_url(base_url) do
    base_url
    |> Config.validate_loopback_base_url!()
    |> URI.parse()
    |> then(fn uri ->
      uri
      |> Map.put(:host, normalize_host(uri.host))
      |> Map.put(:scheme, String.downcase(uri.scheme || "http"))
      |> URI.to_string()
    end)
  end

  defp normalize_host("localhost"), do: "127.0.0.1"
  defp normalize_host("localhost.localdomain"), do: "127.0.0.1"
  defp normalize_host(host) when is_binary(host), do: String.downcase(host)
  defp normalize_host(host), do: host
end
