defmodule AllbertAssist.Search.Projection do
  @moduledoc """
  Single-writer and serving-handle owner for disposable conversation Search.

  This is a plain GenServer because it serializes SQLite writes, reads, and
  fixed-file promotion. Jido lifecycle hooks or Skill composition would not add
  authority or useful state-machine behavior; registered actions remain the
  runtime-facing boundary.
  """

  use GenServer

  alias AllbertAssist.Conversations.Corpus
  alias AllbertAssist.Conversations.SourceEnvelope
  alias AllbertAssist.Paths
  alias AllbertAssist.Projection.PromoteProtocol
  alias AllbertAssist.Runtime.Redactor
  alias AllbertAssist.Search.Query
  alias AllbertAssist.Search.Schema
  alias AllbertAssist.Search.SQLite
  alias AllbertAssist.Settings
  alias Exqlite.Sqlite3

  @control_file "control.json"
  @page_size 200
  @candidate_batch 100

  defstruct root: nil,
            serving_conn: nil,
            control: nil,
            ready?: false,
            diagnostics: []

  @type state :: %__MODULE__{}

  def start_link(opts \\ []) do
    case Keyword.get(opts, :name, __MODULE__) do
      nil -> GenServer.start_link(__MODULE__, opts)
      name -> GenServer.start_link(__MODULE__, opts, name: name)
    end
  end

  @doc "Build, verify, and promote one complete generation from canonical Corpus pages."
  def rebuild(operator_id \\ "local", server \\ __MODULE__),
    do: GenServer.call(server, {:rebuild, operator_id}, :infinity)

  @doc "Upsert one already-authorized typed Corpus envelope into the current generation."
  def upsert(%SourceEnvelope{} = envelope, server \\ __MODULE__),
    do: GenServer.call(server, {:upsert, envelope}, :infinity)

  @doc "Remove one source from the current disposable generation."
  def delete(source_id, server \\ __MODULE__) when is_binary(source_id),
    do: GenServer.call(server, {:delete, source_id}, :infinity)

  @doc "Return one bounded, locator-only candidate batch for canonical reauthorization."
  def candidates(%Query{} = query, position \\ nil, server \\ __MODULE__),
    do: GenServer.call(server, {:candidates, query, position}, :infinity)

  @doc "Return content-free projection lifecycle status."
  def status(server \\ __MODULE__), do: GenServer.call(server, :status)

  @doc "Durably mark stale candidate evidence for the Jobs-owned repair path."
  def queue_repair(reasons, server \\ __MODULE__) when is_list(reasons),
    do: GenServer.cast(server, {:queue_repair, reasons})

  @impl true
  def init(opts) do
    root = opts |> Keyword.get(:root, Paths.search_projection_root()) |> Path.expand()
    File.mkdir_p!(root)
    cleanup_stale_builders(root)
    {conn, control, diagnostics} = load_generation(root)

    {:ok,
     %__MODULE__{
       root: root,
       serving_conn: conn,
       control: control,
       ready?: not is_nil(conn),
       diagnostics: diagnostics
     }}
  end

  @impl true
  def handle_call(:status, _from, state), do: {:reply, status_map(state), state}

  def handle_call({:rebuild, operator_id}, _from, state) do
    case rebuild_generation(state, operator_id) do
      {:ok, result, next} -> {:reply, {:ok, result}, next}
      {:error, reason, next} -> {:reply, {:error, reason}, next}
    end
  end

  def handle_call({:upsert, envelope}, _from, %{ready?: true} = state) do
    case mutate_current(state, fn conn, revision -> upsert_envelope(conn, envelope, revision) end) do
      {:ok, result, next} -> {:reply, {:ok, result}, next}
      {:error, reason, next} -> {:reply, {:error, reason}, next}
    end
  end

  def handle_call({:upsert, _envelope}, _from, state),
    do: {:reply, {:error, :search_not_ready}, state}

  def handle_call({:delete, source_id}, _from, %{ready?: true} = state) do
    case mutate_current(state, fn conn, revision -> delete_source(conn, source_id, revision) end) do
      {:ok, result, next} -> {:reply, {:ok, result}, next}
      {:error, reason, next} -> {:reply, {:error, reason}, next}
    end
  end

  def handle_call({:delete, _source_id}, _from, state),
    do: {:reply, {:error, :search_not_ready}, state}

  def handle_call({:candidates, query, position}, _from, %{ready?: true} = state) do
    {:reply, query_candidates(state, query, position), state}
  end

  def handle_call({:candidates, _query, _position}, _from, state),
    do: {:reply, {:error, :search_not_ready}, state}

  @impl true
  def handle_cast({:queue_repair, reasons}, state) do
    safe = reasons |> Enum.map(&error_code/1) |> Enum.uniq() |> Enum.sort()
    control = state.control |> Map.put("dirty", true) |> Map.put("repair_reasons", safe)
    _ = write_control(state.root, control)
    {:noreply, %{state | control: control}}
  end

  @impl true
  def terminate(_reason, state) do
    _ = Sqlite3.close(state.serving_conn)
    :ok
  end

  defp rebuild_generation(state, operator_id) when is_binary(operator_id) do
    with {:ok, snapshots} <- snapshots(operator_id),
         {:ok, primary} <- primary_snapshot(snapshots) do
      build_generation(state, snapshots, primary)
    else
      {:error, reason} -> fail_rebuild(state, reason, nil)
    end
  end

  defp rebuild_generation(state, _operator_id), do: fail_rebuild(state, :invalid_operator, nil)

  defp build_generation(state, snapshots, primary) do
    generation_id = uuid7()
    builder_path = Path.join(state.root, "build-#{generation_id}.sqlite3")

    rebuilding = %{
      "domain" => "search",
      "state" => "rebuilding",
      "current_generation_id" => state.control["current_generation_id"],
      "previous_generation_id" => state.control["previous_generation_id"],
      "builder_generation_id" => generation_id,
      "projection_revision" => state.control["projection_revision"] || 0,
      "dirty" => true,
      "last_error_code" => nil
    }

    with :ok <- write_control(state.root, rebuilding),
         {:ok, builder_conn} <- Sqlite3.open(builder_path),
         :ok <-
           Schema.create(builder_conn, %{
             generation_id: generation_id,
             eligibility_epoch: primary.eligibility_epoch,
             high_water: primary.high_water
           }) do
      populate_and_promote(state, snapshots, generation_id, builder_conn, rebuilding)
    else
      {:error, reason} -> fail_rebuild(state, reason, nil)
    end
  end

  defp populate_and_promote(state, snapshots, generation_id, builder_conn, rebuilding) do
    with {:ok, build} <- populate_snapshots(builder_conn, snapshots),
         :ok <- current_epochs(snapshots),
         {:ok, source_advanced?} <- source_advanced?(snapshots),
         build = Map.put(build, :source_advanced?, source_advanced?),
         {:ok, _capability} <- Schema.verify(builder_conn, generation_id),
         {:ok, promoted} <- promote(state, generation_id, builder_conn) do
      finish_rebuild(state, generation_id, rebuilding, build, promoted)
    else
      {:error, reason, promoted} ->
        fail_rebuild(state, reason, promoted)

      {:error, reason} ->
        _ = Sqlite3.close(builder_conn)
        fail_rebuild(state, reason, nil)
    end
  end

  defp populate_snapshots(conn, snapshots) do
    Enum.reduce_while(
      snapshots,
      {:ok, %{count: 0, revision: 0, indexed_through: nil}},
      fn snapshot, {:ok, acc} ->
        case populate_snapshot(conn, snapshot, nil, acc) do
          {:ok, next} -> {:cont, {:ok, next}}
          {:error, reason} -> {:halt, {:error, reason}}
        end
      end
    )
  end

  defp populate_snapshot(conn, snapshot, cursor, acc) do
    with {:ok, page} <- Corpus.page(snapshot, cursor, @page_size),
         {:ok, next} <- write_page(conn, page.items, page.cursor, acc) do
      if page.exhausted?,
        do: {:ok, next},
        else: populate_snapshot(conn, snapshot, page.cursor, next)
    end
  end

  defp write_page(_conn, [], _cursor, acc), do: {:ok, acc}

  defp write_page(conn, envelopes, cursor, acc) do
    revision = acc.revision + 1

    case SQLite.transaction(conn, fn ->
           with :ok <- each_ok(envelopes, &upsert_envelope(conn, &1, revision)),
                :ok <- update_generation_progress(conn, revision, cursor) do
             {:ok, :written}
           end
         end) do
      {:ok, :written} ->
        {:ok,
         %{
           count: acc.count + length(envelopes),
           revision: revision,
           indexed_through: cursor
         }}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp finish_rebuild(state, generation_id, rebuilding, build, promoted) do
    control = %{
      rebuilding
      | "state" => "ready",
        "current_generation_id" => generation_id,
        "previous_generation_id" => state.control["current_generation_id"],
        "builder_generation_id" => nil,
        "projection_revision" => build.revision,
        "dirty" => build.source_advanced?,
        "last_error_code" => nil
    }

    with :ok <- write_control(state.root, control) do
      next = %{
        state
        | serving_conn: promoted.serving_conn,
          control: control,
          ready?: true,
          diagnostics: []
      }

      {:ok,
       %{
         generation_id: generation_id,
         projection_revision: build.revision,
         document_count: build.count,
         indexed_through: encode_corpus_cursor(build.indexed_through)
       }, next}
    else
      {:error, reason} ->
        _ = Sqlite3.close(promoted.serving_conn)
        fail_rebuild(state, {:control_write_failed, reason}, %{promoted | serving_conn: nil})
    end
  end

  defp promote(state, generation_id, builder_conn) do
    PromoteProtocol.promote(
      root: state.root,
      generation_id: generation_id,
      builder_conn: builder_conn,
      serving_conn: state.serving_conn,
      verify: fn conn, _path -> verify_for_promote(conn, generation_id) end,
      quiesce: fn -> :ok end
    )
  end

  defp verify_for_promote(conn, generation_id) do
    case Schema.verify(conn, generation_id) do
      {:ok, _capability} -> :ok
      {:error, reason} -> {:error, reason}
    end
  end

  defp fail_rebuild(state, reason, promoted) do
    serving_conn = if is_map(promoted), do: promoted.serving_conn, else: state.serving_conn

    control =
      state.control
      |> Map.put("state", if(serving_conn, do: "degraded", else: "not_ready"))
      |> Map.put("builder_generation_id", nil)
      |> Map.put("dirty", true)
      |> Map.put("last_error_code", error_code(reason))

    _ = write_control(state.root, control)

    {:error, reason,
     %{
       state
       | serving_conn: serving_conn,
         control: control,
         ready?: not is_nil(serving_conn),
         diagnostics: [%{code: error_code(reason)}]
     }}
  end

  defp snapshots(operator_id) do
    policies()
    |> Enum.reduce_while({:ok, []}, fn policy, {:ok, acc} ->
      case Corpus.snapshot(operator_id, policy) do
        {:ok, snapshot} -> {:cont, {:ok, [snapshot | acc]}}
        {:error, :origin_grant_required} -> {:cont, {:ok, acc}}
        {:error, :e2ee_grant_required} -> {:cont, {:ok, acc}}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
    |> case do
      {:ok, []} -> {:error, :search_disabled}
      {:ok, snapshots} -> {:ok, Enum.reverse(snapshots)}
      error -> error
    end
  end

  defp policies do
    grants = setting("search.origin_grants", ["local_operator"])

    [
      if("local_operator" in grants,
        do: %{consumer: :search, origin_scope: :local_operator, e2ee?: false}
      ),
      if("mapped_operator_dm" in grants and "e2ee_operator" in grants,
        do: %{consumer: :search, origin_scope: :mapped_operator_dm, e2ee?: true}
      ),
      if("mapped_operator_dm" in grants and "e2ee_operator" not in grants,
        do: %{consumer: :search, origin_scope: :mapped_operator_dm, e2ee?: false}
      )
    ]
    |> Enum.reject(&is_nil/1)
  end

  defp primary_snapshot([snapshot | _rest]), do: {:ok, snapshot}
  defp primary_snapshot([]), do: {:error, :search_disabled}

  defp current_epochs(snapshots) do
    if Enum.all?(snapshots, &(Corpus.eligibility_epoch(:search) == &1.eligibility_epoch)),
      do: :ok,
      else: {:error, :eligibility_changed}
  end

  defp source_advanced?(snapshots) do
    Enum.reduce_while(snapshots, {:ok, false}, fn snapshot, {:ok, advanced?} ->
      case Corpus.snapshot(snapshot.operator_id, snapshot.policy) do
        {:ok, current} ->
          {:cont, {:ok, advanced? or current.high_water != snapshot.high_water}}

        {:error, reason} ->
          {:halt, {:error, reason}}
      end
    end)
  end

  defp mutate_current(state, mutation) do
    with {:ok, meta} <- generation_meta(state.serving_conn),
         revision = meta.projection_revision + 1,
         {:ok, result} <-
           SQLite.transaction(state.serving_conn, fn ->
             with :ok <- mutation.(state.serving_conn, revision),
                  :ok <- set_revision(state.serving_conn, revision) do
               {:ok, %{projection_revision: revision}}
             end
           end) do
      control =
        state.control |> Map.put("projection_revision", revision) |> Map.put("dirty", false)

      :ok = write_control(state.root, control)
      {:ok, result, %{state | control: control}}
    else
      {:error, reason} -> {:error, reason, mark_dirty(state, reason)}
    end
  end

  defp upsert_envelope(conn, %SourceEnvelope{} = envelope, revision) do
    with {:ok, rowid} <- existing_rowid(conn, envelope.source_id),
         {:ok, rowid} <- ensure_locator(conn, rowid, envelope, revision),
         :ok <- replace_fts(conn, rowid, Redactor.redact(envelope.content)) do
      :ok
    end
  end

  defp existing_rowid(conn, source_id) do
    case SQLite.query_one(
           conn,
           "SELECT fts_rowid FROM documents WHERE source_type = 'conversation' AND source_id = ?",
           [source_id]
         ) do
      {:ok, [rowid]} -> {:ok, rowid}
      {:error, :not_found} -> {:ok, nil}
      {:error, reason} -> {:error, reason}
    end
  end

  defp ensure_locator(conn, nil, envelope, revision) do
    values = locator_values(envelope, revision)

    with :ok <- SQLite.write(conn, locator_insert_sql(), values),
         {:ok, rowid} <- Sqlite3.last_insert_rowid(conn) do
      {:ok, rowid}
    end
  end

  defp ensure_locator(conn, rowid, envelope, _revision) do
    with :ok <- SQLite.write(conn, locator_update_sql(), locator_update_values(envelope, rowid)) do
      {:ok, rowid}
    end
  end

  defp replace_fts(conn, rowid, content) when is_binary(content) do
    with :ok <- SQLite.write(conn, "DELETE FROM search_fts WHERE rowid = ?", [rowid]),
         :ok <-
           SQLite.write(conn, "INSERT INTO search_fts(rowid, searchable_text) VALUES(?, ?)", [
             rowid,
             content
           ]) do
      :ok
    end
  end

  defp delete_source(conn, source_id, _revision) do
    case existing_rowid(conn, source_id) do
      {:ok, nil} ->
        :ok

      {:ok, rowid} ->
        with :ok <- SQLite.write(conn, "DELETE FROM search_fts WHERE rowid = ?", [rowid]),
             :ok <- SQLite.write(conn, "DELETE FROM documents WHERE fts_rowid = ?", [rowid]) do
          :ok
        end

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp query_candidates(state, query, position) do
    with {:ok, meta} <- generation_meta(state.serving_conn),
         {sql, params} <- candidate_sql(query, position),
         {:ok, rows} <- SQLite.query(state.serving_conn, sql, params) do
      {:ok,
       %{
         candidates: Enum.map(rows, &candidate_from_row/1),
         generation_id: meta.generation_id,
         projection_revision: meta.projection_revision,
         indexed_through: meta.indexed_through,
         last_indexed_at_us: meta.last_indexed_at_us
       }}
    end
  end

  defp candidate_sql(query, position) do
    {filter_sql, filter_values} = filter_sql(query.filters)
    {cursor_sql, cursor_values} = cursor_sql(query.order, position)
    order_sql = order_sql(query.order)

    sql =
      "WITH ranked AS (SELECT d.source_id, d.content_digest, d.timestamp_us, " <>
        "d.thread_id, d.origin_scope, d.e2ee, d.owner_scope, d.channel, " <>
        "d.receiver_account_ref, d.provider_thread_key, bm25(search_fts) AS score " <>
        "FROM search_fts JOIN documents d " <>
        "ON d.fts_rowid = search_fts.rowid WHERE search_fts MATCH ?#{filter_sql}) " <>
        "SELECT source_id, content_digest, timestamp_us, thread_id, origin_scope, e2ee, " <>
        "owner_scope, channel, receiver_account_ref, provider_thread_key, score FROM ranked " <>
        "WHERE 1 = 1#{cursor_sql} ORDER BY #{order_sql} LIMIT ?"

    {sql, [query.match] ++ filter_values ++ cursor_values ++ [@candidate_batch]}
  end

  defp filter_sql(filters) do
    Enum.reduce(filters, {"", []}, fn
      {:authors, values}, {sql, params} ->
        in_filter(sql, params, "d.author", values)

      {:surfaces, values}, {sql, params} ->
        in_filter(sql, params, "d.surface", values)

      {:thread_ids, values}, {sql, params} ->
        in_filter(sql, params, "d.thread_id", values)

      {:after, value}, {sql, params} ->
        {sql <> " AND d.timestamp_us > ?", params ++ [timestamp_us(value)]}

      {:before, value}, {sql, params} ->
        {sql <> " AND d.timestamp_us < ?", params ++ [timestamp_us(value)]}

      {:origin_scope, value}, {sql, params} ->
        {sql <> " AND d.origin_scope = ?", params ++ [to_string(value)]}

      {:e2ee, value}, {sql, params} ->
        {sql <> " AND d.e2ee = ?", params ++ [if(value, do: 1, else: 0)]}
    end)
  end

  defp in_filter(sql, params, column, values) do
    placeholders = Enum.map_join(values, ", ", fn _ -> "?" end)
    {sql <> " AND #{column} IN (#{placeholders})", params ++ Enum.map(values, &to_string/1)}
  end

  defp cursor_sql(_order, nil), do: {"", []}

  defp cursor_sql(:relevance, %{score: score, timestamp_us: timestamp, source_id: source_id}) do
    {" AND (score > ? OR (score = ? AND (timestamp_us < ? OR " <>
       "(timestamp_us = ? AND source_id > ?))))", [score, score, timestamp, timestamp, source_id]}
  end

  defp cursor_sql(:newest, %{timestamp_us: timestamp, source_id: source_id}) do
    {" AND (timestamp_us < ? OR (timestamp_us = ? AND source_id > ?))",
     [timestamp, timestamp, source_id]}
  end

  defp cursor_sql(:oldest, %{timestamp_us: timestamp, source_id: source_id}) do
    {" AND (timestamp_us > ? OR (timestamp_us = ? AND source_id > ?))",
     [timestamp, timestamp, source_id]}
  end

  defp order_sql(:relevance), do: "score ASC, timestamp_us DESC, source_id ASC"
  defp order_sql(:newest), do: "timestamp_us DESC, source_id ASC"
  defp order_sql(:oldest), do: "timestamp_us ASC, source_id ASC"

  defp candidate_from_row([
         source_id,
         digest,
         timestamp_us,
         thread_id,
         origin_scope,
         e2ee,
         owner_scope,
         channel,
         receiver_account_ref,
         provider_thread_key,
         score
       ]) do
    %{
      source_id: source_id,
      content_digest: digest,
      timestamp_us: timestamp_us,
      thread_id: thread_id,
      origin_scope: String.to_existing_atom(origin_scope),
      e2ee?: e2ee == 1,
      origin: %{
        owner_scope: owner_scope,
        channel: channel,
        receiver_account_ref: receiver_account_ref,
        provider_thread_key: provider_thread_key
      },
      score: score,
      position: %{score: score, timestamp_us: timestamp_us, source_id: source_id}
    }
  end

  defp generation_meta(conn) do
    case SQLite.query_one(
           conn,
           "SELECT generation_id, projection_revision, indexed_through_at_us, " <>
             "indexed_through_id, last_indexed_at_us FROM generation_meta WHERE id = 1"
         ) do
      {:ok, [generation_id, revision, at_us, source_id, last_indexed]} ->
        {:ok,
         %{
           generation_id: generation_id,
           projection_revision: revision,
           indexed_through: encode_watermark(at_us, source_id),
           last_indexed_at_us: last_indexed
         }}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp status_map(state) do
    meta = if state.ready?, do: generation_meta(state.serving_conn), else: {:error, :not_ready}

    %{
      ready?: state.ready?,
      state: state.control["state"],
      dirty?: state.control["dirty"],
      generation:
        case meta do
          {:ok, value} -> value
          {:error, _reason} -> nil
        end,
      diagnostics: state.diagnostics
    }
  end

  defp load_generation(root) do
    control = read_control(root)
    current_path = Path.join(root, "current.sqlite3")

    case open_verified(current_path) do
      {:ok, conn, generation_id, revision} ->
        control =
          control
          |> Map.put("state", "ready")
          |> Map.put("current_generation_id", generation_id)
          |> Map.put("projection_revision", revision)

        _ = write_control(root, control)
        {conn, control, []}

      {:error, :enoent} ->
        {nil, control, []}

      {:error, reason} ->
        recover_previous(root, control, reason)
    end
  end

  defp recover_previous(root, control, current_error) do
    current = Path.join(root, "current.sqlite3")
    previous = Path.join(root, "previous.sqlite3")
    _ = remove_database(current)

    case File.rename(previous, current) do
      :ok ->
        case open_verified(current) do
          {:ok, conn, generation_id, revision} ->
            recovered =
              control
              |> Map.put("state", "degraded")
              |> Map.put("current_generation_id", generation_id)
              |> Map.put("previous_generation_id", nil)
              |> Map.put("projection_revision", revision)
              |> Map.put("last_error_code", "current_generation_recovered")

            _ = write_control(root, recovered)
            {conn, recovered, [%{code: "current_generation_recovered"}]}

          {:error, reason} ->
            not_ready(control, {:current_and_previous_invalid, current_error, reason})
        end

      {:error, :enoent} ->
        not_ready(control, current_error)

      {:error, reason} ->
        not_ready(control, {:previous_recovery_failed, reason})
    end
  end

  defp open_verified(path) do
    case Sqlite3.open(path, mode: :readwrite) do
      {:ok, conn} ->
        case Schema.verify(conn) do
          {:ok, _capability} ->
            case generation_meta(conn) do
              {:ok, meta} -> {:ok, conn, meta.generation_id, meta.projection_revision}
              {:error, reason} -> close_error(conn, reason)
            end

          {:error, reason} ->
            close_error(conn, reason)
        end

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp close_error(conn, reason) do
    _ = Sqlite3.close(conn)
    {:error, reason}
  end

  defp not_ready(control, reason) do
    control =
      control
      |> Map.put("state", "not_ready")
      |> Map.put("dirty", true)
      |> Map.put("last_error_code", error_code(reason))

    {nil, control, [%{code: error_code(reason)}]}
  end

  defp mark_dirty(state, reason) do
    control =
      state.control
      |> Map.put("state", "degraded")
      |> Map.put("dirty", true)
      |> Map.put("last_error_code", error_code(reason))

    _ = write_control(state.root, control)
    %{state | control: control, diagnostics: [%{code: error_code(reason)} | state.diagnostics]}
  end

  defp default_control do
    %{
      "domain" => "search",
      "state" => "not_ready",
      "current_generation_id" => nil,
      "previous_generation_id" => nil,
      "builder_generation_id" => nil,
      "projection_revision" => 0,
      "dirty" => true,
      "last_error_code" => nil
    }
  end

  defp read_control(root) do
    case File.read(Path.join(root, @control_file)) do
      {:ok, bytes} ->
        case Jason.decode(bytes) do
          {:ok, decoded} when is_map(decoded) -> Map.merge(default_control(), decoded)
          _error -> default_control()
        end

      {:error, _reason} ->
        default_control()
    end
  end

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

  defp cleanup_stale_builders(root) do
    root
    |> Path.join("build-*.sqlite3*")
    |> Path.wildcard()
    |> Enum.each(&File.rm/1)
  end

  defp remove_database(path) do
    Enum.each([path, path <> "-wal", path <> "-shm"], fn file ->
      case File.rm(file) do
        :ok -> :ok
        {:error, :enoent} -> :ok
        {:error, _reason} -> :ok
      end
    end)
  end

  defp update_generation_progress(conn, revision, nil), do: set_revision(conn, revision)

  defp update_generation_progress(conn, revision, %Corpus.Cursor{} = cursor) do
    SQLite.write(
      conn,
      "UPDATE generation_meta SET projection_revision = ?, indexed_through_at_us = ?, " <>
        "indexed_through_id = ?, last_indexed_at_us = ? WHERE id = 1",
      [
        revision,
        timestamp_us(cursor.inserted_at),
        cursor.source_id,
        System.system_time(:microsecond)
      ]
    )
  end

  defp set_revision(conn, revision) do
    SQLite.write(
      conn,
      "UPDATE generation_meta SET projection_revision = ?, last_indexed_at_us = ? WHERE id = 1",
      [revision, System.system_time(:microsecond)]
    )
  end

  defp each_ok(values, fun) do
    Enum.reduce_while(values, :ok, fn value, :ok ->
      case fun.(value) do
        :ok -> {:cont, :ok}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
  end

  defp locator_insert_sql do
    "INSERT INTO documents(source_type, source_id, thread_id, author, trust, surface, " <>
      "thread_kind, origin_scope, e2ee, timestamp_us, source_version, content_digest, " <>
      "redactor_version, tokenizer_version, schema_version, first_projected_revision, " <>
      "owner_scope, channel, receiver_account_ref, provider_thread_key) " <>
      "VALUES('conversation', ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)"
  end

  defp locator_update_sql do
    "UPDATE documents SET thread_id = ?, author = ?, trust = ?, surface = ?, thread_kind = ?, " <>
      "origin_scope = ?, e2ee = ?, timestamp_us = ?, source_version = ?, content_digest = ?, " <>
      "redactor_version = ?, tokenizer_version = ?, schema_version = ?, owner_scope = ?, " <>
      "channel = ?, receiver_account_ref = ?, provider_thread_key = ? WHERE fts_rowid = ?"
  end

  defp locator_values(envelope, revision) do
    origin = envelope.origin || %{}

    [
      envelope.source_id,
      envelope.thread_id,
      to_string(envelope.author),
      to_string(envelope.trust),
      envelope.surface,
      envelope.thread_kind,
      to_string(envelope.origin_scope),
      if(:e2ee_operator in envelope.origin_overlays, do: 1, else: 0),
      timestamp_us(envelope.inserted_at),
      envelope.source_version,
      envelope.content_digest,
      Schema.redactor_version(),
      Schema.tokenizer_version(),
      Schema.schema_version(),
      revision,
      origin[:owner_scope],
      origin[:channel],
      origin[:receiver_account_ref],
      origin[:provider_thread_key]
    ]
  end

  defp locator_update_values(envelope, rowid) do
    [_source_id | values] = locator_values(envelope, 0)
    {_first_revision, values} = List.pop_at(values, 13)
    values ++ [rowid]
  end

  defp timestamp_us(%DateTime{} = value), do: DateTime.to_unix(value, :microsecond)

  defp encode_corpus_cursor(nil), do: nil

  defp encode_corpus_cursor(%Corpus.Cursor{} = cursor) do
    %{timestamp: cursor.inserted_at, source_id: cursor.source_id}
  end

  defp encode_watermark(nil, nil), do: nil

  defp encode_watermark(timestamp_us, source_id) do
    %{timestamp: DateTime.from_unix!(timestamp_us, :microsecond), source_id: source_id}
  end

  defp setting(key, default) do
    case Settings.get(key) do
      {:ok, value} -> value
      _other -> default
    end
  end

  defp error_code(reason) do
    case reason do
      atom when is_atom(atom) -> Atom.to_string(atom)
      {atom, _detail} when is_atom(atom) -> Atom.to_string(atom)
      {atom, _detail, _more} when is_atom(atom) -> Atom.to_string(atom)
      _other -> "search_projection_failed"
    end
  end

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
end
