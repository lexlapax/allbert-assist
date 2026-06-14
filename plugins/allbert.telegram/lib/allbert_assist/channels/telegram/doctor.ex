defmodule AllbertAssist.Channels.Telegram.Doctor do
  @moduledoc false

  alias AllbertAssist.Channels
  alias AllbertAssist.Channels.Telegram.Adapter
  alias AllbertAssist.Channels.Telegram.Client
  alias AllbertAssist.Paths
  alias AllbertAssist.Settings.Secrets

  @state_path Path.join(["channels", "telegram", "doctor", "state.json"])

  def diagnose(opts \\ []) do
    with {:ok, settings} <- Channels.channel_settings("telegram") do
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
    token_ref = Map.get(settings, "bot_token_ref")
    poller_status = transport_status(opts)

    with {:ok, token} <- resolve_token(token_ref),
         {:ok, bot} <- Client.get_me(token, client_opts(opts)) do
      %{
        status: if(diagnostics == [], do: :ok, else: :warning),
        auth_ok: true,
        endpoint_ok: true,
        poller_status: poller_status,
        bot_id: Map.get(bot, "id"),
        bot_username: Map.get(bot, "username"),
        allowed_chat_count: length(Map.get(settings, "allowed_chat_ids", [])),
        allow_group_chats: Map.get(settings, "allow_group_chats", false),
        credential_status: Secrets.status(token_ref),
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
          allowed_chat_count: length(Map.get(settings, "allowed_chat_ids", [])),
          allow_group_chats: Map.get(settings, "allow_group_chats", false),
          credential_status: Secrets.status(token_ref),
          diagnostics: diagnostics ++ [normalize_reason(reason)],
          checked_at: DateTime.utc_now() |> DateTime.to_iso8601()
        }
    end
  end

  defp settings_diagnostics(settings) do
    []
    |> maybe_add(blank?(Map.get(settings, "bot_token_ref")), :missing_bot_token_ref)
    |> maybe_add(
      Map.get(settings, "allow_group_chats", false) and
        Map.get(settings, "allowed_chat_ids", []) == [],
      :missing_allowed_chat_ids
    )
  end

  defp resolve_token(token_ref) do
    case Secrets.get_secret(token_ref) do
      {:ok, token} when is_binary(token) ->
        token = String.trim(token)
        if token == "", do: {:error, :missing_bot_token}, else: {:ok, token}

      _other ->
        {:error, :missing_bot_token}
    end
  end

  defp client_opts(opts) do
    Keyword.get_lazy(opts, :client_opts, fn ->
      Application.get_env(:allbert_assist, :telegram_doctor_client_opts, [])
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

  defp maybe_add(diagnostics, true, diagnostic), do: diagnostics ++ [diagnostic]
  defp maybe_add(diagnostics, false, _diagnostic), do: diagnostics

  defp blank?(value), do: value in [nil, ""]

  defp auth_ok?({:telegram_error, 401, _body}), do: false
  defp auth_ok?(:missing_bot_token), do: false
  defp auth_ok?(_reason), do: true

  defp normalize_reason({:telegram_error, 401, _body}), do: :token_rejected
  defp normalize_reason({:transport_error, _reason}), do: :network_unavailable
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
