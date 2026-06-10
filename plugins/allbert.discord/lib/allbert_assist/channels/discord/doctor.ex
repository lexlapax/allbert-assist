defmodule AllbertAssist.Channels.Discord.Doctor do
  @moduledoc false

  alias AllbertAssist.Channels
  alias AllbertAssist.Channels.Discord.Client
  alias AllbertAssist.Paths
  alias AllbertAssist.Settings.Secrets

  @state_path Path.join(["channels", "discord", "doctor", "state.json"])

  def diagnose(opts \\ []) do
    with {:ok, settings} <- Channels.channel_settings("discord") do
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
    diagnostics = AllbertDiscord.Settings.Fragment.required_when_enabled(settings)
    token_ref = Map.get(settings, "bot_token_ref")
    application_id = Map.get(settings, "application_id", "")

    case Client.users_me(token_ref, Keyword.get(opts, :client_opts, [])) do
      {:ok, bot} ->
        %{
          status: if(diagnostics == [], do: :ok, else: :warning),
          auth_ok: true,
          endpoint_ok: true,
          gateway_status: :stub,
          bot_id: Map.get(bot, "id"),
          bot_username: Map.get(bot, "username"),
          application_id: application_id,
          credential_status: Secrets.status(token_ref),
          diagnostics: diagnostics,
          checked_at: DateTime.utc_now() |> DateTime.to_iso8601()
        }

      {:error, reason} ->
        %{
          status: :error,
          auth_ok: auth_ok?(reason),
          endpoint_ok: false,
          gateway_status: :stub,
          application_id: application_id,
          credential_status: Secrets.status(token_ref),
          diagnostics: diagnostics ++ [normalize_reason(reason)],
          checked_at: DateTime.utc_now() |> DateTime.to_iso8601()
        }
    end
  end

  defp write_state(result) do
    path = state_path()
    File.mkdir_p!(Path.dirname(path))
    File.write!(path, Jason.encode!(stringify(result), pretty: true))
    :ok
  end

  defp auth_ok?({:discord_error, 401, _body}), do: false
  defp auth_ok?(_reason), do: true

  defp normalize_reason({:discord_error, 401, _body}), do: :token_rejected
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
