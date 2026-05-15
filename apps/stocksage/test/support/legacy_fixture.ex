defmodule StockSage.LegacyFixture do
  @moduledoc false

  alias Exqlite.Sqlite3

  def create!(path, opts \\ []) do
    File.rm(path)
    File.mkdir_p!(Path.dirname(path))

    {:ok, conn} = Sqlite3.open(path)

    try do
      execute!(conn, schema_sql(opts))
      insert_rows!(conn)
      path
    after
      Sqlite3.close(conn)
    end
  end

  defp schema_sql(opts) do
    extra_table =
      if Keyword.get(opts, :unknown_table?, false) do
        """
        CREATE TABLE experimental_notes (id TEXT PRIMARY KEY, content TEXT);
        INSERT INTO experimental_notes (id, content) VALUES ('x1', 'ignored');
        """
      else
        ""
      end

    """
    CREATE TABLE analyses (
      id TEXT PRIMARY KEY,
      symbol TEXT NOT NULL,
      analysis_date TEXT,
      status TEXT,
      recommendation TEXT,
      score TEXT,
      summary TEXT,
      ignored_column TEXT
    );

    CREATE TABLE analysis_details (
      id TEXT PRIMARY KEY,
      analysis_id TEXT,
      section TEXT,
      agent TEXT,
      content TEXT,
      payload_json TEXT
    );

    CREATE TABLE outcomes (
      id TEXT PRIMARY KEY,
      analysis_id TEXT,
      symbol TEXT,
      horizon_days INTEGER,
      observed_on TEXT,
      start_price TEXT,
      end_price TEXT,
      return_pct TEXT,
      label TEXT,
      notes TEXT
    );

    CREATE TABLE memory_entries (
      id TEXT PRIMARY KEY,
      analysis_id TEXT,
      kind TEXT,
      content TEXT,
      tags_json TEXT,
      confidence TEXT
    );

    #{extra_table}
    """
  end

  defp insert_rows!(conn) do
    execute!(
      conn,
      """
      INSERT INTO analyses (id, symbol, analysis_date, status, recommendation, score, summary, ignored_column)
      VALUES
        ('a1', 'aapl', '2026-05-01', 'completed', 'buy', '0.82', 'AAPL summary', 'ignored'),
        ('a2', 'msft', '2026-05-02', 'completed', 'hold', '0.50', 'MSFT summary', 'ignored'),
        ('a3', 'nvda', '2026-05-03', 'imported', 'watch', '0.75', 'NVDA summary', 'ignored');

      INSERT INTO analysis_details (id, analysis_id, section, agent, content, payload_json)
      VALUES
        ('d1', 'a1', 'technical', 'legacy', 'AAPL technical', '{"score": 1}'),
        ('d2', 'a1', 'fundamental', 'legacy', 'AAPL fundamental', '{"score": 2}'),
        ('d3', 'a2', 'technical', 'legacy', 'MSFT technical', '{"score": 3}'),
        ('d4', 'a2', 'fundamental', 'legacy', 'MSFT fundamental', '{"score": 4}'),
        ('d5', 'a3', 'technical', 'legacy', 'NVDA technical', '{"score": 5}'),
        ('d6', 'a3', 'fundamental', 'legacy', 'NVDA fundamental', '{"score": 6}');

      INSERT INTO outcomes (id, analysis_id, symbol, horizon_days, observed_on, start_price, end_price, return_pct, label, notes)
      VALUES
        ('o1', 'a1', 'aapl', 30, '2026-05-10', '100.0', '110.0', '0.10', 'win', 'worked'),
        ('o2', 'a2', 'msft', 30, '2026-05-11', '200.0', '198.0', '-0.01', 'loss', 'missed'),
        ('o3', 'a3', 'nvda', 30, '2026-05-12', '300.0', '300.0', '0.00', 'neutral', 'flat');

      INSERT INTO memory_entries (id, analysis_id, kind, content, tags_json, confidence)
      VALUES
        ('m1', 'a1', 'lesson', 'Watch volume confirmation.', '{"tags": ["volume"]}', '0.7'),
        ('m2', 'a2', 'note', 'Compare cloud peers.', '{"tags": ["cloud"]}', '0.6'),
        ('m3', 'a3', 'reflection', 'Semiconductor momentum is volatile.', '{"tags": ["chips"]}', '0.8');
      """
    )
  end

  defp execute!(conn, sql) do
    :ok = Sqlite3.execute(conn, sql)
  end
end
