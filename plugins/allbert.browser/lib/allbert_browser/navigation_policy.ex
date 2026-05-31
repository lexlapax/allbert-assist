defmodule AllbertBrowser.NavigationPolicy do
  @moduledoc false

  alias AllbertAssist.External.HttpPolicy
  alias AllbertAssist.External.RequestSpec
  alias AllbertAssist.Settings

  def preflight(url) when is_binary(url) do
    uri = URI.parse(url)

    spec = %RequestSpec{
      method: "GET",
      url: URI.to_string(uri),
      uri: uri,
      profile: "browser",
      host: String.downcase(uri.host || ""),
      path: uri.path || "/",
      query: uri.query,
      headers: [],
      body: nil,
      body_summary: %{present?: false, bytes: 0},
      timeout_ms: setting("browser.navigation.timeout_ms", 30_000),
      max_response_bytes: setting("browser.extraction.max_bytes", 1_048_576),
      allow_redirects?: false,
      max_redirects: 0,
      retry_policy: "none",
      redact_request_headers: [],
      redact_response_headers: [],
      enabled?: true,
      profile_enabled?: true,
      allowed_hosts: ["*"],
      blocked_hosts: setting("browser.navigation.denied_domains", []),
      allowed_paths: ["/"],
      allowed_methods: ["GET"]
    }

    HttpPolicy.validate(spec)
  end

  def preflight(_url), do: {:error, :invalid_url}

  defp setting(key, default) do
    case Settings.get(key) do
      {:ok, value} -> value
      _error -> default
    end
  end
end
