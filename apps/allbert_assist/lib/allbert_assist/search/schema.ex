defmodule AllbertAssist.Search.Schema do
  @moduledoc """
  Closed schema-1 and native SQLite capability contract for Search Central.

  This is a plain module because schema creation and verification are bounded
  operations over a connection owned by `Search.Projection`; it owns no state.
  """

  alias AllbertAssist.Search.SQLite
  @schema_version 1
  @tokenizer_version 1
  @redactor_version 1
  @minimum_sqlite_version {3, 42, 0}

  def schema_version, do: @schema_version
  def tokenizer_version, do: @tokenizer_version
  def redactor_version, do: @redactor_version

  @doc "Create the immutable schema-1 shape for one new generation."
  def create(conn, generation) when is_map(generation) do
    with :ok <- SQLite.execute(conn, "PRAGMA journal_mode=WAL"),
         :ok <- SQLite.execute(conn, "PRAGMA secure_delete=ON"),
         :ok <- SQLite.execute(conn, schema_sql()),
         :ok <- SQLite.execute(conn, index_sql()),
         :ok <- SQLite.execute(conn, trigger_sql()),
         :ok <- SQLite.write(conn, generation_insert_sql(), generation_values(generation)),
         :ok <-
           SQLite.execute(
             conn,
             "INSERT INTO search_fts(search_fts, rank) VALUES('secure-delete', 1)"
           ) do
      :ok
    end
  end

  @doc "Verify schema identity, SQLite/FTS integrity, and locator/FTS bijection."
  def verify(conn, expected_generation_id \\ nil) do
    with :ok <- SQLite.execute(conn, "PRAGMA secure_delete=ON"),
         {:ok, capability} <- capability_probe(conn),
         :ok <- verify_metadata(conn, expected_generation_id),
         {:ok, ["ok"]} <- SQLite.query_one(conn, "PRAGMA integrity_check"),
         :ok <-
           SQLite.execute(conn, "INSERT INTO search_fts(search_fts) VALUES('integrity-check')"),
         {:ok, [0]} <- SQLite.query_one(conn, missing_fts_sql()),
         {:ok, [0]} <- SQLite.query_one(conn, orphan_fts_sql()) do
      {:ok, capability}
    else
      {:ok, row} -> {:error, {:search_integrity_failed, row}}
      {:error, reason} -> {:error, reason}
    end
  end

  @doc "Functionally prove the SQLite features used by the packaged Search binary."
  def capability_probe(conn) do
    with {:ok, [version]} <- SQLite.query_one(conn, "SELECT sqlite_version()"),
         :ok <- minimum_version(version),
         {:ok, [1]} <-
           SQLite.query_one(conn, "SELECT sqlite_compileoption_used('ENABLE_FTS5')"),
         {:ok, ["wal"]} <- SQLite.query_one(conn, "PRAGMA journal_mode"),
         :ok <- functional_probe(conn) do
      {:ok,
       %{
         sqlite_version: version,
         compile_options: ["ENABLE_FTS5"],
         journal_mode: "wal",
         fts5: true,
         schema_version: @schema_version
       }}
    end
  end

  defp functional_probe(conn) do
    table = "search_capability_#{System.unique_integer([:positive])}"
    locator = table <> "_locator"
    partial = table <> "_partial"

    sql = """
    CREATE TEMP TABLE #{locator}(id INTEGER PRIMARY KEY, source_id TEXT NOT NULL UNIQUE, state TEXT NOT NULL);
    CREATE UNIQUE INDEX #{partial} ON #{locator}(source_id) WHERE state IN ('queued', 'running');
    CREATE VIRTUAL TABLE temp.#{table} USING fts5(searchable_text, tokenize='unicode61 remove_diacritics 2');
    INSERT INTO #{locator}(id, source_id, state) VALUES(1, 'probe', 'queued');
    INSERT INTO #{table}(rowid, searchable_text) VALUES(1, 'Café release notes shipped safely');
    INSERT INTO #{table}(#{table}, rank) VALUES('secure-delete', 1);
    """

    try do
      with :ok <- SQLite.execute(conn, sql),
           {:ok, [[1, score, snippet]]} <-
             SQLite.query(
               conn,
               "SELECT rowid, bm25(#{table}), snippet(#{table}, 0, '[', ']', '…', 8) " <>
                 "FROM #{table} WHERE #{table} MATCH ?",
               [~s("cafe" "release notes" ship*)]
             ),
           true <- is_number(score),
           true <- is_binary(snippet),
           :ok <- SQLite.execute(conn, "INSERT INTO #{table}(#{table}) VALUES('integrity-check')"),
           {:ok, ["ok"]} <- SQLite.query_one(conn, "PRAGMA integrity_check"),
           {:ok, [1]} <- SQLite.query_one(conn, "PRAGMA secure_delete"),
           {:ok, [0, _log, _checkpointed]} <-
             SQLite.query_one(conn, "PRAGMA wal_checkpoint(TRUNCATE)") do
        :ok
      else
        false -> {:error, :search_capability_invalid_result}
        {:ok, value} -> {:error, {:search_capability_invalid_result, value}}
        {:error, reason} -> {:error, {:search_capability_missing, reason}}
      end
    after
      _ = SQLite.execute(conn, "DROP TABLE IF EXISTS temp.#{table}")
      _ = SQLite.execute(conn, "DROP TABLE IF EXISTS temp.#{locator}")
    end
  end

  defp minimum_version(version) when is_binary(version) do
    parsed =
      version
      |> String.split(".")
      |> Enum.take(3)
      |> Enum.map(&Integer.parse/1)

    case parsed do
      [{major, ""}, {minor, ""}, {patch, ""}] ->
        if {major, minor, patch} >= @minimum_sqlite_version,
          do: :ok,
          else: {:error, {:sqlite_version_too_old, version}}

      _other ->
        {:error, {:invalid_sqlite_version, version}}
    end
  end

  defp minimum_version(version), do: {:error, {:invalid_sqlite_version, version}}

  defp verify_metadata(conn, expected_generation_id) do
    with {:ok, [generation_id, @schema_version, @tokenizer_version, @redactor_version]} <-
           SQLite.query_one(
             conn,
             "SELECT generation_id, schema_version, tokenizer_version, redactor_version " <>
               "FROM generation_meta WHERE id = 1"
           ),
         :ok <- expected_generation(generation_id, expected_generation_id) do
      :ok
    else
      {:ok, row} -> {:error, {:incompatible_search_generation, row}}
      {:error, reason} -> {:error, reason}
    end
  end

  defp expected_generation(_actual, nil), do: :ok
  defp expected_generation(actual, actual), do: :ok

  defp expected_generation(actual, expected),
    do: {:error, {:generation_id_mismatch, expected, actual}}

  defp schema_sql do
    """
    CREATE TABLE documents(
      fts_rowid INTEGER PRIMARY KEY,
      source_type TEXT NOT NULL CHECK(source_type = 'conversation'),
      source_id TEXT NOT NULL,
      thread_id TEXT NOT NULL,
      author TEXT NOT NULL CHECK(author IN ('operator', 'assistant')),
      trust TEXT NOT NULL,
      surface TEXT NOT NULL,
      thread_kind TEXT NOT NULL,
      origin_scope TEXT NOT NULL CHECK(origin_scope IN ('local_operator', 'mapped_operator_dm')),
      e2ee INTEGER NOT NULL CHECK(e2ee IN (0, 1)),
      timestamp_us INTEGER NOT NULL,
      source_version INTEGER NOT NULL CHECK(source_version >= 0),
      content_digest TEXT NOT NULL,
      redactor_version INTEGER NOT NULL CHECK(redactor_version >= 0),
      tokenizer_version INTEGER NOT NULL CHECK(tokenizer_version >= 0),
      schema_version INTEGER NOT NULL CHECK(schema_version >= 0),
      first_projected_revision INTEGER NOT NULL CHECK(first_projected_revision >= 0),
      owner_scope TEXT,
      channel TEXT,
      receiver_account_ref TEXT,
      provider_thread_key TEXT,
      UNIQUE(source_type, source_id)
    );

    CREATE VIRTUAL TABLE search_fts USING fts5(
      searchable_text,
      tokenize='unicode61 remove_diacritics 2'
    );

    CREATE TABLE generation_meta(
      id INTEGER PRIMARY KEY CHECK(id = 1),
      generation_id TEXT NOT NULL UNIQUE,
      schema_version INTEGER NOT NULL,
      tokenizer_version INTEGER NOT NULL,
      redactor_version INTEGER NOT NULL,
      source_high_water_at_us INTEGER,
      source_high_water_id TEXT,
      eligibility_epoch INTEGER NOT NULL CHECK(eligibility_epoch >= 0),
      projection_revision INTEGER NOT NULL CHECK(projection_revision >= 0),
      indexed_through_at_us INTEGER,
      indexed_through_id TEXT,
      last_indexed_at_us INTEGER,
      created_at_us INTEGER NOT NULL
    );
    """
  end

  defp index_sql do
    """
    CREATE INDEX documents_newest_idx ON documents(timestamp_us DESC, source_id ASC);
    CREATE INDEX documents_oldest_idx ON documents(timestamp_us ASC, source_id ASC);
    CREATE INDEX documents_thread_newest_idx ON documents(thread_id, timestamp_us DESC, source_id ASC);
    CREATE INDEX documents_author_newest_idx ON documents(author, timestamp_us DESC, source_id ASC);
    CREATE INDEX documents_surface_newest_idx ON documents(surface, timestamp_us DESC, source_id ASC);
    CREATE INDEX documents_origin_newest_idx ON documents(origin_scope, e2ee, timestamp_us DESC, source_id ASC);
    """
  end

  defp trigger_sql do
    """
    CREATE TRIGGER documents_first_revision_immutable
    BEFORE UPDATE OF first_projected_revision ON documents
    WHEN NEW.first_projected_revision != OLD.first_projected_revision
    BEGIN
      SELECT RAISE(ABORT, 'first_projected_revision is immutable');
    END;
    """
  end

  defp generation_insert_sql do
    """
    INSERT INTO generation_meta(
      id, generation_id, schema_version, tokenizer_version, redactor_version,
      source_high_water_at_us, source_high_water_id, eligibility_epoch,
      projection_revision, indexed_through_at_us, indexed_through_id,
      last_indexed_at_us, created_at_us
    ) VALUES(1, ?, ?, ?, ?, ?, ?, ?, 0, NULL, NULL, NULL, ?)
    """
  end

  defp generation_values(generation) do
    high_water = Map.get(generation, :high_water)

    [
      Map.fetch!(generation, :generation_id),
      @schema_version,
      @tokenizer_version,
      @redactor_version,
      high_water_at(high_water),
      high_water_id(high_water),
      Map.fetch!(generation, :eligibility_epoch),
      DateTime.utc_now() |> DateTime.to_unix(:microsecond)
    ]
  end

  defp high_water_at({%DateTime{} = timestamp, _id}),
    do: DateTime.to_unix(timestamp, :microsecond)

  defp high_water_at(nil), do: nil
  defp high_water_id({_timestamp, id}), do: id
  defp high_water_id(nil), do: nil

  defp missing_fts_sql do
    "SELECT count(*) FROM documents d LEFT JOIN search_fts f ON f.rowid = d.fts_rowid " <>
      "WHERE f.rowid IS NULL"
  end

  defp orphan_fts_sql do
    "SELECT count(*) FROM search_fts f LEFT JOIN documents d ON d.fts_rowid = f.rowid " <>
      "WHERE d.fts_rowid IS NULL"
  end
end
