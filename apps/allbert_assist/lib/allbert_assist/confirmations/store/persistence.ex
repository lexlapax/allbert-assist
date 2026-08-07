defmodule AllbertAssist.Confirmations.Store.Persistence do
  @moduledoc """
  Durable confirmation persistence with an exact readiness boundary.

  Multi-file transitions are deliberately staged in memory and compensated in
  process. There is no recovery journal: confirmation YAML remains the durable
  authority, and a failed or stale epoch restores every touched path to its
  exact preimage before returning the failure.
  """

  alias AllbertAssist.Confirmations.ExternalRequestMetadata
  alias AllbertAssist.Confirmations.OnlineSkillMetadata
  alias AllbertAssist.Confirmations.PackageInstallMetadata
  alias AllbertAssist.Confirmations.Record
  alias AllbertAssist.Confirmations.ResourceMetadata
  alias AllbertAssist.Confirmations.ShellCommandMetadata
  alias AllbertAssist.Confirmations.SkillScriptMetadata
  alias AllbertAssist.Pack.EffectGuard
  alias AllbertAssist.Paths
  alias AllbertAssist.Runtime.Redactor
  alias AllbertAssist.Settings
  alias AllbertAssist.Settings.Store, as: SettingsStore
  alias AllbertAssist.Settings.YamlCodec
  alias AllbertAssist.Workspace.Emitters, as: WorkspaceEmitters

  @type effect_context :: %{required(:allbert_pack_epoch) => EffectGuard.epoch()}

  @doc false
  def root, do: Paths.confirmations_root()
  @doc false
  def pending_root, do: Path.join(root(), "pending")
  @doc false
  def resolved_root, do: Path.join(root(), "resolved")
  @doc false
  def audit_root, do: Path.join(root(), "audit")

  @doc false
  def ensure_root! do
    root = root()
    [root, pending_root(), resolved_root(), audit_root()] |> Enum.each(&File.mkdir_p!/1)
    root
  end

  @doc false
  def create(attrs, effect_context, opts \\ [])

  def create(attrs, effect_context, opts)
      when is_map(attrs) and is_map(effect_context) and is_list(opts) do
    now = Keyword.get(opts, :now, DateTime.utc_now())
    ttl_minutes = Keyword.get(opts, :ttl_minutes, default_ttl_minutes())
    binding_kind = Keyword.get(opts, :objective_binding_kind, :ordinary)
    audit = audit_path(now)

    with :ok <- validate_effect_context(effect_context),
         {:ok, record} <-
           Record.new(Map.put(attrs, :audit_path, audit), now, ttl_minutes, binding_kind),
         {:ok, audit_bytes} <- audit_bytes(audit, record, "requested", now),
         {:ok, _result} <-
           commit(
             [
               {:write, pending_path(Map.fetch!(record, "id")), YamlCodec.encode!(record)},
               {:write, audit, audit_bytes}
             ],
             effect_context,
             opts
           ) do
      WorkspaceEmitters.confirmation_requested(record)
      {:ok, record}
    end
  end

  def create(_attrs, _effect_context, _opts), do: {:error, :product_not_ready}

  @doc false
  def read(id) when is_binary(id) do
    path = pending_path(id)
    if File.exists?(path), do: read_record(path), else: read_resolved(id)
  end

  @doc false
  def list(opts \\ []) when is_list(opts) do
    opts
    |> Keyword.get(:status, :pending)
    |> paths_for_status()
    |> Enum.flat_map(&read_records/1)
    |> Enum.sort_by(&Map.get(&1, "requested_at", ""))
  end

  @doc false
  def resolve(id, status, resolution_attrs, effect_context, opts \\ [])

  def resolve(id, status, resolution_attrs, effect_context, opts)
      when is_binary(id) and is_map(resolution_attrs) and is_map(effect_context) and is_list(opts) do
    now = Keyword.get(opts, :now, DateTime.utc_now())

    with :ok <- validate_effect_context(effect_context),
         {:ok, record} <- read_pending(id),
         {:ok, resolved} <- Record.resolve(record, status, resolution_attrs, now),
         {:ok, stages} <- resolve_stages(record, resolved, now),
         {:ok, _result} <- commit(stages, effect_context, opts) do
      WorkspaceEmitters.confirmation_resolved(resolved)
      {:ok, resolved}
    end
  end

  def resolve(_id, _status, _attrs, _effect_context, _opts), do: {:error, :product_not_ready}

  @doc false
  def annotate_resolution(id, attrs, effect_context, opts \\ [])

  def annotate_resolution(id, attrs, effect_context, opts)
      when is_binary(id) and is_map(attrs) and is_map(effect_context) and is_list(opts) do
    now = Keyword.get(opts, :now, DateTime.utc_now())

    with :ok <- validate_effect_context(effect_context),
         {:ok, record, path} <- read_resolved_with_path(id),
         resolution when is_map(resolution) <- Map.get(record, "operator_resolution", %{}),
         updated_resolution <-
           resolution |> Map.merge(stringify_resolution_attrs(attrs)) |> Redactor.redact(),
         updated <- Map.put(record, "operator_resolution", updated_resolution),
         :ok <- Record.validate(updated),
         {:ok, audit_bytes} <- audit_bytes(audit_path(now), updated, "updated", now),
         {:ok, _result} <-
           commit(
             [
               {:write, path, YamlCodec.encode!(updated)},
               {:write, audit_path(now), audit_bytes}
             ],
             effect_context,
             opts
           ) do
      {:ok, updated}
    else
      nil -> {:error, {:confirmation_resolution_missing, id}}
      {:error, reason} -> {:error, reason}
    end
  end

  def annotate_resolution(_id, _attrs, _effect_context, _opts), do: {:error, :product_not_ready}

  @doc false
  def expire(effect_context, opts \\ [])

  def expire(effect_context, opts) when is_map(effect_context) and is_list(opts) do
    now = Keyword.get(opts, :now, DateTime.utc_now())
    attrs = Keyword.get(opts, :resolution_attrs, %{})

    with :ok <- validate_effect_context(effect_context),
         {:ok, expired} <- expired_records(now),
         {:ok, resolved} <- resolve_records(expired, attrs, now),
         {:ok, stages} <- expire_stages(expired, resolved, now),
         {:ok, _result} <- commit(stages, effect_context, opts) do
      Enum.each(resolved, &WorkspaceEmitters.confirmation_resolved/1)
      {:ok, Enum.map(resolved, &{:ok, &1})}
    end
  end

  def expire(_effect_context, _opts), do: {:error, :product_not_ready}

  @doc false
  def rebuild_projection(opts \\ []) when is_list(opts) do
    ensure_root!()
    now = Keyword.get(opts, :now, DateTime.utc_now())
    pending = list(status: :pending)

    {:ok,
     %{
       pending_ids: Enum.map(pending, &Map.fetch!(&1, "id")),
       pending_by_target: pending_by_target(pending),
       last_rebuilt_at: now |> DateTime.truncate(:second) |> DateTime.to_iso8601(),
       last_sweep_at: nil,
       last_command: :rebuild,
       last_result: {:ok, :rebuilt},
       last_error: nil
     }}
  end

  @doc false
  def pending_path(id), do: Path.join(pending_root(), "#{id}.yml")
  @doc false
  def resolved_path(id, now \\ DateTime.utc_now()),
    do: Path.join([resolved_root(), Calendar.strftime(now, "%Y-%m"), "#{id}.yml"])

  @doc false
  def audit_path(now \\ DateTime.utc_now()),
    do:
      Path.join(audit_root(), "#{Calendar.strftime(DateTime.truncate(now, :second), "%Y-%m")}.md")

  # Snapshot every target before the first mutation. Each write is atomic; a
  # delete is compensated by atomically restoring its original bytes.
  defp commit(stages, effect_context, opts) do
    with :ok <- validate_effect_context(effect_context),
         {:ok, preimages} <- capture_preimages(stages),
         :ok <- apply_stages(stages, preimages, effect_context, opts) do
      {:ok, :committed}
    end
  end

  defp apply_stages(stages, preimages, effect_context, opts) do
    Enum.reduce_while(Enum.with_index(stages, 1), :ok, fn {stage, index}, :ok ->
      case apply_stage(stage) do
        :ok ->
          with :ok <- run_stage_hook(opts, index, stage),
               :ok <- validate_effect_context(effect_context) do
            {:cont, :ok}
          else
            {:error, reason} -> {:halt, compensate(preimages, reason)}
          end

        {:error, reason} ->
          {:halt, compensate(preimages, reason)}
      end
    end)
  end

  defp capture_preimages(stages) do
    stages
    |> Enum.map(&stage_path/1)
    |> Enum.uniq()
    |> Enum.reduce_while({:ok, %{}}, fn path, {:ok, preimages} ->
      case File.read(path) do
        {:ok, bytes} -> {:cont, {:ok, Map.put(preimages, path, {:present, bytes})}}
        {:error, :enoent} -> {:cont, {:ok, Map.put(preimages, path, :absent)}}
        {:error, reason} -> {:halt, {:error, {:confirmation_preimage_failed, path, reason}}}
      end
    end)
  end

  defp apply_stage({:write, path, bytes}), do: SettingsStore.write_atomic(path, bytes)

  defp apply_stage({:delete, path}) do
    case File.rm(path) do
      :ok -> :ok
      {:error, :enoent} -> :ok
      {:error, reason} -> {:error, {:confirmation_remove_failed, path, reason}}
    end
  end

  defp stage_path({_, path}), do: path
  defp stage_path({_, path, _}), do: path

  defp compensate(preimages, original_reason) do
    failures =
      Enum.flat_map(preimages, fn
        {path, {:present, bytes}} ->
          case SettingsStore.write_atomic(path, bytes) do
            :ok -> []
            {:error, reason} -> [{path, reason}]
          end

        {path, :absent} ->
          case File.rm(path) do
            :ok -> []
            {:error, :enoent} -> []
            {:error, reason} -> [{path, reason}]
          end
      end)

    if failures == [],
      do: {:error, original_reason},
      else: {:error, {:confirmation_compensation_failed, original_reason, failures}}
  end

  defp run_stage_hook(opts, index, stage) do
    result =
      try do
        case Keyword.get(opts, :stage_hook) do
          fun when is_function(fun, 2) -> fun.(index, stage)
          fun when is_function(fun, 1) -> fun.(index)
          _ -> :ok
        end
      rescue
        exception ->
          {:error,
           {:confirmation_stage_hook_failed, exception.__struct__, Exception.message(exception)}}
      catch
        kind, reason -> {:error, {:confirmation_stage_hook_failed, kind, reason}}
      end

    case result do
      :ok -> :ok
      {:error, _reason} = error -> error
      _other -> :ok
    end
  end

  defp resolve_stages(record, resolved, now) do
    audit = audit_path(now)

    with {:ok, audit_bytes} <- audit_bytes(audit, resolved, Map.fetch!(resolved, "status"), now) do
      {:ok,
       [
         {:write, resolved_path(Map.fetch!(resolved, "id"), now), YamlCodec.encode!(resolved)},
         {:delete, pending_path(Map.fetch!(record, "id"))},
         {:write, audit, audit_bytes}
       ]}
    end
  end

  defp expired_records(now),
    do: {:ok, list(status: :pending) |> Enum.filter(&Record.expired?(&1, now))}

  defp resolve_records(records, attrs, now) do
    records
    |> Enum.reduce_while({:ok, []}, fn record, {:ok, acc} ->
      case Record.resolve(record, :expired, attrs, now) do
        {:ok, resolved} -> {:cont, {:ok, [resolved | acc]}}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
    |> then(fn
      {:ok, resolved} -> {:ok, Enum.reverse(resolved)}
      error -> error
    end)
  end

  defp expire_stages([], [], _now), do: {:ok, []}

  defp expire_stages(records, resolved, now) do
    audit = audit_path(now)

    with {:ok, original_audit} <- existing_bytes(audit) do
      audit_bytes =
        Enum.reduce(resolved, original_audit, fn record, bytes ->
          bytes <> render_audit(record, Map.fetch!(record, "status"), now)
        end)

      stages =
        Enum.zip(records, resolved)
        |> Enum.flat_map(fn {record, updated} ->
          [
            {:write, resolved_path(Map.fetch!(updated, "id"), now), YamlCodec.encode!(updated)},
            {:delete, pending_path(Map.fetch!(record, "id"))}
          ]
        end)

      {:ok, stages ++ [{:write, audit, audit_bytes}]}
    end
  end

  defp audit_bytes(path, record, event, now) do
    with {:ok, bytes} <- existing_bytes(path) do
      {:ok, bytes <> render_audit(record, event, now)}
    end
  end

  defp existing_bytes(path) do
    case File.read(path) do
      {:ok, bytes} -> {:ok, bytes}
      {:error, :enoent} -> {:ok, ""}
      {:error, reason} -> {:error, {:confirmation_preimage_failed, path, reason}}
    end
  end

  defp validate_effect_context(%{allbert_pack_activation: _}), do: {:error, :product_not_ready}

  defp validate_effect_context(%{allbert_pack_epoch: epoch} = context),
    do: EffectGuard.validate(epoch, Map.get(context, :allbert_pack_effect_guard_opts, []))

  defp validate_effect_context(_), do: {:error, :product_not_ready}

  defp pending_by_target(records),
    do:
      records
      |> Enum.group_by(&get_in(&1, ["target_action", "name"]), &Map.fetch!(&1, "id"))
      |> Map.delete(nil)

  defp read_pending(id) do
    if File.exists?(pending_path(id)) do
      read_record(pending_path(id))
    else
      {:error, {:confirmation_not_pending, id}}
    end
  end

  defp read_resolved(id) do
    with {:ok, record, _} <- read_resolved_with_path(id) do
      {:ok, record}
    end
  end

  defp read_resolved_with_path(id) do
    case resolved_root()
         |> Path.join("*")
         |> Path.join("#{id}.yml")
         |> Path.wildcard()
         |> List.first() do
      nil -> {:error, {:confirmation_not_found, id}}
      path -> with {:ok, record} <- read_record(path), do: {:ok, record, path}
    end
  end

  defp read_records(path),
    do:
      path
      |> Path.join("**/*.yml")
      |> Path.wildcard()
      |> Enum.flat_map(fn path ->
        case read_record(path) do
          {:ok, record} -> [record]
          _ -> []
        end
      end)

  defp read_record(path),
    do:
      with(
        {:ok, record} <- YamlCodec.read_file(path),
        :ok <- Record.validate(record),
        do: {:ok, record}
      )

  defp stringify_resolution_attrs(attrs),
    do:
      attrs
      |> Enum.map(fn {key, value} -> {to_string(key), stringify_resolution_value(value)} end)
      |> Map.new()

  defp stringify_resolution_value(value) when is_boolean(value), do: value
  defp stringify_resolution_value(value) when is_atom(value), do: Atom.to_string(value)
  defp stringify_resolution_value(value) when is_map(value), do: stringify_keys_deep(value)
  defp stringify_resolution_value(value) when is_list(value), do: stringify_resolution_list(value)
  defp stringify_resolution_value(value), do: value

  defp stringify_resolution_list([head | tail]) when is_list(tail),
    do: [stringify_resolution_value(head) | stringify_resolution_list(tail)]

  defp stringify_resolution_list([head | tail]),
    do: [stringify_resolution_value(head), stringify_resolution_value(tail)]

  defp stringify_resolution_list([]), do: []

  defp stringify_keys_deep(map),
    do:
      map
      |> Enum.map(fn {key, value} -> {to_string(key), stringify_resolution_value(value)} end)
      |> Map.new()

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
    #{render_metadata_audit(record)}
    - audit_version: 1
    """
  end

  defp render_metadata_audit(record) do
    lines =
      ExternalRequestMetadata.lines(record) ++
        PackageInstallMetadata.lines(record) ++
        OnlineSkillMetadata.lines(record) ++
        ResourceMetadata.lines(record) ++
        ShellCommandMetadata.lines(record) ++ SkillScriptMetadata.lines(record)

    case lines do
      [] ->
        ""

      _ ->
        lines
        |> Enum.map(fn line -> "- target_#{line_key(line)}: #{line_value(line)}" end)
        |> Enum.join("\n")
    end
  end

  defp line_key(line),
    do:
      line
      |> String.split(":", parts: 2)
      |> List.first()
      |> String.downcase()
      |> String.replace(~r/[^a-z0-9]+/, "_")
      |> String.trim("_")

  defp line_value(line) do
    case String.split(line, ":", parts: 2) do
      [_key, value] -> String.trim(value)
      [value] -> value
    end
  end

  defp paths_for_status(status) when status in [:pending, "pending"], do: [pending_root()]
  defp paths_for_status(status) when status in [:resolved, "resolved"], do: [resolved_root()]

  defp paths_for_status(status) when status in [:all, "all"],
    do: [pending_root(), resolved_root()]

  defp paths_for_status(_), do: [pending_root()]

  defp default_ttl_minutes do
    case Settings.get("confirmations.default_ttl_minutes") do
      {:ok, ttl} when is_integer(ttl) -> ttl
      _ -> 1440
    end
  end
end
