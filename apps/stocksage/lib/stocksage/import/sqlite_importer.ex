defmodule StockSage.Import.SqliteImporter do
  @moduledoc """
  Imports a representative legacy StockSage SQLite database into local
  `stocksage_*` domain tables.

  v0.20 assumes a conservative legacy shape that is easy for operators to
  inspect and adapt:

  - `analyses`: `id`, `symbol`, `analysis_date`, `status`, `recommendation`,
    `score`, `summary`.
  - `analysis_details`: `id`, `analysis_id`, `section`, `agent`, `content`,
    `payload_json`.
  - `outcomes`: `id`, `analysis_id`, `symbol`, `horizon_days`, `observed_on`,
    `start_price`, `end_price`, `return_pct`, `label`, `notes`.
  - `memory_entries`: `id`, `analysis_id`, `kind`, `content`, `tags_json`,
    `confidence`.

  Unknown tables and columns are reported as diagnostics, not crashes. The
  source database is opened read-only. No Python, market-data call, shell
  command, or external service is involved.
  """

  alias Exqlite.Sqlite3
  alias StockSage.{Analyses, Memory}

  @known_tables ~w[analyses analysis_details outcomes memory_entries]

  @expected_columns %{
    "analyses" =>
      ~w[id symbol analysis_date status recommendation score summary thread_id session_id request_id],
    "analysis_details" => ~w[id analysis_id section agent content payload_json],
    "outcomes" =>
      ~w[id analysis_id symbol horizon_days observed_on start_price end_price return_pct label notes],
    "memory_entries" => ~w[id analysis_id kind content tags_json confidence]
  }

  @empty_entity %{inserted: 0, updated: 0, skipped: 0, invalid: 0}

  @type result :: %{
          source_path: String.t(),
          user_id: String.t(),
          dry_run: boolean(),
          counts: %{required(String.t()) => map()},
          warnings: [String.t()],
          elapsed_ms: non_neg_integer()
        }

  @doc "Imports a legacy SQLite file into the local StockSage domain."
  @spec import(String.t(), keyword()) :: {:ok, result()} | {:error, term()}
  def import(path, opts \\ []) do
    started_at = System.monotonic_time(:millisecond)

    with {:ok, path} <- validate_path(path),
         {:ok, conn} <- Sqlite3.open(path, mode: :readonly) do
      try do
        {:ok, do_import(conn, path, opts, started_at)}
      after
        Sqlite3.close(conn)
      end
    end
  end

  defp do_import(conn, path, opts, started_at) do
    user_id = opts |> Keyword.get(:user_id, "local") |> to_string() |> String.trim()
    dry_run? = Keyword.get(opts, :dry_run, false)
    limit = normalize_limit(Keyword.get(opts, :limit))
    imported_at = DateTime.utc_now() |> DateTime.to_iso8601()

    tables = tables(conn)
    warnings = unknown_table_warnings(tables) ++ unknown_column_warnings(conn, tables)

    {counts, import_warnings} =
      Enum.reduce(@known_tables, {%{}, []}, fn table, {counts_acc, warnings_acc} ->
        if table in tables do
          {count, table_warnings} =
            import_table(conn, table,
              user_id: user_id,
              dry_run: dry_run?,
              limit: limit,
              imported_at: imported_at,
              source_path: path
            )

          {Map.put(counts_acc, table, count), warnings_acc ++ table_warnings}
        else
          {Map.put(counts_acc, table, @empty_entity), warnings_acc}
        end
      end)

    %{
      source_path: path,
      user_id: user_id,
      dry_run: dry_run?,
      counts: counts,
      warnings: warnings ++ import_warnings,
      elapsed_ms: System.monotonic_time(:millisecond) - started_at
    }
  end

  defp import_table(conn, table, opts) do
    rows = query_rows(conn, "SELECT * FROM #{table}#{limit_clause(opts[:limit])}")

    Enum.reduce(rows, {@empty_entity, []}, fn row, {count, warnings} ->
      case import_row(table, row, opts) do
        :inserted -> {increment(count, :inserted), warnings}
        :updated -> {increment(count, :updated), warnings}
        :skipped -> {increment(count, :skipped), warnings}
        {:invalid, reason} -> {increment(count, :invalid), [invalid_warning(table, row, reason) | warnings]}
      end
    end)
    |> then(fn {count, warnings} -> {count, Enum.reverse(warnings)} end)
  end

  defp import_row(table, row, opts) do
    if Keyword.get(opts, :dry_run, false) do
      dry_run_row(table, row, opts)
    else
      do_import_row(table, row, opts)
    end
  end

  defp do_import_row("analyses", row, opts) do
    attrs = %{
      user_id: opts[:user_id],
      thread_id: blank_to_nil(row["thread_id"]),
      session_id: blank_to_nil(row["session_id"]),
      request_id: blank_to_nil(row["request_id"]),
      symbol: row["symbol"],
      analysis_date: parse_date(row["analysis_date"]),
      status: row["status"] || "imported",
      source: "legacy_sqlite",
      recommendation: row["recommendation"],
      score: row["score"],
      summary: row["summary"],
      legacy_source: "analyses",
      legacy_id: to_legacy_id(row["id"]),
      metadata: import_metadata(opts)
    }

    upsert_with_count(
      fn -> Analyses.get_analysis_by_legacy(opts[:user_id], "analyses", attrs.legacy_id) end,
      fn -> Analyses.upsert_analysis(attrs) end
    )
  end

  defp do_import_row("analysis_details", row, opts) do
    with legacy_analysis_id when is_binary(legacy_analysis_id) <- to_legacy_id(row["analysis_id"]),
         %{} = analysis <-
           Analyses.get_analysis_by_legacy(opts[:user_id], "analyses", legacy_analysis_id) do
      attrs = %{
        user_id: opts[:user_id],
        analysis_id: analysis.id,
        section: row["section"],
        agent: row["agent"],
        content: row["content"],
        payload: parse_json_map(row["payload_json"]),
        legacy_source: "analysis_details",
        legacy_id: to_legacy_id(row["id"])
      }

      upsert_with_count(
        fn -> Analyses.get_detail_by_legacy(analysis.id, "analysis_details", attrs.legacy_id) end,
        fn -> Analyses.upsert_detail(attrs) end
      )
    else
      _ -> :skipped
    end
  end

  defp do_import_row("outcomes", row, opts) do
    analysis_id = legacy_analysis_id_to_local(row["analysis_id"], opts[:user_id])

    attrs = %{
      user_id: opts[:user_id],
      analysis_id: analysis_id,
      symbol: row["symbol"],
      horizon_days: parse_integer(row["horizon_days"]),
      observed_on: parse_date(row["observed_on"]),
      start_price: row["start_price"],
      end_price: row["end_price"],
      return_pct: row["return_pct"],
      label: row["label"] || "unknown",
      notes: row["notes"],
      legacy_source: "outcomes",
      legacy_id: to_legacy_id(row["id"]),
      metadata: import_metadata(opts)
    }

    upsert_with_count(
      fn -> Analyses.get_outcome_by_legacy(opts[:user_id], "outcomes", attrs.legacy_id) end,
      fn -> Analyses.upsert_outcome(attrs) end
    )
  end

  defp do_import_row("memory_entries", row, opts) do
    analysis_id = legacy_analysis_id_to_local(row["analysis_id"], opts[:user_id])

    attrs = %{
      user_id: opts[:user_id],
      analysis_id: analysis_id,
      kind: row["kind"] || "note",
      content: row["content"],
      tags: parse_json_map(row["tags_json"]),
      confidence: row["confidence"],
      source: "legacy_sqlite",
      legacy_source: "memory_entries",
      legacy_id: to_legacy_id(row["id"]),
      metadata: import_metadata(opts)
    }

    upsert_with_count(
      fn -> Memory.get_entry_by_legacy(opts[:user_id], "memory_entries", attrs.legacy_id) end,
      fn -> Memory.upsert_entry(attrs) end
    )
  end

  defp do_import_row(_table, _row, _opts), do: :skipped

  defp dry_run_row("analysis_details", row, opts) do
    if blank_to_nil(row["analysis_id"]) in [nil, ""] do
      :skipped
    else
      validate_row(:detail, %{
      id: "dry_run_detail",
        analysis_id: "dry-run-analysis",
        user_id: opts[:user_id],
        section: row["section"],
        payload: parse_json_map(row["payload_json"])
      })
    end
  end

  defp dry_run_row("analyses", row, opts) do
    validate_row(:analysis, %{
      id: "dry_run_analysis",
      user_id: opts[:user_id],
      symbol: row["symbol"],
      status: row["status"] || "imported",
      source: "legacy_sqlite"
    })
  end

  defp dry_run_row("outcomes", row, opts) do
    validate_row(:outcome, %{
      id: "dry_run_outcome",
      user_id: opts[:user_id],
      symbol: row["symbol"],
      label: row["label"] || "unknown"
    })
  end

  defp dry_run_row("memory_entries", row, opts) do
    validate_row(:memory, %{
      id: "dry_run_memory",
      user_id: opts[:user_id],
      content: row["content"],
      kind: row["kind"] || "note",
      source: "legacy_sqlite"
    })
  end

  defp dry_run_row(_table, _row, _opts), do: :skipped

  defp validate_row(:analysis, attrs) do
    case StockSage.Domain.Analysis.changeset(%StockSage.Domain.Analysis{}, attrs) do
      %{valid?: true} -> :inserted
      changeset -> {:invalid, errors_on(changeset)}
    end
  end

  defp validate_row(:detail, attrs) do
    case StockSage.Domain.AnalysisDetail.changeset(%StockSage.Domain.AnalysisDetail{}, attrs) do
      %{valid?: true} -> :inserted
      changeset -> {:invalid, errors_on(changeset)}
    end
  end

  defp validate_row(:outcome, attrs) do
    case StockSage.Domain.Outcome.changeset(%StockSage.Domain.Outcome{}, attrs) do
      %{valid?: true} -> :inserted
      changeset -> {:invalid, errors_on(changeset)}
    end
  end

  defp validate_row(:memory, attrs) do
    case StockSage.Domain.MemoryEntry.changeset(%StockSage.Domain.MemoryEntry{}, attrs) do
      %{valid?: true} -> :inserted
      changeset -> {:invalid, errors_on(changeset)}
    end
  end

  defp upsert_with_count(existing_fun, upsert_fun) do
    existed? = not is_nil(existing_fun.())

    case upsert_fun.() do
      {:ok, _record} -> if(existed?, do: :updated, else: :inserted)
      {:error, changeset} -> {:invalid, errors_on(changeset)}
    end
  end

  defp legacy_analysis_id_to_local(nil, _user_id), do: nil

  defp legacy_analysis_id_to_local(legacy_id, user_id) do
    legacy_id = to_legacy_id(legacy_id)

    case Analyses.get_analysis_by_legacy(user_id, "analyses", legacy_id) do
      nil -> nil
      analysis -> analysis.id
    end
  end

  defp tables(conn) do
    query_rows(conn, "SELECT name FROM sqlite_master WHERE type = 'table'")
    |> Enum.map(& &1["name"])
  end

  defp unknown_table_warnings(tables) do
    tables
    |> Enum.reject(&(&1 in @known_tables or String.starts_with?(&1, "sqlite_")))
    |> Enum.map(&"Unknown legacy table #{&1} skipped")
  end

  defp unknown_column_warnings(conn, tables) do
    tables
    |> Enum.filter(&(&1 in @known_tables))
    |> Enum.flat_map(fn table ->
      expected = Map.fetch!(@expected_columns, table)

      conn
      |> query_rows("PRAGMA table_info(#{table})")
      |> Enum.map(& &1["name"])
      |> Enum.reject(&(&1 in expected))
      |> Enum.map(&"Unknown column #{table}.#{&1} ignored")
    end)
  end

  defp query_rows(conn, sql) do
    {:ok, statement} = Sqlite3.prepare(conn, sql)
    {:ok, columns} = Sqlite3.columns(conn, statement)
    {:ok, rows} = Sqlite3.fetch_all(conn, statement)
    Enum.map(rows, &Map.new(Enum.zip(columns, &1)))
  end

  defp limit_clause(nil), do: ""
  defp limit_clause(limit), do: " LIMIT #{limit}"

  defp validate_path(path) when is_binary(path) do
    trimmed = String.trim(path)
    uri = URI.parse(trimmed)

    cond do
      trimmed == "" ->
        {:error, :missing_path}

      uri.scheme not in [nil, ""] ->
        {:error, {:remote_uri_not_allowed, trimmed}}

      not File.regular?(trimmed) ->
        {:error, {:not_found, trimmed}}

      true ->
        {:ok, Path.expand(trimmed)}
    end
  end

  defp validate_path(_path), do: {:error, :missing_path}

  defp normalize_limit(nil), do: nil

  defp normalize_limit(limit) when is_integer(limit) and limit > 0, do: limit

  defp normalize_limit(limit) when is_binary(limit) do
    case Integer.parse(limit) do
      {parsed, ""} when parsed > 0 -> parsed
      _ -> nil
    end
  end

  defp normalize_limit(_limit), do: nil

  defp increment(count, key), do: Map.update!(count, key, &(&1 + 1))

  defp import_metadata(opts) do
    %{
      "imported_at" => opts[:imported_at],
      "source_path" => opts[:source_path]
    }
  end

  defp parse_date(nil), do: nil
  defp parse_date(%Date{} = date), do: date

  defp parse_date(value) when is_binary(value) do
    case Date.from_iso8601(String.trim(value)) do
      {:ok, date} -> date
      _ -> nil
    end
  end

  defp parse_date(_value), do: nil

  defp parse_integer(nil), do: nil
  defp parse_integer(value) when is_integer(value), do: value

  defp parse_integer(value) when is_binary(value) do
    case Integer.parse(value) do
      {integer, ""} -> integer
      _ -> nil
    end
  end

  defp parse_integer(_value), do: nil

  defp parse_json_map(nil), do: %{}
  defp parse_json_map(""), do: %{}
  defp parse_json_map(value) when is_map(value), do: value

  defp parse_json_map(value) when is_binary(value) do
    case Jason.decode(value) do
      {:ok, decoded} when is_map(decoded) -> decoded
      {:ok, decoded} when is_list(decoded) -> %{"items" => decoded}
      _ -> %{}
    end
  end

  defp parse_json_map(_value), do: %{}

  defp blank_to_nil(nil), do: nil

  defp blank_to_nil(value) when is_binary(value) do
    case String.trim(value) do
      "" -> nil
      trimmed -> trimmed
    end
  end

  defp blank_to_nil(value), do: value

  defp to_legacy_id(nil), do: nil
  defp to_legacy_id(value), do: value |> to_string() |> String.trim() |> blank_to_nil()

  defp invalid_warning(table, row, reason) do
    legacy_id = Map.get(row, "id", "unknown")
    "Invalid #{table} row #{legacy_id}: #{inspect(reason)}"
  end

  defp errors_on(changeset) do
    Ecto.Changeset.traverse_errors(changeset, fn {message, opts} ->
      Regex.replace(~r"%{(\w+)}", message, fn _, key ->
        opts |> Keyword.get(String.to_existing_atom(key), key) |> to_string()
      end)
    end)
  end
end
