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
          %{
            status: :error,
            live_check_status: :unavailable,
            checked_at: DateTime.to_iso8601(checked_at),
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

  defp ok_status(%{live_check_status: status}) when status in [:ok, "ok"], do: :ok
  defp ok_status(%{live_check_status: status}), do: {:error, {:doctor_not_ok, status}}
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

  defp persist(result) do
    File.mkdir_p!(Path.dirname(path()))
    File.write!(path(), Jason.encode!(result))
  end

  defp path, do: Path.join([Paths.home(), "cache", "browser", "doctor", "state.json"])
end
