defmodule AllbertBrowser.Cache do
  @moduledoc false

  alias AllbertAssist.Jobs
  alias AllbertAssist.Paths
  alias AllbertAssist.Settings

  @sweep_job_name "Allbert Browser cache sweep"

  def put(session_id, kind, content, opts \\ []) when is_binary(session_id) and is_binary(kind) do
    bytes = IO.iodata_to_binary(content)
    max_bytes = setting("browser.cache.max_bytes", 33_554_432)

    if byte_size(bytes) > max_bytes do
      {:error, :cache_artifact_too_large}
    else
      put_bounded(session_id, kind, bytes, opts, max_bytes)
    end
  end

  defp put_bounded(session_id, kind, bytes, opts, max_bytes) do
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
    _ = enforce_max_bytes(max_bytes, file)
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

  def fetch(ref) when is_binary(ref) do
    with {:ok, session_id, filename} <- parse_ref(ref),
         metadata_path <- Path.join(session_root(session_id), "#{filename}.json"),
         {:ok, metadata} <- read_metadata_file(metadata_path),
         :ok <- validate_metadata_ref(metadata, ref, session_id, filename) do
      {:ok, metadata}
    end
  end

  def fetch(_ref), do: {:error, :invalid_cache_ref}

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
    |> case do
      {:ok, count} ->
        {:ok, size_count} = enforce_max_bytes(setting("browser.cache.max_bytes", 33_554_432))
        {:ok, count + size_count}
    end
  end

  def ensure_sweep_job do
    status =
      if setting("browser.cache.sweep.schedule", "paused") == "operator_approved",
        do: "active",
        else: "paused"

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
    case read_metadata_file(path) do
      {:ok, metadata} -> metadata
      {:error, _reason} -> nil
    end
  end

  defp read_metadata_file(path) do
    with {:ok, body} <- File.read(path),
         {:ok, metadata} <- Jason.decode(body, keys: :atoms) do
      {:ok, metadata}
    else
      {:error, reason} -> {:error, reason}
    end
  end

  defp enforce_max_bytes(max_bytes, protected_path \\ nil) do
    artifacts =
      cache_artifacts()
      |> Enum.sort_by(fn artifact -> {artifact.path == protected_path, artifact.created_at} end)

    total = Enum.reduce(artifacts, 0, &(&1.bytes + &2))

    if total <= max_bytes do
      {:ok, 0}
    else
      evict_until_bounded(artifacts, total, max_bytes, 0)
    end
  end

  defp evict_until_bounded(_artifacts, total, max_bytes, count) when total <= max_bytes do
    {:ok, count}
  end

  defp evict_until_bounded([], _total, _max_bytes, count), do: {:ok, count}

  defp evict_until_bounded([artifact | rest], total, max_bytes, count) do
    File.rm(artifact.path)
    File.rm(artifact.metadata_path)
    evict_until_bounded(rest, total - artifact.bytes, max_bytes, count + 1)
  end

  defp cache_artifacts do
    root()
    |> Path.join("*/*.json")
    |> Path.wildcard()
    |> Enum.map(&artifact_from_metadata/1)
    |> Enum.reject(&is_nil/1)
    |> Enum.sort_by(& &1.created_at)
  end

  defp artifact_from_metadata(metadata_path) do
    metadata = read_metadata(metadata_path)
    path = metadata && Map.get(metadata, :path)

    cond do
      not is_binary(path) ->
        nil

      not File.exists?(path) ->
        nil

      true ->
        %{
          path: path,
          metadata_path: metadata_path,
          bytes: artifact_bytes(metadata, path),
          created_at: Map.get(metadata, :created_at, "")
        }
    end
  end

  defp artifact_bytes(metadata, path) do
    case Map.get(metadata, :bytes) do
      bytes when is_integer(bytes) and bytes >= 0 ->
        bytes

      _other ->
        case File.stat(path) do
          {:ok, stat} -> stat.size
          {:error, _reason} -> 0
        end
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

  defp parse_ref(ref) do
    case URI.parse(ref) do
      %URI{scheme: "cache", host: "browser", path: path, query: query, fragment: fragment}
      when query in [nil, ""] and fragment in [nil, ""] ->
        parse_ref_path(path, ref)

      _uri ->
        {:error, :invalid_cache_ref}
    end
  rescue
    _exception -> {:error, :invalid_cache_ref}
  end

  defp parse_ref_path(path, ref) do
    case path |> to_string() |> String.trim_leading("/") |> String.split("/", trim: true) do
      [session_id, filename] ->
        with :ok <- validate_safe_session_id(session_id),
             :ok <- validate_safe_filename(filename) do
          {:ok, session_id, filename}
        end

      _other ->
        {:error, {:invalid_cache_ref, ref}}
    end
  end

  defp validate_safe_session_id(session_id) do
    if safe_session_id(session_id) == session_id and session_id != "" do
      :ok
    else
      {:error, {:invalid_cache_session_id, session_id}}
    end
  end

  defp validate_safe_filename(filename) do
    if Regex.match?(~r/^[A-Za-z0-9_.-]+$/, filename) and filename not in ["", ".", ".."] do
      :ok
    else
      {:error, {:invalid_cache_filename, filename}}
    end
  end

  defp validate_metadata_ref(metadata, ref, session_id, filename) do
    path = Map.get(metadata, :path)

    cond do
      Map.get(metadata, :ref) != ref ->
        {:error, :cache_ref_mismatch}

      Map.get(metadata, :session_id) != session_id ->
        {:error, :cache_session_mismatch}

      not is_binary(path) ->
        {:error, :cache_path_missing}

      Path.basename(path) != filename ->
        {:error, :cache_path_mismatch}

      not File.exists?(path) ->
        {:error, :cache_artifact_missing}

      true ->
        :ok
    end
  end
end
