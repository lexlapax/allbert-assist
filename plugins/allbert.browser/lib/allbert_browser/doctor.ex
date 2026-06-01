defmodule AllbertBrowser.Doctor do
  @moduledoc false

  alias AllbertAssist.Paths
  alias AllbertAssist.Settings
  alias AllbertBrowser.Driver

  def run(opts \\ []) do
    checked_at = DateTime.utc_now()

    result =
      case Driver.verify(opts) do
        {:ok, details} ->
          %{
            status: :ok,
            live_check_status: :ok,
            checked_at: DateTime.to_iso8601(checked_at),
            last_verified_at: DateTime.to_iso8601(checked_at),
            details: details
          }

        {:error, reason} ->
          category = error_category(reason)

          %{
            status: :error,
            live_check_status: live_check_status(category),
            checked_at: DateTime.to_iso8601(checked_at),
            error_category: category,
            error: inspect(reason)
          }
      end

    :ok = persist(result)
    {:ok, result}
  end

  def last_result do
    path()
    |> File.read()
    |> case do
      {:ok, body} -> Jason.decode(body, keys: :atoms)
      {:error, :enoent} -> {:error, :not_run}
      {:error, reason} -> {:error, reason}
    end
  end

  def fresh_ok? do
    with {:ok, result} <- last_result(),
         :ok <- ok_status(result),
         :ok <- fresh?(result) do
      :ok
    end
  end

  defp ok_status(%{live_check_status: status}) do
    case normalize_status(status) do
      :ok -> :ok
      normalized -> {:error, {:doctor_not_ok, normalized}}
    end
  end

  defp ok_status(_result), do: {:error, :doctor_not_ok}

  defp fresh?(%{last_verified_at: timestamp}) when is_binary(timestamp) do
    with {:ok, checked_at, _offset} <- DateTime.from_iso8601(timestamp),
         {:ok, max_age_ms} <- Settings.get("browser.doctor.max_age_ms") do
      age_ms = DateTime.diff(DateTime.utc_now(), checked_at, :millisecond)
      if age_ms <= max_age_ms, do: :ok, else: {:error, :doctor_stale}
    else
      _error -> {:error, :doctor_stale}
    end
  end

  defp fresh?(_result), do: {:error, :doctor_stale}

  defp normalize_status(status) when status in [:ok, :degraded, :failed, :unavailable], do: status
  defp normalize_status("ok"), do: :ok
  defp normalize_status("degraded"), do: :degraded
  defp normalize_status("failed"), do: :failed
  defp normalize_status("unavailable"), do: :unavailable
  defp normalize_status(status), do: status

  defp persist(result) do
    File.mkdir_p!(Path.dirname(path()))
    File.write!(path(), Jason.encode!(result))
  end

  defp error_category(:node_unavailable), do: :node_unavailable
  defp error_category({:playwright_bridge_missing, _path}), do: :playwright_bridge_missing
  defp error_category({:playwright_bridge_start_failed, _reason}), do: :playwright_bridge_start_failed
  defp error_category(:playwright_bridge_timeout), do: :bridge_timeout
  defp error_category({:playwright_bridge_exited, _status}), do: :bridge_exited
  defp error_category(:playwright_bridge_unexpected_response), do: :bridge_protocol_error
  defp error_category({:playwright_bridge_invalid_response, _reason}), do: :bridge_protocol_error
  defp error_category({:playwright_bridge_command_failed, _reason}), do: :bridge_protocol_error
  defp error_category({:invalid_json, _message}), do: :bridge_protocol_error
  defp error_category({:unsupported_operation, _message}), do: :bridge_protocol_error

  defp error_category({:playwright_error, message}) when is_binary(message) do
    downcased = String.downcase(message)

    cond do
      String.contains?(downcased, "timeout") ->
        :browser_live_check_timeout

      String.contains?(downcased, "executable") or String.contains?(downcased, "launch") or
          String.contains?(downcased, "browser") ->
        :chromium_launch_failed

      true ->
        :playwright_runtime_error
    end
  end

  defp error_category({kind, _message}) when is_atom(kind), do: kind
  defp error_category(kind) when is_atom(kind), do: kind
  defp error_category(_reason), do: :unknown_browser_doctor_error

  defp live_check_status(category)
       when category in [:node_unavailable, :playwright_bridge_missing, :playwright_bridge_start_failed],
       do: :unavailable

  defp live_check_status(_category), do: :failed

  defp path, do: Path.join([Paths.home(), "cache", "browser", "doctor", "state.json"])
end
