defmodule AllbertAssist.Channels.Matrix.Doctor do
  @moduledoc false

  alias AllbertAssist.Channels
  alias AllbertAssist.Channels.Matrix.Adapter
  alias AllbertAssist.Channels.Matrix.Client
  alias AllbertAssist.Paths
  alias AllbertAssist.Settings.Secrets

  @state_path Path.join(["channels", "matrix", "doctor", "state.json"])

  def diagnose(opts \\ []) do
    with {:ok, settings} <- Channels.channel_settings("matrix") do
      result = run_checks(settings, opts)
      :ok = write_state(result)
      {:ok, result}
    end
  end

  def read_state do
    path = state_path()

    with true <- File.regular?(path),
         {:ok, body} <- File.read(path),
         {:ok, decoded} <- Jason.decode(body) do
      {:ok, decoded}
    else
      _other -> {:error, :not_found}
    end
  end

  def state_path, do: Path.join(Paths.cache_root(), @state_path)

  defp run_checks(settings, opts) do
    diagnostics = settings_diagnostics(settings)
    access_token_ref = Map.get(settings, "access_token_ref")
    poller_status = transport_status(opts)

    with {:ok, homeserver_url} <- homeserver_url(settings),
         {:ok, access_token} <- resolve_access_token(access_token_ref),
         {:ok, account} <- Client.whoami(homeserver_url, access_token, client_opts(opts)) do
      %{
        status: doctor_status(diagnostics),
        auth_ok: true,
        endpoint_ok: true,
        poller_status: poller_status,
        homeserver_url: homeserver_url,
        user_id: Map.get(account, "user_id"),
        device_id: Map.get(account, "device_id"),
        allowed_room_count: length(Map.get(settings, "allowed_room_ids", [])),
        credential_status: Secrets.status(access_token_ref),
        diagnostics: diagnostics,
        checked_at: DateTime.utc_now() |> DateTime.to_iso8601()
      }
    else
      {:error, reason} ->
        %{
          status: :error,
          auth_ok: auth_ok?(reason),
          endpoint_ok: false,
          poller_status: poller_status,
          homeserver_url: Map.get(settings, "homeserver_url"),
          allowed_room_count: length(Map.get(settings, "allowed_room_ids", [])),
          credential_status: Secrets.status(access_token_ref),
          diagnostics: diagnostics ++ [normalize_reason(reason)],
          checked_at: DateTime.utc_now() |> DateTime.to_iso8601()
        }
    end
  end

  defp settings_diagnostics(settings) do
    []
    |> require_present(settings, "homeserver_url", :missing_homeserver_url)
    |> require_present(settings, "access_token_ref", :missing_access_token_ref)
    |> maybe_add(Map.get(settings, "allowed_room_ids", []) == [], :missing_allowed_room_ids)
    |> maybe_add(Map.get(settings, "response_style") != "always", :unsupported_response_style)
  end

  defp homeserver_url(settings) do
    case Map.get(settings, "homeserver_url") do
      value when is_binary(value) ->
        value = String.trim(value)
        if value == "", do: {:error, :missing_homeserver_url}, else: {:ok, value}

      _value ->
        {:error, :missing_homeserver_url}
    end
  end

  defp resolve_access_token(secret_ref) do
    case Secrets.get_secret(secret_ref) do
      {:ok, value} when is_binary(value) ->
        value = String.trim(value)
        if value == "", do: {:error, :missing_matrix_access_token}, else: {:ok, value}

      _other ->
        {:error, :missing_matrix_access_token}
    end
  end

  defp client_opts(opts) do
    Keyword.get_lazy(opts, :client_opts, fn ->
      Application.get_env(:allbert_assist, :matrix_doctor_client_opts, [])
    end)
  end

  defp transport_status(opts) do
    opts
    |> Keyword.get_lazy(:transport_status, &adapter_status/0)
    |> normalize_status()
  end

  defp adapter_status do
    case Process.whereis(Adapter) do
      nil ->
        :not_started

      pid ->
        pid
        |> :sys.get_state()
        |> case do
          %{enabled?: true} -> :running
          %{enabled?: false} -> :disabled
          _state -> :unknown
        end
    end
  catch
    :exit, _reason -> :unavailable
  end

  defp normalize_status(:running), do: :running
  defp normalize_status(:disabled), do: :disabled
  defp normalize_status(:not_started), do: :not_started
  defp normalize_status(:unavailable), do: :unavailable
  defp normalize_status({:error, _reason}), do: :error
  defp normalize_status(_other), do: :unknown

  defp doctor_status([]), do: :ok
  defp doctor_status(_diagnostics), do: :warning

  defp require_present(diagnostics, settings, key, diagnostic) do
    maybe_add(diagnostics, blank?(Map.get(settings, key)), diagnostic)
  end

  defp maybe_add(diagnostics, true, diagnostic), do: diagnostics ++ [diagnostic]
  defp maybe_add(diagnostics, false, _diagnostic), do: diagnostics

  defp blank?(value), do: value in [nil, ""]

  defp auth_ok?({:matrix_error, 401, _body}), do: false
  defp auth_ok?(:missing_matrix_access_token), do: false
  defp auth_ok?(_reason), do: true

  defp normalize_reason({:matrix_error, 401, _body}), do: :token_rejected
  defp normalize_reason({:transport_error, _reason}), do: :network_unavailable
  defp normalize_reason({:matrix_http_policy_denied, _reason}), do: :http_policy_denied
  defp normalize_reason(reason) when is_atom(reason), do: reason
  defp normalize_reason(reason), do: inspect(reason)

  defp write_state(result) do
    path = state_path()
    File.mkdir_p!(Path.dirname(path))
    File.write!(path, Jason.encode!(stringify(result), pretty: true))
    :ok
  end

  defp stringify(map) when is_map(map) do
    Map.new(map, fn {key, value} -> {to_string(key), stringify(value)} end)
  end

  defp stringify(list) when is_list(list), do: Enum.map(list, &stringify/1)
  defp stringify(value) when is_boolean(value), do: value
  defp stringify(nil), do: nil
  defp stringify(value) when is_atom(value), do: Atom.to_string(value)
  defp stringify(value), do: value
end
