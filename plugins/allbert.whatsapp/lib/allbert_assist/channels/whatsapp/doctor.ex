defmodule AllbertAssist.Channels.WhatsApp.Doctor do
  @moduledoc false

  alias AllbertAssist.Channels
  alias AllbertAssist.Channels.WhatsApp.Adapter
  alias AllbertAssist.Channels.WhatsApp.Client
  alias AllbertAssist.Paths
  alias AllbertAssist.Runtime.Redactor
  alias AllbertAssist.Settings.Secrets

  @state_path Path.join(["channels", "whatsapp", "doctor", "state.json"])

  def diagnose(opts \\ []) do
    with {:ok, settings} <- Channels.channel_settings("whatsapp") do
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
    adapter_status = transport_status(opts)

    with {:ok, phone_number_id} <- phone_number_id(settings),
         {:ok, access_token} <- resolve_access_token(access_token_ref),
         {:ok, phone} <-
           Client.phone_number(access_token, phone_number_id, client_opts(settings, opts)) do
      %{
        status: doctor_status(diagnostics),
        auth_ok: true,
        endpoint_ok: true,
        adapter_status: adapter_status,
        phone_number_id: Redactor.redact("+" <> phone_number_id),
        display_phone_number: Redactor.redact(Map.get(phone, "display_phone_number")),
        verified_name: Map.get(phone, "verified_name"),
        quality_rating: Map.get(phone, "quality_rating"),
        webhook_enabled: Map.get(settings, "webhook_enabled", false),
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
          adapter_status: adapter_status,
          phone_number_id: redacted_phone_number_id(settings),
          webhook_enabled: Map.get(settings, "webhook_enabled", false),
          credential_status: Secrets.status(access_token_ref),
          diagnostics: diagnostics ++ [normalize_reason(reason)],
          checked_at: DateTime.utc_now() |> DateTime.to_iso8601()
        }
    end
  end

  defp settings_diagnostics(settings) do
    []
    |> require_present(settings, "phone_number_id", :missing_phone_number_id)
    |> require_present(settings, "access_token_ref", :missing_access_token_ref)
    |> maybe_add(not Map.get(settings, "webhook_enabled", false), :webhook_disabled)
    |> maybe_add(Map.get(settings, "identity_map", []) == [], :missing_identity_map)
    |> maybe_add(Map.get(settings, "response_style") != "always", :unsupported_response_style)
  end

  defp phone_number_id(settings) do
    case Map.get(settings, "phone_number_id") do
      value when is_binary(value) ->
        value = String.trim(value)
        if value == "", do: {:error, :missing_phone_number_id}, else: {:ok, value}

      _value ->
        {:error, :missing_phone_number_id}
    end
  end

  defp resolve_access_token(secret_ref) do
    case Secrets.get_secret(secret_ref) do
      {:ok, value} when is_binary(value) ->
        value = String.trim(value)
        if value == "", do: {:error, :missing_whatsapp_access_token}, else: {:ok, value}

      _other ->
        {:error, :missing_whatsapp_access_token}
    end
  end

  defp client_opts(settings, opts) do
    opts
    |> Keyword.get_lazy(:client_opts, fn ->
      Application.get_env(:allbert_assist, :whatsapp_doctor_client_opts, [])
    end)
    |> Keyword.put_new(:api_version, Map.get(settings, "graph_api_version", "v23.0"))
  end

  defp transport_status(opts) do
    opts
    |> Keyword.get_lazy(:transport_status, &Adapter.status/0)
    |> normalize_status()
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

  defp auth_ok?({:whatsapp_error, 401, _body}), do: false
  defp auth_ok?(:missing_whatsapp_access_token), do: false
  defp auth_ok?(_reason), do: true

  defp normalize_reason({:whatsapp_error, 401, _body}), do: :token_rejected
  defp normalize_reason({:transport_error, _reason}), do: :network_unavailable
  defp normalize_reason({:whatsapp_http_policy_denied, _reason}), do: :http_policy_denied
  defp normalize_reason(reason) when is_atom(reason), do: reason
  defp normalize_reason(reason), do: inspect(Redactor.redact(reason))

  defp redacted_phone_number_id(settings) do
    case Map.get(settings, "phone_number_id") do
      value when is_binary(value) and value != "" -> Redactor.redact("+" <> value)
      _value -> nil
    end
  end

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
