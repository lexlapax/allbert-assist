defmodule AllbertBrowser.NetworkPolicy do
  @moduledoc """
  Per-session browser subresource policy.

  M2 exposes the policy as pure data/functions for the stub driver and later
  Playwright route interception. It is not a security boundary by itself; the
  browser actions decide when to invoke the driver.
  """

  alias AllbertAssist.External.HttpPolicy
  alias AllbertAssist.External.RequestSpec
  alias AllbertAssist.Settings

  def allow_subresource?(page_url, resource_url) do
    with :ok <- same_origin_or_cdn?(page_url, resource_url),
         :ok <- public_resource?(resource_url) do
      true
    else
      _error -> false
    end
  end

  defp same_origin_or_cdn?(page_url, resource_url) do
    page = URI.parse(page_url)
    resource = URI.parse(resource_url)

    cond do
      origin(page) == origin(resource) ->
        :ok

      resource.host in cdn_allowlist() ->
        :ok

      true ->
        {:error, :cross_origin_subresource_denied}
    end
  end

  defp public_resource?(url) do
    uri = URI.parse(url)

    %RequestSpec{
      method: "GET",
      url: URI.to_string(uri),
      uri: uri,
      profile: "browser_subresource",
      host: String.downcase(uri.host || ""),
      path: uri.path || "/",
      query: uri.query,
      headers: [],
      body: nil,
      body_summary: %{present?: false, bytes: 0},
      timeout_ms: 5_000,
      max_response_bytes: 1,
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
    |> HttpPolicy.validate()
  end

  defp origin(%URI{scheme: scheme, host: host, port: port}) do
    {scheme, String.downcase(host || ""), port}
  end

  defp cdn_allowlist, do: setting("browser.navigation.subresource_cdn_allowlist", [])

  defp setting(key, default) do
    case Settings.get(key) do
      {:ok, value} -> value
      _error -> default
    end
  end
end
