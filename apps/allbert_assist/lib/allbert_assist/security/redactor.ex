defmodule AllbertAssist.Security.Redactor do
  @moduledoc """
  Central redaction policy for Security Central-facing values and metadata.

  v0.31 adds `AllbertAssist.Runtime.Redactor` as the runtime-facing facade for
  new code. This module remains the underlying compatibility policy so existing
  callers keep the exact same redaction behavior.
  """

  @redacted "[REDACTED]"
  @secret_ref "[SECRET_REF]"
  # v0.22 M2 audit closeout (moderate gap 10): expanded to cover
  # `raw_bridge_body`/`raw_final_state`/`raw_response` style fields that
  # downstream consumers (StockSage bridge, future advisory providers)
  # may dump into action maps. `authorization` and `bearer` catch
  # header-style credentials. Key-name redaction is the mechanism;
  # callers that need to dump raw secret content for debugging must
  # explicitly opt out at their own boundary, never silently.
  @sensitive_key_fragments [
    "api_key",
    "apikey",
    "secret",
    "token",
    "password",
    "credential",
    "raw_bridge",
    "raw_final",
    "raw_response",
    "authorization",
    "bearer",
    "cookie",
    "set-cookie"
  ]
  @sensitive_key_names [
    "bytes",
    "raw_bytes",
    "content_bytes",
    "payload_bytes",
    "bytes_base64",
    "content_base64",
    "payload_base64"
  ]
  @sensitive_query_names ~w[token api_key key secret password bearer access_token auth session]
  @status_keys ["credential_status", "secret_status", "secret_ref_display"]
  @secret_value_patterns [
    ~r/\b(sk-[A-Za-z0-9_-]{6,})\b/,
    ~r/\b(ghp_[A-Za-z0-9_]{6,})\b/,
    ~r/\b(xox[baprs]-[A-Za-z0-9-]{6,})\b/
  ]

  @type posture :: %{
          sensitive_key_fragments: nonempty_list(String.t()),
          secret_ref_display: String.t(),
          redacted_value: String.t(),
          surfaces: nonempty_list(atom())
        }

  @doc "Recursively redact sensitive keys, secret refs, structs, maps, and lists."
  @spec redact(term()) :: term()
  def redact(%_{} = struct) do
    struct
    |> Map.from_struct()
    |> Map.put(:__struct__, module_name(struct.__struct__))
    |> redact()
  end

  def redact(%{} = map) do
    Map.new(map, fn {key, value} ->
      if sensitive_key?(key) do
        {key, @redacted}
      else
        {key, redact(value)}
      end
    end)
  end

  def redact(list) when is_list(list), do: Enum.map(list, &redact/1)

  def redact("secret://" <> _rest), do: @secret_ref

  def redact(value) when is_binary(value) do
    value
    |> redact_authorization_line()
    |> redact_cookie_line()
    |> redact_bearer_value()
    |> redact_secret_shapes()
    |> redact_url()
  end

  def redact(value), do: value

  @doc "Return a short posture summary suitable for operator status."
  @spec posture() :: posture()
  def posture do
    %{
      sensitive_key_fragments: @sensitive_key_fragments,
      secret_ref_display: @secret_ref,
      redacted_value: @redacted,
      surfaces: [:signals, :traces, :audits, :cli, :live_view, :logs, :tests]
    }
  end

  @doc "Return true if a key name should cause value redaction."
  @spec sensitive_key?(term()) :: boolean()
  def sensitive_key?(key) do
    normalized =
      key
      |> to_string()
      |> String.downcase()

    normalized not in @status_keys and
      (normalized in @sensitive_key_names or
         Enum.any?(@sensitive_key_fragments, &String.contains?(normalized, &1)))
  end

  defp redact_authorization_line(value) do
    Regex.replace(~r/(authorization:\s*)(bearer\s+)?[^\s\r\n]+/i, value, "\\1\\2#{@redacted}")
  end

  defp redact_cookie_line(value) do
    Regex.replace(~r/((set-cookie|cookie):\s*)[^\r\n]+/i, value, "\\1#{@redacted}")
  end

  defp redact_bearer_value(value) do
    Regex.replace(~r/\b(bearer\s+)[^\s\r\n]+/i, value, "\\1#{@redacted}")
  end

  defp redact_secret_shapes(value) do
    Enum.reduce(@secret_value_patterns, value, fn pattern, acc ->
      Regex.replace(pattern, acc, @redacted)
    end)
  end

  defp redact_url(value) do
    uri = URI.parse(value)

    if uri.scheme in ["http", "https"] and is_binary(uri.host) do
      uri
      |> redact_url_userinfo()
      |> redact_url_query()
      |> URI.to_string()
    else
      value
    end
  rescue
    _exception -> value
  end

  defp redact_url_userinfo(%URI{userinfo: nil} = uri), do: uri
  defp redact_url_userinfo(%URI{} = uri), do: %{uri | userinfo: @redacted}

  defp redact_url_query(%URI{query: nil} = uri), do: uri

  defp redact_url_query(%URI{query: query} = uri) do
    query =
      query
      |> String.split("&")
      |> Enum.map_join("&", &redact_query_pair/1)

    %{uri | query: query}
  end

  defp redact_query_pair(pair) do
    case String.split(pair, "=", parts: 2) do
      [key, _value] ->
        if sensitive_query_name?(key), do: "#{key}=#{URI.encode_www_form(@redacted)}", else: pair

      _other ->
        pair
    end
  end

  defp sensitive_query_name?(key) do
    key =
      key
      |> URI.decode_www_form()
      |> String.downcase()

    key in @sensitive_query_names or
      Enum.any?(@sensitive_key_fragments, &String.contains?(key, &1))
  end

  defp module_name(module) when is_atom(module), do: inspect(module)
end
