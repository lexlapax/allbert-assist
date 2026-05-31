defmodule AllbertBrowser.Cache do
  @moduledoc false

  alias AllbertAssist.Jobs
  alias AllbertAssist.Paths
  alias AllbertAssist.Settings

  @sweep_job_name "Allbert Browser cache sweep"

  def put(session_id, kind, content, opts \\ []) when is_binary(session_id) and is_binary(kind) do
    bytes = IO.iodata_to_binary(content)
    hash = :crypto.hash(:sha256, bytes) |> Base.encode16(case: :lower)
    ext = Keyword.get(opts, :ext, ".bin")
    file = Path.join(session_root(session_id), "#{hash}#{ext}")
    metadata_file = file <> ".json"
    now = DateTime.utc_now() |> DateTime.to_iso8601()

    metadata =
      %{
        ref: "cache://browser/#{session_id}/#{Path.basename(file)}",
        path: file,
        session_id: session_id,
        kind: kind,
        bytes: byte_size(bytes),
        sha256: hash,
        created_at: now
      }
      |> Map.merge(Map.new(Keyword.get(opts, :metadata, %{})))

    File.mkdir_p!(Path.dirname(file))
    File.write!(file, bytes)
    File.write!(metadata_file, Jason.encode!(metadata))
    {:ok, metadata}
  end

  def latest_artifacts(opts \\ []) do
    limit = Keyword.get(opts, :limit, 10)

    root()
    |> Path.join("*/*.json")
    |> Path.wildcard()
    |> Enum.map(&read_metadata/1)
    |> Enum.reject(&is_nil/1)
    |> Enum.sort_by(&Map.get(&1, :created_at, ""), :desc)
    |> Enum.take(limit)
  end

  def sweep_expired(opts \\ []) do
    max_age_ms = Keyword.get(opts, :max_age_ms) || setting("browser.cache.max_age_ms", 86_400_000)
    now_ms = System.system_time(:millisecond)

    root()
    |> Path.join("*/*")
    |> Path.wildcard()
    |> Enum.reject(&String.ends_with?(&1, ".json"))
    |> Enum.reduce({:ok, 0}, fn path, {:ok, count} ->
      if expired?(path, now_ms, max_age_ms) do
        File.rm(path)
        File.rm(path <> ".json")
        {:ok, count + 1}
      else
        {:ok, count}
      end
    end)
  end

  def ensure_sweep_job do
    status = if setting("browser.cache.sweep.schedule", "paused") == "operator_approved", do: "active", else: "paused"

    case Enum.find(Jobs.list_jobs("local", limit: 100), &(&1.name == @sweep_job_name)) do
      nil ->
        Jobs.create_job(%{
          name: @sweep_job_name,
          description: "Sweeps expired Browser cache artifacts.",
          target_type: "registered_action",
          target: %{action_name: "browser_sweep_cache", params: %{}},
          schedule: %{kind: "daily", at: "03:00"},
          timezone: "UTC",
          status: status,
          user_id: "local",
          app_id: "allbert_browser"
        })

      job ->
        if job.status == status, do: {:ok, job}, else: Jobs.update_job(job, %{status: status})
    end
  end

  def root, do: Path.join([Paths.cache_root(), "browser"])
  def session_root(session_id), do: Path.join(root(), safe_session_id(session_id))

  defp read_metadata(path) do
    with {:ok, body} <- File.read(path),
         {:ok, metadata} <- Jason.decode(body, keys: :atoms) do
      metadata
    else
      _error -> nil
    end
  end

  defp expired?(path, now_ms, max_age_ms) do
    case File.stat(path, time: :posix) do
      {:ok, %{mtime: mtime}} -> now_ms - mtime * 1_000 > max_age_ms
      {:error, _reason} -> false
    end
  end

  defp setting(key, fallback) do
    case Settings.get(key) do
      {:ok, value} -> value
      {:error, _reason} -> fallback
    end
  end

  defp safe_session_id(session_id), do: String.replace(session_id, ~r/[^A-Za-z0-9_.-]/, "_")
end
