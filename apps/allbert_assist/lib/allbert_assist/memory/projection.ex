defmodule AllbertAssist.Memory.Projection do
  @moduledoc """
  Single-writer owner of the complete disposable Memory SQLite projection.

  This is a plain GenServer because it owns storage lifecycle and serialized
  file handles; Jido state-machine hooks or Skill composition add no value.
  Markdown claim streams remain authority, and every row can be rebuilt from
  `Memory.Claims` plus Key Custody verification.
  """

  use GenServer

  alias AllbertAssist.Jobs.Managed
  alias AllbertAssist.Memory
  alias AllbertAssist.Memory.Claims
  alias AllbertAssist.Memory.Entry
  alias AllbertAssist.Memory.Forget
  alias AllbertAssist.Memory.Lexical
  alias AllbertAssist.Paths
  alias AllbertAssist.Pack.EffectGuard
  alias AllbertAssist.Projection.PromoteProtocol
  alias AllbertAssist.Runtime.WriterLock.Holder, as: WriterLockHolder
  alias Exqlite.Sqlite3

  @schema_version 2
  @claim_normalizer_version 2
  @tombstone_normalizer_version 1
  @control_file "control.json"

  defstruct root: nil,
            control: nil,
            serving_conn: nil,
            diagnostics: [],
            tombstones: [],
            ready?: false,
            effect_guard: EffectGuard,
            effect_guard_opts: []

  @type state :: %__MODULE__{}

  @doc "Start the Memory projection owner."
  def start_link(opts \\ []) do
    case Keyword.get(opts, :name, __MODULE__) do
      nil -> GenServer.start_link(__MODULE__, opts)
      name -> GenServer.start_link(__MODULE__, opts, name: name)
    end
  end

  @doc "Build, verify, and promote one complete canonical generation."
  def rebuild(server \\ __MODULE__), do: GenServer.call(server, :rebuild, :infinity)

  @doc "Build one complete generation subject to an explicit bounded-entry cap."
  def rebuild_with_options(opts, server \\ __MODULE__) when is_list(opts),
    do: GenServer.call(server, {:rebuild, opts}, :infinity)

  @doc "Refresh one canonical claim in the active generation and advance revision once."
  def refresh_claim(claim_id, server \\ __MODULE__),
    do: GenServer.call(server, {:refresh_claim, claim_id}, :infinity)

  @doc false
  def replace_after_forget(claim_id, server \\ __MODULE__),
    do: replace_after_forgets([claim_id], server)

  @doc false
  def replace_after_forgets(claim_ids, server \\ __MODULE__) when is_list(claim_ids),
    do: GenServer.call(server, {:replace_after_forgets, claim_ids}, :infinity)

  @doc "Return content-free projection lifecycle and diagnostics."
  def status(server \\ __MODULE__), do: GenServer.call(server, :status)

  @doc "Return projected history for one claim; surfaces should use Memory retrieval APIs."
  def history(claim_id, server \\ __MODULE__),
    do: GenServer.call(server, {:history, claim_id})

  @doc "List bounded lexical candidates from the verified current generation."
  def candidates(terms, opts \\ [], server \\ __MODULE__)
      when is_list(terms) and is_list(opts),
      do: GenServer.call(server, {:candidates, terms, opts}, :infinity)

  @doc false
  def queue_repair(reasons, server \\ __MODULE__) when is_list(reasons),
    do: GenServer.cast(server, {:queue_repair, reasons})

  @impl true
  def init(opts) do
    root = opts |> Keyword.get(:root, Paths.memory_projection_root()) |> Path.expand()
    File.mkdir_p!(root)
    cleanup_stale_builders(root)
    {control, serving_conn, diagnostics, tombstones} = load_after_tombstones(root)
    _ = write_control(root, control)

    state = %__MODULE__{
      root: root,
      control: control,
      serving_conn: serving_conn,
      diagnostics: diagnostics,
      tombstones: tombstones,
      ready?: not is_nil(serving_conn),
      effect_guard: Keyword.get(opts, :effect_guard, EffectGuard),
      effect_guard_opts: Keyword.get(opts, :effect_guard_opts, [])
    }

    # Forget recovery kicks the same managed rebuild, so it already covers the
    # bootstrap. Only fall through to :bootstrap_projection when it did not fire.
    if maybe_kick_forget_recovery(tombstones) do
      {:ok, state}
    else
      maybe_bootstrap_projection(state, Keyword.get(opts, :bootstrap_jobs?, false))
    end
  end

  # v1.3 M9.b.10.a. A fresh Home has no generation, so `ready?` is false and every
  # read returns :memory_projection_not_ready forever: init only kicked the rebuild
  # when Forget tombstones were pending, a keep recorded "repair_pending" without
  # queueing a repair, and retrieval's repair path needs results it cannot get. The
  # only creator was a manual job run. Search already solves this with
  # `bootstrap_jobs?`; Memory now uses the same seam so the first generation is
  # promoted by the owner that discovers it missing.
  defp maybe_bootstrap_projection(%{ready?: false} = state, true),
    do: {:ok, state, {:continue, :bootstrap_projection}}

  defp maybe_bootstrap_projection(state, _bootstrap?), do: {:ok, state}

  @impl true
  def handle_call(:status, _from, state) do
    {:reply, status_map(state), state}
  end

  def handle_call(:rebuild, _from, state) do
    reply_effect(state, fn -> rebuild_generation(state, []) end)
  end

  def handle_call({:rebuild, opts}, _from, state) do
    reply_effect(state, fn -> rebuild_generation(state, opts) end)
  end

  def handle_call({:refresh_claim, claim_id}, _from, %{ready?: true} = state) do
    reply_effect(state, fn -> refresh_canonical_claim(state, claim_id) end)
  end

  def handle_call({:refresh_claim, _claim_id}, _from, state) do
    {:reply, {:error, :memory_projection_not_ready}, state}
  end

  def handle_call({:replace_after_forgets, claim_ids}, _from, state) do
    with_effect_reply(state, fn ->
      case rebuild_generation(state) do
        {:ok, _result, rebuilt} ->
          with :ok <- retire_noncurrent_generations(rebuilt.root),
               control = Map.put(rebuilt.control, "previous_generation_id", nil),
               :ok <- write_control(rebuilt.root, control),
               {:ok, tombstones} <- Forget.load_tombstones() do
            {:reply, :ok, %{rebuilt | control: control, tombstones: tombstones}}
          else
            {:error, reason} -> {:reply, {:error, reason}, mark_dirty(rebuilt, reason)}
          end

        {:error, reason, failed} ->
          {:reply, {:error, {:forget_projection_rebuild_failed, claim_ids, reason}}, failed}
      end
    end)
  end

  def handle_call({:history, claim_id}, _from, %{ready?: true} = state) do
    {:reply, query_history(state.serving_conn, claim_id), state}
  end

  def handle_call({:history, _claim_id}, _from, state) do
    {:reply, {:error, :memory_projection_not_ready}, state}
  end

  def handle_call({:candidates, terms, opts}, _from, %{ready?: true} = state) do
    {:reply, query_candidates(state, terms, opts), state}
  end

  def handle_call({:candidates, _terms, _opts}, _from, state) do
    {:reply, {:error, :memory_projection_not_ready}, state}
  end

  @impl true
  def handle_cast({:queue_repair, reasons}, state) do
    with {:ok, epoch} <- admit_epoch(state),
         :ok <- validate_epoch(state, epoch) do
      safe_reasons = reasons |> Enum.map(&error_code/1) |> Enum.uniq() |> Enum.sort()
      state = mark_dirty(state, {:canonical_revalidation_failed, safe_reasons})

      if repair_owner?(), do: send(self(), :kick_projection_repair)
      {:noreply, state}
    else
      {:error, _reason} -> {:noreply, state}
    end
  end

  @impl true
  def handle_continue(:bootstrap_projection, state) do
    case kick_if_ready(state) do
      {:ok, _result} ->
        {:noreply, state}

      {:error, reason} ->
        diagnostic = %{code: "projection_bootstrap_kick_failed", reason: error_code(reason)}
        {:noreply, %{state | diagnostics: [diagnostic | state.diagnostics]}}
    end
  end

  @impl true
  def handle_info(:kick_forget_recovery, state) do
    case kick_if_ready(state) do
      {:ok, _result} ->
        {:noreply, state}

      {:error, reason} ->
        diagnostic = %{code: "forget_recovery_kick_failed", reason: inspect(reason)}
        {:noreply, %{state | diagnostics: [diagnostic | state.diagnostics]}}
    end
  end

  def handle_info(:kick_projection_repair, state) do
    case kick_if_ready(state) do
      {:ok, _result} ->
        {:noreply, state}

      {:error, reason} ->
        diagnostic = %{code: "projection_repair_kick_failed", reason: error_code(reason)}
        {:noreply, %{state | diagnostics: [diagnostic | state.diagnostics]}}
    end
  end

  @impl true
  def terminate(_reason, state) do
    _ = Sqlite3.close(state.serving_conn)
    :ok
  end

  defp maybe_kick_forget_recovery(tombstones) do
    if repair_owner?() and Enum.any?(tombstones, &(&1["phase"] == "pending")) do
      send(self(), :kick_forget_recovery)
      true
    else
      false
    end
  end

  defp reply_effect(state, fun) do
    with_effect_reply(state, fn ->
      case fun.() do
        {:ok, result, next} -> {:reply, {:ok, result}, next}
        {:error, reason, next} -> {:reply, {:error, reason}, next}
      end
    end)
  end

  defp with_effect_reply(state, fun) do
    with {:ok, epoch} <- admit_epoch(state),
         :ok <- validate_epoch(state, epoch) do
      fun.()
    else
      {:error, _reason} -> {:reply, {:error, :product_not_ready}, state}
    end
  end

  defp kick_if_ready(state) do
    with {:ok, epoch} <- admit_epoch(state),
         :ok <- validate_epoch(state, epoch) do
      kick_forget_recovery()
    else
      {:error, _reason} -> {:error, :product_not_ready}
    end
  end

  defp admit_epoch(%{effect_guard: guard}), do: guard.admit_ready()

  defp validate_epoch(%{effect_guard: guard}, epoch), do: guard.validate(epoch)

  # v1.3 M9.b.11.c. This used to be `WriterLockHolder.enabled?()`, which reads
  # the `ALLBERT_HOLD_WRITER_LOCK` environment variable. That variable describes
  # how the daemon was *launched*; it is set and restored around startup by
  # `Mix.Tasks.Allbert.with_source_daemon_env/1`, so it is not a dependable
  # statement about whether this VM owns the writer at the moment a repair is
  # queued. Ownership is a fact about this VM: the holder process is either
  # running here or it is not. An attended run on 2026-08-03 saw a queued repair
  # mark the projection dirty (control `dirty_seq` 2 -> 3) while
  # `memory-index-rebuild` was never kicked (job `dirty_seq` stayed 1), leaving
  # the projection degraded with no path back.
  defp repair_owner?, do: is_pid(Process.whereis(WriterLockHolder))

  defp kick_forget_recovery do
    case Managed.kick("memory-index-rebuild", "local") do
      {:ok, result} ->
        {:ok, result}

      {:error, {:managed_job_not_found, "memory-index-rebuild"}} ->
        with {:ok, _results} <- Managed.reconcile("local") do
          Managed.kick("memory-index-rebuild", "local")
        end

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp rebuild_generation(state, opts \\ []) do
    with {:ok, max_entries} <- rebuild_limit(opts),
         {:ok, paths} <- bounded_rebuild_paths(max_entries) do
      rebuild_generation_from_paths(state, paths)
    else
      {:error, reason} -> fail_rebuild(state, reason, nil)
    end
  end

  defp rebuild_generation_from_paths(state, paths) do
    generation_id = uuid7()
    builder_path = Path.join(state.root, "build-#{generation_id}.sqlite3")

    rebuilding =
      state.control
      |> Map.put("builder_generation_id", generation_id)
      |> Map.put("state", "rebuilding")
      |> Map.put("rebuild_phase", "paging")
      |> Map.put("last_error_code", nil)

    with :ok <- write_control(state.root, rebuilding),
         {:ok, builder_conn} <- Sqlite3.open(builder_path) do
      build_opened(state, generation_id, builder_conn, rebuilding, paths)
    else
      {:error, reason} -> fail_rebuild(state, reason, nil)
    end
  end

  defp build_opened(state, generation_id, builder_conn, rebuilding, paths) do
    with :ok <- create_schema(builder_conn, generation_id),
         {:ok, build} <- populate(builder_conn, paths),
         {:ok, categories} <- projection_categories(builder_conn),
         build = Map.put(build, :categories, categories),
         :ok <-
           update_generation_watermark(builder_conn, build.full_build_source_watermark),
         verifying = Map.put(rebuilding, "rebuild_phase", "verifying"),
         :ok <- write_control(state.root, verifying) do
      promote_built(state, generation_id, builder_conn, verifying, build)
    else
      {:error, reason} ->
        _ = Sqlite3.close(builder_conn)
        fail_rebuild(state, reason, nil)
    end
  end

  defp promote_built(state, generation_id, builder_conn, verifying, build) do
    case promote(state, generation_id, builder_conn) do
      {:ok, promoted} -> finish_rebuild(state, generation_id, verifying, build, promoted)
      {:error, reason, promoted} -> fail_rebuild(state, reason, promoted)
    end
  end

  defp finish_rebuild(state, generation_id, verifying, build, promoted) do
    control = %{
      verifying
      | "current_generation_id" => generation_id,
        "previous_generation_id" => state.control["current_generation_id"],
        "builder_generation_id" => nil,
        "projection_revision" => 0,
        "state" => "ready",
        "dirty" => false,
        "rebuild_phase" => nil,
        "last_error_code" => nil,
        "full_build_source_watermark" => build.full_build_source_watermark
    }

    with :ok <- write_control(state.root, control) do
      state = %{
        state
        | control: control,
          serving_conn: promoted.serving_conn,
          diagnostics: build.diagnostics,
          ready?: true
      }

      {:ok,
       %{
         generation_id: generation_id,
         projection_revision: 0,
         claim_count: build.claim_count,
         revision_count: build.revision_count,
         excluded_count: length(build.diagnostics),
         categories: build.categories,
         derived_at: DateTime.utc_now() |> DateTime.truncate(:second) |> DateTime.to_iso8601(),
         path: Path.join(state.root, "current.sqlite3"),
         full_build_source_watermark: build.full_build_source_watermark
       }, state}
    else
      {:error, reason} ->
        _ = Sqlite3.close(promoted.serving_conn)
        fail_rebuild(state, {:control_write_failed, reason}, %{promoted | serving_conn: nil})
    end
  end

  defp promote(state, generation_id, builder_conn) do
    case PromoteProtocol.promote(
           root: state.root,
           generation_id: generation_id,
           builder_conn: builder_conn,
           serving_conn: state.serving_conn,
           verify: &verify_generation/2,
           quiesce: fn -> :ok end
         ) do
      {:ok, promoted} -> {:ok, promoted}
      {:error, reason, promoted} -> {:error, reason, promoted}
    end
  end

  defp fail_rebuild(state, reason, promoted) do
    serving_conn = if is_map(promoted), do: promoted.serving_conn, else: state.serving_conn
    error_code = error_code(reason)

    control =
      state.control
      |> Map.put("state", if(is_nil(serving_conn), do: "not_ready", else: "degraded"))
      |> Map.put("dirty", true)
      |> Map.update("dirty_seq", 1, &(&1 + 1))
      |> Map.put("rebuild_phase", nil)
      |> Map.put("last_error_code", error_code)

    _ = write_control(state.root, control)

    {:error, reason,
     %{state | control: control, serving_conn: serving_conn, ready?: not is_nil(serving_conn)}}
  end

  defp populate(conn, paths) do
    source_watermark = source_watermark(paths)

    with {:ok, tombstones} <- Forget.load_tombstones() do
      populate_paths(conn, paths, source_watermark, tombstones)
    end
  end

  defp rebuild_limit(opts) do
    case Keyword.get(opts, :max_entries, :unbounded) do
      :unbounded -> {:ok, :unbounded}
      value when is_integer(value) and value > 0 -> {:ok, value}
      value -> {:error, {:invalid_memory_projection_max_entries, value}}
    end
  end

  defp bounded_rebuild_paths(:unbounded), do: {:ok, Claims.claim_paths()}

  defp bounded_rebuild_paths(max_entries) do
    paths = Claims.claim_paths()
    discovered_entries = length(paths)

    if discovered_entries <= max_entries do
      {:ok, paths}
    else
      {:error,
       {:memory_projection_rebuild_limit_exceeded,
        %{
          max_entries: max_entries,
          discovered_entries: discovered_entries,
          processed_entries: 0,
          partial?: true,
          degraded?: true
        }}}
    end
  end

  defp projection_categories(conn) do
    with {:ok, rows} <-
           query_all(
             conn,
             "SELECT DISTINCT category FROM claim_revisions ORDER BY category ASC",
             []
           ) do
      {:ok, Enum.map(rows, &List.first/1)}
    end
  end

  defp populate_paths(conn, paths, source_watermark, tombstones) do
    candidates = Enum.map(paths, &claim_candidate/1)

    duplicate_ids =
      candidates
      |> Enum.flat_map(fn
        {:ok, stream} -> [{stream.claim_id, stream.path}]
        {:error, _diagnostic} -> []
      end)
      |> Enum.group_by(&elem(&1, 0), &elem(&1, 1))
      |> Enum.filter(fn {_claim_id, claim_paths} -> length(claim_paths) > 1 end)
      |> Map.new()

    Enum.reduce_while(candidates, {:ok, build_acc()}, fn candidate, result ->
      populate_candidate(candidate, result, conn, duplicate_ids, tombstones)
    end)
    |> case do
      {:ok, acc} ->
        {:ok,
         %{
           acc
           | diagnostics: Enum.reverse(acc.diagnostics),
             full_build_source_watermark: source_watermark
         }}

      error ->
        error
    end
  end

  defp claim_candidate(path) do
    case Claims.read_path(path) do
      {:ok, stream} -> {:ok, stream}
      {:error, reason} -> {:error, diagnostic(path, reason)}
    end
  end

  defp build_acc do
    %{
      claim_count: 0,
      revision_count: 0,
      diagnostics: [],
      full_build_source_watermark: nil
    }
  end

  defp add_diagnostic(acc, diagnostic),
    do: %{acc | diagnostics: [diagnostic | acc.diagnostics]}

  defp populate_candidate(
         {:error, diagnostic},
         {:ok, acc},
         _conn,
         _duplicate_ids,
         _tombstones
       ) do
    {:cont, {:ok, add_diagnostic(acc, diagnostic)}}
  end

  defp populate_candidate({:ok, stream}, {:ok, acc}, conn, duplicate_ids, tombstones) do
    cond do
      Map.has_key?(duplicate_ids, stream.claim_id) ->
        skip_candidate(acc, stream.path, :duplicate_claim_id)

      stream.status not in [:valid, :grandfathered] ->
        skip_candidate(acc, stream.path, stream.status)

      true ->
        insert_unsuppressed_candidate(conn, stream, acc, tombstones)
    end
  end

  defp insert_unsuppressed_candidate(conn, stream, acc, tombstones) do
    case stream_suppressed?(stream, tombstones) do
      {:ok, true} -> skip_candidate(acc, stream.path, :forgotten_value_suppressed)
      {:ok, false} -> insert_candidate(conn, stream, acc)
    end
  end

  defp stream_suppressed?(%{status: :grandfathered, legacy_content: value}, tombstones),
    do: Forget.suppressed_value?(value, tombstones)

  defp stream_suppressed?(%{status: :valid, effective_records: records}, tombstones) do
    records
    |> List.last()
    |> case do
      %{"payload" => payload} -> Forget.suppressed_value?(claim_value(payload), tombstones)
      nil -> {:ok, false}
    end
  end

  defp skip_candidate(acc, path, reason) do
    {:cont, {:ok, add_diagnostic(acc, diagnostic(path, reason))}}
  end

  defp insert_candidate(conn, stream, acc) do
    case insert_stream(conn, stream) do
      {:ok, revision_count} ->
        {:cont,
         {:ok,
          %{
            acc
            | claim_count: acc.claim_count + 1,
              revision_count: acc.revision_count + revision_count
          }}}

      {:skip, reason} ->
        {:cont, {:ok, add_diagnostic(acc, diagnostic(stream.path, reason))}}

      {:error, reason} ->
        {:halt, {:error, {:projection_insert_failed, stream.claim_id, reason}}}
    end
  end

  defp insert_stream(conn, %{status: :grandfathered} = stream) do
    case Memory.read_entry(stream.path) do
      {:ok, %Entry{review_status: :kept} = entry} ->
        row = legacy_row(stream, entry)
        with :ok <- insert_row(conn, row), do: {:ok, 1}

      {:ok, %Entry{}} ->
        {:skip, :legacy_not_kept}

      {:error, reason} ->
        {:skip, {:legacy_entry_unreadable, reason}}
    end
  end

  defp insert_stream(conn, %{status: :valid} = stream) do
    Enum.reduce_while(stream.effective_records, {:ok, 0}, fn record, {:ok, count} ->
      case insert_row(conn, record_row(stream.path, record)) do
        :ok -> {:cont, {:ok, count + 1}}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
  end

  defp insert_stream(_conn, stream), do: {:error, {:claim_not_authoritative, stream.status}}

  defp record_row(path, record) do
    payload = record["payload"]

    %{
      claim_id: record["claim_id"],
      sequence: record["sequence"],
      revision_digest: record["revision_digest"],
      state: record["state"],
      recorded_at: record["recorded_at"],
      valid_from: record["valid_from"],
      valid_to: record["valid_to"],
      actor: record["actor"],
      action: record["action"],
      value: claim_value(payload),
      source_path: path,
      operator_id: payload["operator_id"] || actor_id(record["actor"]),
      namespace:
        projected_namespace(payload["namespace"], payload["category"] || path_category(path)),
      category: payload["category"] || path_category(path),
      app_id: payload["app_id"],
      origin: payload["origin"],
      source_ref: source_ref(payload),
      summary: claim_summary(payload)
    }
  end

  defp insert_row(conn, row) do
    search_text = String.downcase(Enum.join([row.summary, row.value, row.category], " "))

    with :ok <-
           execute_bound(
             conn,
             "INSERT INTO claim_revisions " <>
               "(claim_id, sequence, revision_digest, state, recorded_at, valid_from, valid_to, " <>
               "actor, action, value, source_path, operator_id, namespace, category, app_id, origin, " <>
               "source_ref, summary, search_text) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)",
             [
               row.claim_id,
               row.sequence,
               row.revision_digest,
               row.state,
               row.recorded_at,
               row.valid_from,
               row.valid_to,
               row.actor,
               row.action,
               row.value,
               row.source_path,
               row.operator_id,
               row.namespace,
               row.category,
               row.app_id,
               row.origin,
               row.source_ref,
               row.summary,
               search_text
             ]
           ) do
      insert_terms(conn, row.claim_id, row.sequence, Lexical.terms(search_text))
    end
  end

  defp insert_terms(conn, claim_id, sequence, terms) do
    Enum.reduce_while(terms, :ok, fn term, :ok ->
      case execute_bound(
             conn,
             "INSERT INTO claim_terms (term, claim_id, sequence) VALUES (?, ?, ?)",
             [term, claim_id, sequence]
           ) do
        :ok -> {:cont, :ok}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
  end

  defp refresh_canonical_claim(state, claim_id) do
    with {:ok, stream} <- Claims.read(claim_id),
         true <- stream.status in [:valid, :grandfathered] || {:error, stream.status},
         :ok <- Sqlite3.execute(state.serving_conn, "BEGIN IMMEDIATE"),
         :ok <- delete_claim_rows(state.serving_conn, claim_id),
         {:ok, revision_count} <- insert_stream(state.serving_conn, stream),
         {:ok, revision} <- increment_revision(state.serving_conn),
         :ok <- Sqlite3.execute(state.serving_conn, "COMMIT") do
      control =
        state.control
        |> Map.put("projection_revision", revision)
        |> Map.put("dirty", false)
        |> Map.put("last_error_code", nil)

      with :ok <- write_control(state.root, control) do
        {:ok,
         %{claim_id: claim_id, revision_count: revision_count, projection_revision: revision},
         %{state | control: control}}
      else
        {:error, reason} -> {:error, {:control_write_failed, reason}, mark_dirty(state, reason)}
      end
    else
      {:error, reason} ->
        _ = Sqlite3.execute(state.serving_conn, "ROLLBACK")
        {:error, reason, mark_dirty(state, reason)}
    end
  end

  defp delete_claim_rows(conn, claim_id) do
    with :ok <- execute_bound(conn, "DELETE FROM claim_terms WHERE claim_id = ?", [claim_id]) do
      execute_bound(conn, "DELETE FROM claim_revisions WHERE claim_id = ?", [claim_id])
    end
  end

  defp increment_revision(conn) do
    with :ok <-
           Sqlite3.execute(
             conn,
             "UPDATE generation_meta SET projection_revision = projection_revision + 1 WHERE singleton = 1"
           ),
         {:ok, [revision]} <-
           query_one(conn, "SELECT projection_revision FROM generation_meta WHERE singleton = 1") do
      {:ok, revision}
    end
  end

  defp mark_dirty(state, reason) do
    control =
      state.control
      |> Map.put("state", "degraded")
      |> Map.put("dirty", true)
      |> Map.update("dirty_seq", 1, &(&1 + 1))
      |> Map.put("last_error_code", error_code(reason))

    _ = write_control(state.root, control)
    %{state | control: control}
  end

  defp create_schema(conn, generation_id) do
    Sqlite3.execute(
      conn,
      "PRAGMA journal_mode=WAL;" <>
        "PRAGMA synchronous=FULL;" <>
        "PRAGMA secure_delete=ON;" <>
        "CREATE TABLE generation_meta (" <>
        "singleton INTEGER PRIMARY KEY CHECK (singleton = 1)," <>
        "domain TEXT NOT NULL, generation_id TEXT NOT NULL, schema_version INTEGER NOT NULL," <>
        "projection_revision INTEGER NOT NULL, full_build_source_watermark TEXT," <>
        "claim_normalizer_version INTEGER NOT NULL, tombstone_normalizer_version INTEGER NOT NULL);" <>
        "CREATE TABLE claim_revisions (" <>
        "claim_id TEXT NOT NULL, sequence INTEGER NOT NULL, revision_digest TEXT NOT NULL," <>
        "state TEXT NOT NULL, recorded_at TEXT NOT NULL, valid_from TEXT, valid_to TEXT," <>
        "actor TEXT NOT NULL, action TEXT NOT NULL, value TEXT NOT NULL, source_path TEXT NOT NULL," <>
        "operator_id TEXT, namespace TEXT, category TEXT NOT NULL, app_id TEXT, origin TEXT, " <>
        "source_ref TEXT, summary TEXT NOT NULL, search_text TEXT NOT NULL," <>
        "PRIMARY KEY (claim_id, sequence));" <>
        "CREATE TABLE claim_terms (" <>
        "term TEXT NOT NULL, claim_id TEXT NOT NULL, sequence INTEGER NOT NULL," <>
        "PRIMARY KEY (term, claim_id, sequence));" <>
        "CREATE INDEX claim_terms_revision_idx ON claim_terms (claim_id, sequence);" <>
        "CREATE INDEX claim_revisions_current_idx ON claim_revisions " <>
        "(claim_id, recorded_at DESC, sequence DESC);" <>
        "CREATE INDEX claim_revisions_temporal_idx ON claim_revisions " <>
        "(state, valid_from, valid_to, recorded_at);" <>
        "CREATE INDEX claim_revisions_operator_idx ON claim_revisions " <>
        "(operator_id, state, recorded_at, claim_id);" <>
        "INSERT INTO generation_meta " <>
        "(singleton, domain, generation_id, schema_version, projection_revision, " <>
        "full_build_source_watermark, claim_normalizer_version, tombstone_normalizer_version) " <>
        "VALUES (1, 'memory', '#{generation_id}', #{@schema_version}, 0, NULL, " <>
        "#{@claim_normalizer_version}, #{@tombstone_normalizer_version})"
    )
  end

  defp update_generation_watermark(conn, watermark) do
    execute_bound(
      conn,
      "UPDATE generation_meta SET full_build_source_watermark = ? WHERE singleton = 1",
      [watermark]
    )
  end

  defp verify_generation(conn, _path) do
    with {:ok,
          [
            "memory",
            generation_id,
            @schema_version,
            revision,
            full_build_source_watermark,
            claim_version,
            tombstone_version
          ]} <-
           query_one(
             conn,
             "SELECT domain, generation_id, schema_version, projection_revision, " <>
               "full_build_source_watermark, claim_normalizer_version, " <>
               "tombstone_normalizer_version " <>
               "FROM generation_meta WHERE singleton = 1"
           ),
         true <- uuid7?(generation_id) || {:error, :invalid_generation_id},
         true <-
           (is_integer(revision) and revision >= 0) || {:error, :invalid_projection_revision},
         true <-
           valid_source_watermark?(full_build_source_watermark) ||
             {:error, :invalid_full_build_source_watermark},
         true <-
           claim_version == @claim_normalizer_version ||
             {:error, :claim_normalizer_mismatch},
         true <-
           tombstone_version == @tombstone_normalizer_version ||
             {:error, :tombstone_normalizer_mismatch},
         :ok <- verify_schema_columns(conn),
         {:ok, [invalid_count]} <-
           query_one(
             conn,
             "SELECT COUNT(*) FROM claim_revisions WHERE state NOT IN ('kept','archived','retired')"
           ),
         true <- invalid_count == 0 || {:error, :invalid_projected_state} do
      :ok
    end
  end

  defp verify_schema_columns(conn) do
    required =
      ~w[
        claim_id sequence revision_digest state recorded_at valid_from valid_to actor action value
        source_path operator_id namespace category app_id origin source_ref summary search_text
      ]

    required_terms = ~w[term claim_id sequence]

    with {:ok, rows} <- query_all(conn, "PRAGMA table_info(claim_revisions)", []),
         {:ok, term_rows} <- query_all(conn, "PRAGMA table_info(claim_terms)", []) do
      actual = rows |> Enum.map(&Enum.at(&1, 1)) |> MapSet.new()
      actual_terms = term_rows |> Enum.map(&Enum.at(&1, 1)) |> MapSet.new()

      if Enum.all?(required, &MapSet.member?(actual, &1)) and
           Enum.all?(required_terms, &MapSet.member?(actual_terms, &1)),
         do: :ok,
         else: {:error, :memory_projection_schema_incomplete}
    end
  end

  defp load_generation(root) do
    with {:ok, control} <- read_control(root),
         :ok <- validate_control(control),
         generation_id when is_binary(generation_id) <- control["current_generation_id"] do
      open_controlled_generation(root, control, generation_id)
    else
      _reason -> {default_control(), nil, []}
    end
  end

  defp load_after_tombstones(root) do
    case Forget.load_tombstones() do
      {:ok, tombstones} ->
        {control, conn, diagnostics} = load_generation(root)
        {control, conn, diagnostics, tombstones}

      {:error, reason} ->
        control =
          default_control()
          |> Map.put("state", "degraded")
          |> Map.put("last_error_code", error_code(reason))

        {control, nil, [%{path: "tombstones", code: error_code(reason)}], []}
    end
  end

  defp open_controlled_generation(root, control, generation_id) do
    path = Path.join(root, "current.sqlite3")

    case Sqlite3.open(path, mode: :readwrite) do
      {:ok, conn} -> verify_controlled_generation(conn, path, control, generation_id)
      {:error, _reason} -> {default_control(), nil, []}
    end
  end

  defp verify_controlled_generation(conn, path, control, generation_id) do
    result =
      with :ok <- verify_generation(conn, path),
           {:ok, [^generation_id]} <-
             query_one(conn, "SELECT generation_id FROM generation_meta WHERE singleton = 1") do
        :ok
      end

    case result do
      :ok -> {recover_control(control), conn, []}
      _error -> close_invalid_generation(conn)
    end
  end

  defp recover_control(%{"state" => state} = control)
       when state in ["rebuilding", "purging"] do
    control
    |> Map.put("builder_generation_id", nil)
    |> Map.put("state", "degraded")
    |> Map.put("dirty", true)
    |> Map.update("dirty_seq", 1, &(&1 + 1))
    |> Map.put("rebuild_phase", nil)
    |> Map.put("last_error_code", "interrupted_rebuild")
  end

  defp recover_control(control), do: control

  defp close_invalid_generation(conn) do
    _ = Sqlite3.close(conn)
    {default_control(), nil, []}
  end

  defp validate_control(control) do
    cond do
      control["domain"] != "memory" ->
        {:error, :invalid_control_domain}

      control["schema_version"] != @schema_version ->
        {:error, :invalid_control_schema}

      control["state"] not in ~w[not_ready ready degraded rebuilding purging] ->
        {:error, :invalid_control_state}

      not is_integer(control["projection_revision"]) or control["projection_revision"] < 0 ->
        {:error, :invalid_control_revision}

      control["state"] == "ready" and
          not valid_source_watermark?(control["full_build_source_watermark"]) ->
        {:error, :invalid_control_full_build_source_watermark}

      true ->
        :ok
    end
  end

  defp query_history(conn, claim_id) do
    with {:ok, rows} <-
           query_all(
             conn,
             "SELECT claim_id, sequence, revision_digest, state, recorded_at, valid_from, " <>
               "valid_to, actor, action, value, source_path FROM claim_revisions " <>
               "WHERE claim_id = ? ORDER BY sequence ASC",
             [claim_id]
           ) do
      {:ok,
       Enum.map(rows, fn row ->
         [
           claim_id,
           sequence,
           revision_digest,
           state,
           recorded_at,
           valid_from,
           valid_to,
           actor,
           action,
           value,
           source_path
         ] = row

         %{
           claim_id: claim_id,
           sequence: sequence,
           revision_digest: revision_digest,
           state: state,
           recorded_at: recorded_at,
           valid_from: valid_from,
           valid_to: valid_to,
           actor: actor,
           action: action,
           value: value,
           source_path: source_path
         }
       end)}
    end
  end

  defp query_candidates(state, terms, opts) do
    terms =
      terms
      |> Enum.filter(&is_binary/1)
      |> Enum.flat_map(&Lexical.terms/1)
      |> Enum.uniq()
      |> Enum.take(32)

    if terms == [] do
      {:ok, candidate_result(state, [])}
    else
      limit = opts |> Keyword.get(:limit, 1_000) |> min(10_000) |> max(1)
      user_id = normalize_optional(Keyword.get(opts, :user_id))
      {owner_sql, owner_values} = owner_clause(user_id, "candidate.operator_id")

      {category_sql, category_values} =
        category_clause(Keyword.get(opts, :categories), "candidate.category")

      posting_names =
        terms |> Enum.with_index() |> Enum.map(fn {_term, index} -> "posting_#{index}" end)

      postings_sql =
        Enum.map_join(posting_names, ", ", fn name ->
          "#{name} AS MATERIALIZED (SELECT term, claim_id, sequence FROM claim_terms " <>
            "WHERE term = ? LIMIT ?)"
        end)

      matched_sql = Enum.map_join(posting_names, " UNION ALL ", &"SELECT * FROM #{&1}")

      sql =
        "WITH " <>
          postings_sql <>
          ", matched AS (" <>
          matched_sql <>
          ") SELECT candidate.claim_id, candidate.sequence, candidate.revision_digest, " <>
          "candidate.recorded_at, candidate.actor, candidate.action, candidate.value, " <>
          "candidate.source_path, candidate.operator_id, candidate.namespace, " <>
          "candidate.category, candidate.app_id, candidate.origin, candidate.source_ref, " <>
          "candidate.summary " <>
          "FROM matched " <>
          "INNER JOIN claim_revisions AS candidate " <>
          "ON candidate.claim_id = matched.claim_id AND candidate.sequence = matched.sequence " <>
          "WHERE candidate.state = 'kept' " <>
          "AND candidate.recorded_at <= ? " <>
          "AND (candidate.valid_from IS NULL OR candidate.valid_from <= ?) " <>
          "AND (candidate.valid_to IS NULL OR candidate.valid_to > ?)" <>
          owner_sql <>
          category_sql <>
          " AND NOT EXISTS (SELECT 1 FROM claim_revisions AS newer " <>
          "WHERE newer.claim_id = candidate.claim_id " <>
          "AND newer.sequence > candidate.sequence " <>
          "AND newer.recorded_at <= ? " <>
          "AND (newer.valid_from IS NULL OR newer.valid_from <= ?) " <>
          "AND (newer.valid_to IS NULL OR newer.valid_to > ?)) " <>
          "GROUP BY candidate.claim_id, candidate.sequence"

      with {:ok, valid_at} <- temporal_value(opts, :valid_at),
           {:ok, known_at} <- temporal_value(opts, :known_at),
           values =
             Enum.flat_map(terms, &[&1, limit]) ++
               [known_at, valid_at, valid_at] ++
               owner_values ++
               category_values ++ [known_at, valid_at, valid_at],
           {:ok, rows} <- query_all(state.serving_conn, sql, values) do
        candidates = rows |> Enum.map(&candidate_from_row/1) |> rank_candidates(terms, limit)
        {:ok, candidate_result(state, candidates)}
      end
    end
  end

  defp candidate_result(state, candidates) do
    %{
      candidates: candidates,
      generation_id: state.control["current_generation_id"],
      projection_revision: state.control["projection_revision"],
      dirty?: state.control["dirty"]
    }
  end

  defp candidate_from_row(row) do
    [
      claim_id,
      sequence,
      revision_digest,
      recorded_at,
      actor,
      action,
      value,
      source_path,
      operator_id,
      namespace,
      category,
      app_id,
      origin,
      source_ref,
      summary
    ] = row

    %{
      claim_id: claim_id,
      sequence: sequence,
      revision_digest: revision_digest,
      source_path: source_path,
      state: "kept",
      entry:
        Entry.from_map(%{
          path: source_path,
          category: category,
          timestamp: recorded_at,
          actor: operator_id || actor_id(actor),
          origin: origin,
          app_id: app_id,
          namespace: namespace,
          source_ref: source_ref,
          summary: summary,
          body: value,
          review_status: :kept,
          reviewed_at: recorded_at,
          reviewed_by: operator_id || actor_id(actor),
          kind: action
        })
    }
  end

  defp rank_candidates(candidates, terms, limit) do
    candidates
    |> Enum.map(fn candidate -> {candidate_lexical_hits(candidate, terms), candidate} end)
    |> Enum.filter(fn {hits, _candidate} -> hits > 0 end)
    |> Enum.sort(&candidate_before?/2)
    |> Enum.take(limit)
    |> Enum.map(fn {hits, candidate} -> Map.put(candidate, :lexical_hits, hits) end)
  end

  defp candidate_lexical_hits(candidate, terms) do
    candidate_terms =
      [candidate.entry.summary, candidate.entry.body, Atom.to_string(candidate.entry.category)]
      |> Enum.join(" ")
      |> Lexical.terms()
      |> MapSet.new()

    Enum.count(terms, &MapSet.member?(candidate_terms, &1))
  end

  defp candidate_before?({left_hits, left}, {right_hits, right}) do
    cond do
      left_hits != right_hits ->
        left_hits > right_hits

      left.entry.timestamp != right.entry.timestamp ->
        left.entry.timestamp > right.entry.timestamp

      true ->
        left.claim_id < right.claim_id
    end
  end

  defp owner_clause(nil, _column), do: {"", []}
  defp owner_clause(user_id, column), do: {" AND #{column} = ?", [user_id]}

  defp category_clause(nil, _column), do: {"", []}

  defp category_clause(categories, column) do
    categories =
      categories
      |> List.wrap()
      |> Enum.map(&normalize_optional/1)
      |> Enum.reject(&is_nil/1)
      |> Enum.uniq()
      |> Enum.take(16)

    case categories do
      [] -> {"", []}
      categories -> {" AND #{column} IN (#{placeholders(categories)})", categories}
    end
  end

  defp placeholders(values), do: Enum.map_join(values, ", ", fn _value -> "?" end)

  defp temporal_value(opts, key) do
    opts
    |> Keyword.get(key, DateTime.utc_now())
    |> case do
      %DateTime{} = datetime -> {:ok, datetime}
      value when is_binary(value) -> parse_datetime(value)
      _other -> {:error, {:invalid_temporal_value, key}}
    end
    |> case do
      {:ok, datetime} -> {:ok, datetime |> DateTime.truncate(:second) |> DateTime.to_iso8601()}
      {:error, _reason} = error -> error
    end
  end

  defp parse_datetime(value) do
    case DateTime.from_iso8601(value) do
      {:ok, datetime, _offset} -> {:ok, datetime}
      _other -> {:error, :invalid_datetime}
    end
  end

  defp normalize_optional(nil), do: nil
  defp normalize_optional(value), do: value |> to_string() |> String.trim() |> blank_to_nil()

  defp blank_to_nil(""), do: nil
  defp blank_to_nil(value), do: value

  defp execute_bound(conn, sql, values) do
    with {:ok, statement} <- Sqlite3.prepare(conn, sql) do
      try do
        with :ok <- Sqlite3.bind(statement, values),
             :done <- Sqlite3.step(conn, statement) do
          :ok
        else
          {:error, reason} -> {:error, reason}
          other -> {:error, {:unexpected_sql_result, other}}
        end
      after
        _ = Sqlite3.release(conn, statement)
      end
    end
  end

  defp query_one(conn, sql), do: query_one(conn, sql, [])

  defp query_one(conn, sql, values) do
    with {:ok, rows} <- query_all(conn, sql, values) do
      case rows do
        [row] -> {:ok, row}
        [] -> {:error, :not_found}
        _many -> {:error, :multiple_rows}
      end
    end
  end

  defp query_all(conn, sql, values) do
    with {:ok, statement} <- Sqlite3.prepare(conn, sql) do
      try do
        with :ok <- Sqlite3.bind(statement, values) do
          collect_rows(conn, statement, [])
        end
      after
        _ = Sqlite3.release(conn, statement)
      end
    end
  end

  defp collect_rows(conn, statement, rows) do
    case Sqlite3.step(conn, statement) do
      {:row, row} -> collect_rows(conn, statement, [row | rows])
      :done -> {:ok, Enum.reverse(rows)}
      :busy -> {:error, :busy}
      {:error, reason} -> {:error, reason}
    end
  end

  defp read_control(root) do
    root |> Path.join(@control_file) |> File.read() |> decode_control()
  end

  defp decode_control({:ok, bytes}), do: Jason.decode(bytes)
  defp decode_control({:error, reason}), do: {:error, reason}

  defp write_control(root, control) do
    path = Path.join(root, @control_file)
    tmp = path <> ".tmp-" <> uuid7()
    bytes = Jason.encode_to_iodata!(control, pretty: true)

    with :ok <- File.mkdir_p(root),
         :ok <- File.write(tmp, bytes, [:binary, :exclusive]),
         {:ok, io} <- File.open(tmp, [:read, :binary]),
         :ok <- sync_and_close(io),
         :ok <- File.rename(tmp, path),
         :ok <- sync_directory(root) do
      :ok
    else
      {:error, reason} ->
        _ = File.rm(tmp)
        {:error, reason}
    end
  end

  defp sync_and_close(io) do
    try do
      :file.sync(io)
    after
      File.close(io)
    end
  end

  defp sync_directory(directory) do
    case :file.open(String.to_charlist(directory), [:read, :directory]) do
      {:ok, io} -> sync_and_close(io)
      {:error, :eisdir} -> :ok
      {:error, reason} -> {:error, reason}
    end
  end

  defp default_control do
    %{
      "domain" => "memory",
      "current_generation_id" => nil,
      "previous_generation_id" => nil,
      "builder_generation_id" => nil,
      "projection_revision" => 0,
      "schema_version" => @schema_version,
      "state" => "not_ready",
      "dirty" => true,
      "dirty_seq" => 0,
      "rebuild_phase" => nil,
      "last_error_code" => nil,
      "full_build_source_watermark" => nil,
      "claim_normalizer_version" => @claim_normalizer_version,
      "tombstone_normalizer_version" => @tombstone_normalizer_version
    }
  end

  defp status_map(state) do
    %{
      ready?: state.ready?,
      root: state.root,
      control: state.control,
      diagnostics: state.diagnostics,
      tombstone_count: length(state.tombstones)
    }
  end

  defp claim_value(payload) do
    value = payload["value"] || payload["object"] || payload["body"] || payload["claim"]
    if is_binary(value), do: value, else: Jason.encode!(value || payload)
  end

  defp legacy_row(stream, entry) do
    %{
      claim_id: stream.claim_id,
      sequence: 0,
      revision_digest: stream.legacy_digest,
      state: "kept",
      recorded_at: entry.reviewed_at || entry.timestamp || legacy_recorded_at(stream.path),
      valid_from: nil,
      valid_to: nil,
      actor: entry.actor || "legacy",
      action: "legacy_revision_zero",
      value: entry.body,
      source_path: stream.path,
      operator_id: entry.actor,
      namespace: entry.namespace,
      category: Atom.to_string(entry.category),
      app_id: entry.app_id,
      origin: entry.origin,
      source_ref: entry.source_ref,
      summary: entry.summary
    }
  end

  defp actor_id("operator:" <> actor), do: actor
  defp actor_id(actor) when is_binary(actor), do: actor
  defp actor_id(_actor), do: nil

  defp path_category(path), do: path |> Path.dirname() |> Path.basename()

  defp projected_namespace(namespace, "identity") when namespace in [nil, "", "default"],
    do: "identity"

  defp projected_namespace(namespace, _category), do: namespace

  defp source_ref(payload) do
    case payload["source_evidence"] do
      [%{} = source | _rest] -> source["source_id"] || source["message_id"]
      _other -> payload["source_ref"]
    end
  end

  defp claim_summary(payload) do
    [payload["subject"], payload["predicate"]]
    |> Enum.filter(&is_binary/1)
    |> Enum.map(&String.trim/1)
    |> Enum.reject(&(&1 == ""))
    |> Enum.join(" ")
    |> case do
      "" -> claim_value(payload) |> first_line()
      summary -> summary
    end
  end

  defp first_line(value) do
    value
    |> String.split("\n", parts: 2)
    |> List.first()
    |> String.slice(0, 200)
  end

  defp legacy_recorded_at(path) do
    case File.stat(path, time: :posix) do
      {:ok, stat} -> DateTime.from_unix!(stat.mtime) |> DateTime.to_iso8601()
      {:error, _reason} -> "1970-01-01T00:00:00Z"
    end
  end

  defp source_watermark(paths) do
    paths
    |> Enum.map(fn path ->
      relative = Path.relative_to(path, Memory.root())

      file_digest =
        case File.read(path) do
          {:ok, bytes} -> digest(bytes)
          {:error, reason} -> "unreadable:" <> error_code(reason)
        end

      {relative, file_digest}
    end)
    |> Enum.sort()
    |> Enum.map_join("\n", fn {path, file_digest} -> path <> ":" <> file_digest end)
    |> digest()
  end

  defp diagnostic(path, reason),
    do: %{path: Path.relative_to(path, Memory.root()), code: error_code(reason)}

  defp error_code(reason) do
    case reason do
      atom when is_atom(atom) -> Atom.to_string(atom)
      {atom, _detail} when is_atom(atom) -> Atom.to_string(atom)
      {atom, _detail, _more} when is_atom(atom) -> Atom.to_string(atom)
      _other -> "projection_failed"
    end
  end

  defp digest(value),
    do: "sha256:" <> (:crypto.hash(:sha256, value) |> Base.encode16(case: :lower))

  defp valid_source_watermark?("sha256:" <> hex) when byte_size(hex) == 64 do
    hex
    |> :binary.bin_to_list()
    |> Enum.all?(fn byte -> byte in ?0..?9 or byte in ?a..?f end)
  end

  defp valid_source_watermark?(_value), do: false

  defp uuid7 do
    timestamp_ms = System.system_time(:millisecond)
    <<rand_a::12, rand_b::62, _unused::6>> = :crypto.strong_rand_bytes(10)

    <<timestamp_ms::48, 7::4, rand_a::12, 2::2, rand_b::62>>
    |> Base.encode16(case: :lower)
    |> format_uuid()
  end

  defp format_uuid(
         <<a::binary-size(8), b::binary-size(4), c::binary-size(4), d::binary-size(4),
           e::binary-size(12)>>
       ),
       do: a <> "-" <> b <> "-" <> c <> "-" <> d <> "-" <> e

  defp uuid7?(value) when is_binary(value),
    do:
      Regex.match?(
        ~r/^[0-9a-f]{8}-[0-9a-f]{4}-7[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/,
        value
      )

  defp uuid7?(_value), do: false

  defp cleanup_stale_builders(root) do
    root
    |> Path.join("build-*.sqlite3*")
    |> Path.wildcard()
    |> Enum.each(&File.rm/1)
  end

  defp retire_noncurrent_generations(root) do
    paths =
      [
        Path.join(root, "previous.sqlite3"),
        Path.join(root, "previous.sqlite3-wal"),
        Path.join(root, "previous.sqlite3-shm")
      ] ++ Path.wildcard(Path.join(root, "build-*.sqlite3*"))

    result =
      Enum.reduce_while(paths, :ok, fn path, :ok ->
        case File.rm(path) do
          :ok -> {:cont, :ok}
          {:error, :enoent} -> {:cont, :ok}
          {:error, reason} -> {:halt, {:error, {:projection_retire_failed, reason}}}
        end
      end)

    with :ok <- result, do: sync_directory(root)
  end
end
