defmodule AllbertAssist.Channels.Signal.Doctor do
  @moduledoc false

  alias AllbertAssist.Channels
  alias AllbertAssist.Channels.Signal.Adapter
  alias AllbertAssist.Channels.Signal.Client
  alias AllbertAssist.Channels.Signal.Daemon
  alias AllbertAssist.Paths
  alias AllbertAssist.Runtime.Redactor

  @state_path Path.join(["channels", "signal", "doctor", "state.json"])

  def diagnose(opts \\ []) do
    with {:ok, settings} <- Channels.channel_settings("signal") do
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
    release_decision = Channels.channel_release_decision("signal")
    adapter_status = transport_status(opts)

    unless release_decision.live_use_allowed? do
      diagnostics = [:implemented_not_released]

      %{
        status: :implemented_not_released,
        release_status: release_decision.release_status,
        release_decision: release_decision,
        auth_ok: true,
        endpoint_ok: false,
        adapter_status: adapter_status,
        control_mode: Map.get(settings, "control_mode", "socket"),
        control_local_only: false,
        account_configured: configured?(Map.get(settings, "account_identifier")),
        local_aci_configured: configured?(Map.get(settings, "local_aci")),
        identity_count: length(Map.get(settings, "identity_map", [])),
        diagnostics: diagnostics,
        checked_at: DateTime.utc_now() |> DateTime.to_iso8601()
      }
    else
      run_live_checks(settings, opts, release_decision, adapter_status)
    end
  end

  defp run_live_checks(settings, opts, release_decision, adapter_status) do
    custody = Daemon.ensure_custody!(settings)
    control = Daemon.control_diagnostics(settings)
    diagnostics = settings_diagnostics(settings) ++ control.diagnostics
    client_opts = client_opts(settings, opts)

    endpoint =
      case Keyword.get(opts, :skip_client_check?, false) do
        true -> :ok
        false -> Client.health_check(client_opts)
      end

    %{
      status: doctor_status(diagnostics, endpoint),
      release_status: release_decision.release_status,
      release_decision: release_decision,
      auth_ok: auth_ok?(control),
      endpoint_ok: endpoint == :ok and control.ok?,
      adapter_status: adapter_status,
      control_mode: Map.get(settings, "control_mode", "socket"),
      control_local_only: control.local_only?,
      data_dir: Redactor.redact(custody.data_dir),
      data_dir_mode: custody.directory_mode,
      socket_mode: Map.get(control, :socket_mode),
      key_file_modes: custody.key_files,
      account_configured: configured?(Map.get(settings, "account_identifier")),
      local_aci_configured: configured?(Map.get(settings, "local_aci")),
      identity_count: length(Map.get(settings, "identity_map", [])),
      diagnostics: diagnostics ++ endpoint_diagnostics(endpoint),
      checked_at: DateTime.utc_now() |> DateTime.to_iso8601()
    }
  end

  defp settings_diagnostics(settings) do
    settings
    |> AllbertSignal.Settings.Fragment.required_when_enabled()
    |> Kernel.++(aci_diagnostics(settings))
  end

  defp aci_diagnostics(settings) do
    settings
    |> Map.get("allowed_aci_ids", [])
    |> Enum.reject(&AllbertAssist.Channels.Signal.Parser.valid_aci?/1)
    |> case do
      [] -> []
      _invalid -> [:invalid_allowed_aci]
    end
  end

  defp client_opts(settings, opts) do
    opts
    |> Keyword.get_lazy(:client_opts, fn ->
      Application.get_env(:allbert_assist, :signal_doctor_client_opts, [])
    end)
    |> then(&Daemon.client_opts(settings, &1))
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

  defp doctor_status([], :ok), do: :ok
  defp doctor_status(_diagnostics, :ok), do: :warning
  defp doctor_status(_diagnostics, {:error, _reason}), do: :error

  defp auth_ok?(%{mode: "loopback_http", auth_configured?: configured?}), do: configured?
  defp auth_ok?(_control), do: true

  defp endpoint_diagnostics(:ok), do: []
  defp endpoint_diagnostics({:error, reason}), do: [normalize_reason(reason)]

  defp normalize_reason(reason) when is_atom(reason), do: reason
  defp normalize_reason(reason), do: inspect(Redactor.redact(reason))

  defp configured?(value), do: is_binary(value) and String.trim(value) != ""

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
