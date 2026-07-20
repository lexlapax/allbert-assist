defmodule AllbertAssist.Security.Redactor do
  @moduledoc """
  Central redaction policy for Security Central-facing values and metadata.

  v0.31 adds `AllbertAssist.Runtime.Redactor` as the runtime-facing facade for
  new code. This module remains the underlying compatibility policy so existing
  callers keep the exact same redaction behavior.
  """

  @redacted "[REDACTED]"
  @secret_ref "[SECRET_REF]"
  @phone_redaction "[REDACTED_PHONE]"
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
  @non_sensitive_key_names ["allow_single_token_match"]
  @secret_value_patterns [
    ~r/\b(sk-[A-Za-z0-9_-]{6,})\b/,
    ~r/\b(ghp_[A-Za-z0-9_]{6,})\b/,
    ~r/\b(xox[baprs]-[A-Za-z0-9-]{6,})\b/,
    ~r/\b(xapp-[A-Za-z0-9-]{6,})\b/,
    ~r/\b(AIza[0-9A-Za-z_-]{20,})\b/,
    ~r/\b((?:AKIA|ASIA)[A-Z0-9]{16})\b/
  ]
  @phone_value_pattern ~r/(^|[^A-Za-z0-9_])(\+[1-9]\d{6,14})(?![A-Za-z0-9_])/

  # v1.0.3 M7: every binary value walked by `redact/1` ran the full
  # ten-regex pipeline unconditionally — 35,040 `Regex.replace` invocations
  # inside one `Engine.decide` (eprof; 73% of all regex work in the turn).
  # Each pattern has a MANDATORY literal that must appear in the subject for
  # any match to exist, so a single Aho-Corasick prescan per step decides
  # "cannot match" far cheaper than running the regex, and `Regex.replace`
  # on a non-matching subject returns the subject unchanged. The guards are
  # therefore exactly equivalent, not approximations:
  #
  #   * authorization: `(authorization:\s*)…/i` — group 1 is mandatory, and
  #     every case variant of "authorization" contains `z` or `Z`.
  #   * cookie: `((set-cookie|cookie):\s*)…/i` — both alternatives contain
  #     "cookie", hence `k` or `K`.
  #   * bearer: `\b(bearer\s+)…/i` — mandatory "bearer", hence `b` or `B`.
  #   * secret shapes: all six patterns are case-SENSITIVE, so their literal
  #     prefixes are exact byte sequences.
  #   * phone: the pattern requires a literal `+`.
  #   * url: `redact_url/1` only rewrites when `URI.parse/1` yields an
  #     http(s) scheme, and a scheme exists only when the value contains `:`.
  @authorization_markers ["z", "Z"]
  @cookie_markers ["k", "K"]
  @bearer_markers ["b", "B"]
  @secret_shape_markers ["sk-", "ghp_", "xox", "xapp-", "AIza", "AKIA", "ASIA"]
  @phone_markers ["+"]
  @url_markers [":"]

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

  def redact(list) when is_list(list), do: redact_list(list)

  def redact("secret://" <> _rest), do: @secret_ref

  def redact(value) when is_binary(value) do
    value
    |> redact_authorization_line()
    |> redact_cookie_line()
    |> redact_bearer_value()
    |> redact_secret_shapes()
    |> redact_phone_numbers()
    |> redact_url()
  end

  def redact(value), do: value

  # Redaction is a safety facade and must be total — it must never raise and take
  # down a caller (e.g. a channel adapter). `Enum.map/2` raises on an improper
  # list (tail is not `[]`), so recurse manually and redact a non-list tail
  # rather than crashing. Proper lists behave exactly as before.
  defp redact_list([head | tail]) when is_list(tail), do: [redact(head) | redact_list(tail)]
  defp redact_list([head | tail]), do: [redact(head), redact(tail)]
  defp redact_list([]), do: []

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
      |> downcase_key()

    normalized not in @status_keys and
      normalized not in @non_sensitive_key_names and
      (normalized in @sensitive_key_names or
         String.contains?(normalized, sensitive_fragment_pattern()))
  end

  # M8.8: redaction walks every key of every payload it touches, and the
  # fragment check ran one String.contains? per fragment per key (~150k
  # binary scans inside one Engine.decide, eprof). One compiled multi-
  # pattern keeps the exact any-fragment-contained semantics in a single
  # scan per key. compile_pattern returns a runtime ref, so it cannot live
  # in a module attribute; the fragment list is compile-constant, so the
  # persistent_term memo never needs invalidation.
  defp sensitive_fragment_pattern do
    compiled_pattern(:sensitive_fragment_pattern, @sensitive_key_fragments)
  end

  # v1.0.3 M7: `sensitive_key?/1` runs on every key of every payload
  # redaction touches — 11,711 calls inside one `Engine.decide`, and
  # `String.downcase/1` walked each key grapheme-by-grapheme through the
  # Unicode tables (the single largest `String.Unicode.downcase/3` caller in
  # the turn). Map keys are overwhelmingly already-lowercase ASCII atoms, so
  # classify the bytes once: a pure-ASCII binary with no `A-Z` is already its
  # own downcase and is returned untouched, a pure-ASCII binary with `A-Z`
  # lowers byte-wise (identical to `String.downcase/1` on ASCII, which has no
  # multi-codepoint or locale-dependent foldings below U+0080), and anything
  # with a byte >= 0x80 falls back to `String.downcase/1` unchanged.
  defp downcase_key(binary) do
    case ascii_case(binary, false) do
      :lower -> binary
      :mixed -> ascii_downcase(binary, <<>>)
      :non_ascii -> String.downcase(binary)
    end
  end

  defp ascii_case(<<c, rest::binary>>, upper?) when c < 0x80 do
    ascii_case(rest, upper? or (c >= ?A and c <= ?Z))
  end

  defp ascii_case(<<>>, true), do: :mixed
  defp ascii_case(<<>>, false), do: :lower
  defp ascii_case(_binary, _upper?), do: :non_ascii

  defp ascii_downcase(<<c, rest::binary>>, acc) when c >= ?A and c <= ?Z do
    ascii_downcase(rest, <<acc::binary, c + 32>>)
  end

  defp ascii_downcase(<<c, rest::binary>>, acc), do: ascii_downcase(rest, <<acc::binary, c>>)
  defp ascii_downcase(<<>>, acc), do: acc

  # M7 generalization of the M8.8 memo: every literal list here is
  # compile-constant, so a cached compiled pattern never needs invalidation.
  defp compiled_pattern(name, literals) do
    key = {__MODULE__, name}

    case :persistent_term.get(key, nil) do
      nil ->
        pattern = :binary.compile_pattern(literals)
        :persistent_term.put(key, pattern)
        pattern

      pattern ->
        pattern
    end
  end

  defp may_match?(value, name, literals) do
    :binary.match(value, compiled_pattern(name, literals)) != :nomatch
  end

  defp redact_authorization_line(value) do
    if may_match?(value, :authorization_markers, @authorization_markers) do
      Regex.replace(~r/(authorization:\s*)(bearer\s+)?[^\s\r\n]+/i, value, "\\1\\2#{@redacted}")
    else
      value
    end
  end

  defp redact_cookie_line(value) do
    if may_match?(value, :cookie_markers, @cookie_markers) do
      Regex.replace(~r/((set-cookie|cookie):\s*)[^\r\n]+/i, value, "\\1#{@redacted}")
    else
      value
    end
  end

  defp redact_bearer_value(value) do
    if may_match?(value, :bearer_markers, @bearer_markers) do
      Regex.replace(~r/\b(bearer\s+)[^\s\r\n]+/i, value, "\\1#{@redacted}")
    else
      value
    end
  end

  defp redact_secret_shapes(value) do
    if may_match?(value, :secret_shape_markers, @secret_shape_markers) do
      Enum.reduce(@secret_value_patterns, value, fn pattern, acc ->
        Regex.replace(pattern, acc, @redacted)
      end)
    else
      value
    end
  end

  defp redact_phone_numbers(value) do
    if may_match?(value, :phone_markers, @phone_markers) do
      Regex.replace(@phone_value_pattern, value, "\\1#{@phone_redaction}")
    else
      value
    end
  end

  defp redact_url(value) do
    if may_match?(value, :url_markers, @url_markers) do
      redact_parsed_url(value)
    else
      value
    end
  end

  defp redact_parsed_url(value) do
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
