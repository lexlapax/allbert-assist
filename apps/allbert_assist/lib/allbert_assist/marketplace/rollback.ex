defmodule AllbertAssist.Marketplace.Rollback do
  @moduledoc """
  Marketplace rollback pipeline.
  """

  alias AllbertAssist.Marketplace.Diagnostic
  alias AllbertAssist.Marketplace.Installed

  @spec rollback(String.t(), keyword()) :: {:ok, map()} | {:error, map()}
  def rollback(entry_id, opts \\ []) do
    Installed.with_lock(opts, fn ->
      with {:ok, state} <- Installed.read(opts),
           {:ok, record} <- installed_record(state, entry_id),
           :ok <- remove_target(record),
           :ok <- write_removed(state, record, opts) do
        {:ok, %{removed: record}}
      end
    end)
  end

  defp installed_record(%{"installed" => installed}, entry_id) do
    case Enum.find(installed, &(&1["entry_id"] == entry_id)) do
      nil ->
        {:error,
         Diagnostic.new(:not_installed, :not_installed, "marketplace entry is not installed",
           pointer: "/entry_id",
           details: %{entry_id: entry_id}
         )}

      record ->
        {:ok, record}
    end
  end

  defp remove_target(%{"install_target" => target}) do
    case File.rm_rf(target) do
      {:ok, _files} ->
        :ok

      {:error, reason, path} ->
        {:error,
         Diagnostic.new(
           :rollback_failed,
           :rollback_remove_failed,
           "marketplace install directory could not be removed",
           pointer: "/install_target",
           details: %{target: target, path: path, reason: inspect(reason)}
         )}
    end
  end

  defp write_removed(%{"installed" => installed} = state, record, opts) do
    remaining =
      Enum.reject(installed, fn candidate ->
        candidate["entry_id"] == record["entry_id"] and candidate["version"] == record["version"]
      end)

    state
    |> Map.put("installed", remaining)
    |> Installed.write(opts)
  end
end
