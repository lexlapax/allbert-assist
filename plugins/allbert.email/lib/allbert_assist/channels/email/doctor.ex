defmodule AllbertAssist.Channels.Email.Doctor do
  @moduledoc false

  alias AllbertAssist.Channels
  alias AllbertAssist.Channels.Email.Adapter
  alias AllbertAssist.Channels.Email.ImapClient
  alias AllbertAssist.Paths
  alias AllbertAssist.Settings.Secrets

  @state_path Path.join(["channels", "email", "doctor", "state.json"])

  def diagnose(opts \\ []) do
    with {:ok, settings} <- Channels.channel_settings("email") do
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
    imap_ref = Map.get(settings, "imap_password_ref")
    smtp_ref = Map.get(settings, "smtp_password_ref")
    poller_status = transport_status(opts)
    smtp_credential_status = Secrets.status(smtp_ref)

    case resolve_secret(imap_ref, :missing_imap_password) do
      {:ok, imap_password} ->
        case imap_probe(settings, imap_password, opts) do
          :ok ->
            endpoint_ok = smtp_credential_status == :configured

            %{
              status: doctor_status(endpoint_ok, diagnostics),
              auth_ok: endpoint_ok,
              endpoint_ok: endpoint_ok,
              imap_endpoint_ok: true,
              smtp_endpoint_ok: endpoint_ok,
              poller_status: poller_status,
              imap_mailbox: Map.get(settings, "imap_mailbox"),
              from_address: Map.get(settings, "from_address"),
              imap_credential_status: Secrets.status(imap_ref),
              smtp_credential_status: smtp_credential_status,
              diagnostics: smtp_diagnostics(smtp_credential_status, diagnostics),
              checked_at: DateTime.utc_now() |> DateTime.to_iso8601()
            }

          {:error, reason} ->
            error_result(settings, poller_status, imap_ref, smtp_ref, diagnostics, reason)
        end

      {:error, reason} ->
        error_result(settings, poller_status, imap_ref, smtp_ref, diagnostics, reason)
    end
  end

  defp settings_diagnostics(settings) do
    []
    |> require_present(settings, "imap_host", :missing_imap_host)
    |> require_present(settings, "smtp_host", :missing_smtp_host)
    |> require_present(settings, "imap_username", :missing_imap_username)
    |> require_present(settings, "smtp_username", :missing_smtp_username)
    |> require_present(settings, "from_address", :missing_from_address)
    |> require_present(settings, "imap_password_ref", :missing_imap_password_ref)
    |> require_present(settings, "smtp_password_ref", :missing_smtp_password_ref)
    |> maybe_add(Map.get(settings, "imap_ssl") != true, :plaintext_imap_rejected)
    |> maybe_add(Map.get(settings, "smtp_tls") != true, :plaintext_smtp_rejected)
  end

  defp imap_probe(settings, imap_password, opts) do
    client =
      Keyword.get(
        opts,
        :imap_client,
        Application.get_env(:allbert_assist, :email_doctor_imap_client, ImapClient)
      )

    with {:ok, conn} <-
           client.connect(
             Map.get(settings, "imap_host"),
             Map.get(settings, "imap_port"),
             imap_opts(settings, opts)
           ),
         {:ok, conn} <- client.login(conn, Map.get(settings, "imap_username"), imap_password),
         {:ok, conn} <- client.select_mailbox(conn, Map.get(settings, "imap_mailbox")),
         {:ok, _uids} <- client.search_unseen(conn) do
      _logout = client.logout(conn)
      :ok
    end
  end

  defp imap_opts(settings, opts) do
    opts
    |> Keyword.get(:imap_opts, Application.get_env(:allbert_assist, :email_doctor_imap_opts, []))
    |> Keyword.put_new(:ssl, Map.get(settings, "imap_ssl", true))
  end

  defp resolve_secret(secret_ref, reason) do
    case Secrets.get_secret(secret_ref) do
      {:ok, value} when is_binary(value) ->
        value = String.trim(value)
        if value == "", do: {:error, reason}, else: {:ok, value}

      _other ->
        {:error, reason}
    end
  end

  defp error_result(settings, poller_status, imap_ref, smtp_ref, diagnostics, reason) do
    %{
      status: :error,
      auth_ok: auth_ok?(reason),
      endpoint_ok: false,
      imap_endpoint_ok: false,
      smtp_endpoint_ok: Secrets.status(smtp_ref) == :configured,
      poller_status: poller_status,
      imap_mailbox: Map.get(settings, "imap_mailbox"),
      from_address: Map.get(settings, "from_address"),
      imap_credential_status: Secrets.status(imap_ref),
      smtp_credential_status: Secrets.status(smtp_ref),
      diagnostics: diagnostics ++ [normalize_reason(reason)],
      checked_at: DateTime.utc_now() |> DateTime.to_iso8601()
    }
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

  defp doctor_status(true, []), do: :ok
  defp doctor_status(true, _diagnostics), do: :warning
  defp doctor_status(false, _diagnostics), do: :error

  defp smtp_diagnostics(:configured, diagnostics), do: diagnostics
  defp smtp_diagnostics(_status, diagnostics), do: diagnostics ++ [:missing_smtp_password]

  defp require_present(diagnostics, settings, key, diagnostic) do
    maybe_add(diagnostics, blank?(Map.get(settings, key)), diagnostic)
  end

  defp maybe_add(diagnostics, true, diagnostic), do: diagnostics ++ [diagnostic]
  defp maybe_add(diagnostics, false, _diagnostic), do: diagnostics

  defp blank?(value), do: value in [nil, ""]

  defp auth_ok?(:missing_imap_password), do: false
  defp auth_ok?({:imap_command_failed, _response}), do: false
  defp auth_ok?(_reason), do: true

  defp normalize_reason({:imap_command_failed, _response}), do: :imap_login_or_mailbox_failed
  defp normalize_reason({:tcp_error, _reason}), do: :network_unavailable
  defp normalize_reason({:ssl_error, _reason}), do: :network_unavailable
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
