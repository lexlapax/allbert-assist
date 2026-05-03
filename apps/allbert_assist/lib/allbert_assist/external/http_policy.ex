defmodule AllbertAssist.External.HttpPolicy do
  @moduledoc """
  Fail-closed policy checks for v0.10 confirmed external HTTP requests.
  """

  alias AllbertAssist.External.RequestSpec

  @metadata_hosts ~w(metadata.google.internal metadata)

  @spec validate(RequestSpec.t()) :: :ok | {:error, term()}
  def validate(%RequestSpec{} = spec) do
    with :ok <- enabled(spec),
         :ok <- profile_enabled(spec),
         :ok <- scheme_allowed(spec),
         :ok <- credentials_absent(spec),
         :ok <- method_allowed(spec),
         :ok <- host_present(spec),
         :ok <- host_not_blocked(spec),
         :ok <- public_host(spec),
         :ok <- host_allowed(spec),
         :ok <- path_allowed(spec),
         :ok <- redirects_allowed(spec),
         :ok <- retry_allowed(spec) do
      :ok
    end
  end

  defp enabled(%{enabled?: true}), do: :ok
  defp enabled(_spec), do: {:error, :external_services_disabled}

  defp profile_enabled(%{profile_enabled?: true}), do: :ok
  defp profile_enabled(%{profile: profile}), do: {:error, {:external_profile_disabled, profile}}

  defp scheme_allowed(%{uri: %{scheme: scheme}}) when scheme in ["http", "https"], do: :ok
  defp scheme_allowed(%{uri: %{scheme: scheme}}), do: {:error, {:unsupported_scheme, scheme}}

  defp credentials_absent(%{uri: %{userinfo: nil}}), do: :ok
  defp credentials_absent(%{uri: %{userinfo: ""}}), do: :ok
  defp credentials_absent(_spec), do: {:error, :url_credentials_not_allowed}

  defp method_allowed(%{method: method, allowed_methods: methods}) do
    if method in methods, do: :ok, else: {:error, {:method_not_allowed, method}}
  end

  defp host_present(%{host: host}) when is_binary(host) and host != "", do: :ok
  defp host_present(_spec), do: {:error, :missing_host}

  defp host_not_blocked(%{host: host, blocked_hosts: blocked}) do
    if host_matches?(host, blocked), do: {:error, {:blocked_host, host}}, else: :ok
  end

  defp host_allowed(%{host: host, allowed_hosts: allowed}) do
    cond do
      allowed in [nil, []] -> {:error, {:host_not_allowlisted, host}}
      host_matches?(host, allowed) -> :ok
      true -> {:error, {:host_not_allowlisted, host}}
    end
  end

  defp public_host(%{host: host}) do
    cond do
      host in @metadata_hosts ->
        {:error, {:metadata_host_denied, host}}

      host in ["localhost", "localhost.localdomain"] ->
        {:error, {:private_host_denied, host}}

      ip = parse_ip(host) ->
        if private_ip?(ip), do: {:error, {:private_host_denied, host}}, else: :ok

      true ->
        :ok
    end
  end

  defp path_allowed(%{path: path, allowed_paths: allowed}) do
    if Enum.any?(allowed || [], &path_matches?(path, &1)) do
      :ok
    else
      {:error, {:path_not_allowed, path}}
    end
  end

  defp redirects_allowed(%{allow_redirects?: false, max_redirects: 0}), do: :ok
  defp redirects_allowed(%{allow_redirects?: true}), do: :ok
  defp redirects_allowed(_spec), do: {:error, :redirect_policy_invalid}

  defp retry_allowed(%{retry_policy: policy}) when policy in ["none", "safe_idempotent"], do: :ok
  defp retry_allowed(%{retry_policy: policy}), do: {:error, {:retry_policy_invalid, policy}}

  defp host_matches?(_host, ["*" | _rest]), do: true

  defp host_matches?(host, patterns) do
    Enum.any?(patterns || [], fn pattern ->
      pattern = String.downcase(to_string(pattern))

      cond do
        pattern == "*" ->
          true

        String.starts_with?(pattern, "*.") ->
          String.ends_with?(host, String.trim_leading(pattern, "*"))

        true ->
          host == pattern
      end
    end)
  end

  defp path_matches?(_path, "*"), do: true
  defp path_matches?(_path, "/"), do: true
  defp path_matches?(path, prefix), do: String.starts_with?(path, prefix)

  defp parse_ip(host) do
    host
    |> to_charlist()
    |> :inet.parse_address()
    |> case do
      {:ok, ip} -> ip
      {:error, _reason} -> nil
    end
  end

  defp private_ip?({10, _, _, _}), do: true
  defp private_ip?({127, _, _, _}), do: true
  defp private_ip?({169, 254, _, _}), do: true
  defp private_ip?({172, second, _, _}) when second >= 16 and second <= 31, do: true
  defp private_ip?({192, 168, _, _}), do: true
  defp private_ip?({0, _, _, _}), do: true
  defp private_ip?({100, second, _, _}) when second >= 64 and second <= 127, do: true
  defp private_ip?({first, _, _, _}) when first >= 224, do: true
  defp private_ip?({0, 0, 0, 0, 0, 0, 0, 1}), do: true

  defp private_ip?({first, _, _, _, _, _, _, _}) when Bitwise.band(first, 0xFE00) == 0xFC00,
    do: true

  defp private_ip?({first, _, _, _, _, _, _, _}) when Bitwise.band(first, 0xFFC0) == 0xFE80,
    do: true

  defp private_ip?({first, _, _, _, _, _, _, _}) when Bitwise.band(first, 0xFF00) == 0xFF00,
    do: true

  defp private_ip?(_ip), do: false
end
