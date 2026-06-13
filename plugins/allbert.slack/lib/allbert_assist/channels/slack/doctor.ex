defmodule AllbertAssist.Channels.Slack.Doctor do
  @moduledoc false

  alias AllbertAssist.Channels
  alias AllbertAssist.Channels.Slack.Adapter
  alias AllbertAssist.Channels.Slack.Client
  alias AllbertAssist.Paths
  alias AllbertAssist.Settings.Secrets

  @state_path Path.join(["channels", "slack", "doctor", "state.json"])

  def diagnose(opts \\ []) do
    with {:ok, settings} <- Channels.channel_settings("slack") do
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
    base_diagnostics = AllbertSlack.Settings.Fragment.required_when_enabled(settings)
    bot_token_ref = Map.get(settings, "bot_token_ref")
    app_token_ref = Map.get(settings, "app_token_ref")
    workspace_team_id = Map.get(settings, "workspace_team_id", "")
    socket_mode_status = transport_status(opts)

    case Client.auth_test_scopes(bot_token_ref, Keyword.get(opts, :client_opts, [])) do
      {:ok, %{auth: auth, scopes: scopes}} ->
        missing_scopes = Client.default_bot_scopes() -- scopes
        diagnostics = base_diagnostics ++ scope_diagnostics(missing_scopes)

        %{
          status: if(diagnostics == [], do: :ok, else: :warning),
          auth_ok: true,
          endpoint_ok: true,
          socket_mode_status: socket_mode_status,
          team: Map.get(auth, "team"),
          team_id: Map.get(auth, "team_id"),
          bot_user_id: Map.get(auth, "user_id"),
          bot_id: Map.get(auth, "bot_id"),
          workspace_team_id: workspace_team_id,
          granted_scopes: scopes,
          missing_scopes: missing_scopes,
          bot_credential_status: Secrets.status(bot_token_ref),
          app_credential_status: Secrets.status(app_token_ref),
          diagnostics: diagnostics,
          checked_at: DateTime.utc_now() |> DateTime.to_iso8601()
        }

      {:error, reason} ->
        %{
          status: :error,
          auth_ok: auth_ok?(reason),
          endpoint_ok: false,
          socket_mode_status: socket_mode_status,
          workspace_team_id: workspace_team_id,
          bot_credential_status: Secrets.status(bot_token_ref),
          app_credential_status: Secrets.status(app_token_ref),
          diagnostics: base_diagnostics ++ [normalize_reason(reason)],
          checked_at: DateTime.utc_now() |> DateTime.to_iso8601()
        }
    end
  end

  # Live Socket Mode status from the running adapter, normalized to a plain atom
  # so the redacted envelope never carries an internal reason term. Injectable
  # via opts for deterministic tests.
  defp transport_status(opts) do
    opts
    |> Keyword.get_lazy(:transport_status, fn -> Adapter.status() end)
    |> normalize_status()
  end

  defp normalize_status(:running), do: :running
  defp normalize_status(:disabled), do: :disabled
  defp normalize_status(:not_started), do: :not_started
  defp normalize_status(:unavailable), do: :unavailable
  defp normalize_status({:error, _reason}), do: :error
  defp normalize_status({:not_started, _reason}), do: :not_started
  defp normalize_status(_other), do: :unknown

  defp scope_diagnostics([]), do: []
  defp scope_diagnostics(_missing), do: [:missing_bot_scopes]

  defp write_state(result) do
    path = state_path()
    File.mkdir_p!(Path.dirname(path))
    File.write!(path, Jason.encode!(stringify(result), pretty: true))
    :ok
  end

  defp auth_ok?({:slack_error, "invalid_auth"}), do: false
  defp auth_ok?(_reason), do: true

  defp normalize_reason({:slack_error, "invalid_auth"}), do: :token_rejected
  defp normalize_reason({:transport_error, _reason}), do: :network_unavailable
  defp normalize_reason(reason) when is_atom(reason), do: reason
  defp normalize_reason(reason), do: inspect(reason)

  defp stringify(map) when is_map(map) do
    Map.new(map, fn {key, value} -> {to_string(key), stringify(value)} end)
  end

  defp stringify(list) when is_list(list), do: Enum.map(list, &stringify/1)
  defp stringify(value) when is_atom(value), do: Atom.to_string(value)
  defp stringify(value), do: value
end
