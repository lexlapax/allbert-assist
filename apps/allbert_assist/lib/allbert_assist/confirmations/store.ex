defmodule AllbertAssist.Confirmations.Store do
  @moduledoc false

  alias AllbertAssist.Confirmations.Record
  alias AllbertAssist.Paths
  alias AllbertAssist.Settings
  alias AllbertAssist.Settings.Store, as: SettingsStore
  alias AllbertAssist.Settings.YamlCodec

  def root, do: Paths.confirmations_root()
  def pending_root, do: Path.join(root(), "pending")
  def resolved_root, do: Path.join(root(), "resolved")
  def audit_root, do: Path.join(root(), "audit")

  def ensure_root! do
    root = root()

    [root, pending_root(), resolved_root(), audit_root()]
    |> Enum.each(&File.mkdir_p!/1)

    root
  end

  def create(attrs, opts \\ []) when is_map(attrs) and is_list(opts) do
    now = Keyword.get(opts, :now, DateTime.utc_now())
    ttl_minutes = Keyword.get(opts, :ttl_minutes, default_ttl_minutes())
    audit_path = audit_path(now)

    attrs = Map.put(attrs, :audit_path, audit_path)

    with {:ok, record} <- Record.new(attrs, now, ttl_minutes),
         :ok <- write_pending(record),
         {:ok, _path} <- append_audit(record, "requested", now) do
      {:ok, record}
    end
  end

  def read(id) when is_binary(id) do
    path = pending_path(id)

    if File.exists?(path) do
      read_record(path)
    else
      read_resolved(id)
    end
  end

  def list(opts \\ []) when is_list(opts) do
    status = Keyword.get(opts, :status, :pending)

    status
    |> paths_for_status()
    |> Enum.flat_map(&read_records/1)
    |> Enum.sort_by(&Map.get(&1, "requested_at", ""))
  end

  def resolve(id, status, resolution_attrs \\ %{}, opts \\ [])
      when is_binary(id) and is_map(resolution_attrs) and is_list(opts) do
    now = Keyword.get(opts, :now, DateTime.utc_now())

    with {:ok, record} <- read_pending(id),
         {:ok, resolved} <- Record.resolve(record, status, resolution_attrs, now),
         :ok <- write_resolved(resolved, now),
         :ok <- remove_pending(id),
         {:ok, _path} <- append_audit(resolved, Map.get(resolved, "status"), now) do
      {:ok, resolved}
    end
  end

  def expire(opts \\ []) when is_list(opts) do
    now = Keyword.get(opts, :now, DateTime.utc_now())
    resolution_attrs = Keyword.get(opts, :resolution_attrs, %{})

    expired =
      list(status: :pending)
      |> Enum.filter(&Record.expired?(&1, now))

    results =
      Enum.map(expired, fn record ->
        resolve(Map.fetch!(record, "id"), :expired, resolution_attrs, now: now)
      end)

    {:ok, results}
  end

  def pending_path(id), do: Path.join(pending_root(), "#{id}.yml")

  def resolved_path(id, now \\ DateTime.utc_now()) do
    month = Calendar.strftime(now, "%Y-%m")
    Path.join([resolved_root(), month, "#{id}.yml"])
  end

  def audit_path(now \\ DateTime.utc_now()) do
    now = DateTime.truncate(now, :second)
    Path.join(audit_root(), "#{Calendar.strftime(now, "%Y-%m")}.md")
  end

  defp read_pending(id) do
    path = pending_path(id)

    if File.exists?(path) do
      read_record(path)
    else
      {:error, {:confirmation_not_pending, id}}
    end
  end

  defp read_resolved(id) do
    resolved_root()
    |> Path.join("*")
    |> Path.join("#{id}.yml")
    |> Path.wildcard()
    |> List.first()
    |> case do
      nil -> {:error, {:confirmation_not_found, id}}
      path -> read_record(path)
    end
  end

  defp read_records(path) do
    path
    |> Path.join("**/*.yml")
    |> Path.wildcard()
    |> Enum.flat_map(fn path ->
      case read_record(path) do
        {:ok, record} -> [record]
        {:error, _reason} -> []
      end
    end)
  end

  defp read_record(path) do
    with {:ok, record} <- YamlCodec.read_file(path),
         :ok <- Record.validate(record) do
      {:ok, record}
    end
  end

  defp write_pending(record) do
    ensure_root!()
    record |> Map.fetch!("id") |> pending_path() |> write_record(record)
  end

  defp write_resolved(record, now) do
    ensure_root!()
    record |> Map.fetch!("id") |> resolved_path(now) |> write_record(record)
  end

  defp write_record(path, record) do
    SettingsStore.write_atomic(path, YamlCodec.encode!(record))
  end

  defp remove_pending(id) do
    case File.rm(pending_path(id)) do
      :ok -> :ok
      {:error, :enoent} -> :ok
      {:error, reason} -> {:error, {:confirmation_remove_failed, reason}}
    end
  end

  defp append_audit(record, event, now) do
    path = audit_path(now)
    File.mkdir_p!(Path.dirname(path))

    case File.write(path, render_audit(record, event, now), [:append]) do
      :ok -> {:ok, path}
      {:error, reason} -> {:error, {:confirmation_audit_failed, reason}}
    end
  end

  defp render_audit(record, event, now) do
    origin = Map.get(record, "origin", %{})
    resolution = Map.get(record, "operator_resolution", %{}) || %{}

    """

    ## #{DateTime.to_iso8601(DateTime.truncate(now, :second))} #{Map.get(record, "id")}

    - event: #{event}
    - status: #{Map.get(record, "status")}
    - target_action: #{get_in(record, ["target_action", "name"])}
    - target_permission: #{Map.get(record, "target_permission")}
    - origin_actor: #{Map.get(origin, "actor", "local")}
    - origin_channel: #{Map.get(origin, "channel", "unknown")}
    - resolver_actor: #{Map.get(resolution, "resolver_actor", "none")}
    - resolver_channel: #{Map.get(resolution, "resolver_channel", "none")}
    - resolver_surface: #{Map.get(resolution, "resolver_surface", "none")}
    - same_channel: #{Map.get(resolution, "same_channel?", "none")}
    - resolution_reason: #{Map.get(resolution, "resolution_reason", "none")}
    - decision_source: #{Map.get(resolution, "decision_source", "none")}
    - source_trace_id: #{Map.get(record, "source_trace_id", "none")}
    - audit_version: 1
    """
  end

  defp paths_for_status(:pending), do: [pending_root()]
  defp paths_for_status("pending"), do: [pending_root()]
  defp paths_for_status(:resolved), do: [resolved_root()]
  defp paths_for_status("resolved"), do: [resolved_root()]
  defp paths_for_status(:all), do: [pending_root(), resolved_root()]
  defp paths_for_status("all"), do: [pending_root(), resolved_root()]
  defp paths_for_status(_status), do: [pending_root()]

  defp default_ttl_minutes do
    case Settings.get("confirmations.default_ttl_minutes") do
      {:ok, ttl} when is_integer(ttl) -> ttl
      _other -> 1440
    end
  end
end
