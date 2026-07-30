defmodule AllbertAssist.Search.SQLite do
  @moduledoc false

  alias Exqlite.Sqlite3

  def execute(conn, sql), do: Sqlite3.execute(conn, sql)

  def query(conn, sql, params \\ []) do
    with {:ok, statement} <- Sqlite3.prepare(conn, sql) do
      try do
        with :ok <- Sqlite3.bind(statement, params) do
          Sqlite3.fetch_all(conn, statement)
        end
      after
        _ = Sqlite3.release(conn, statement)
      end
    end
  end

  def query_one(conn, sql, params \\ []) do
    case query(conn, sql, params) do
      {:ok, [row]} -> {:ok, row}
      {:ok, []} -> {:error, :not_found}
      {:ok, rows} -> {:error, {:expected_one_row, length(rows)}}
      {:error, reason} -> {:error, reason}
    end
  end

  def write(conn, sql, params \\ []) do
    with {:ok, statement} <- Sqlite3.prepare(conn, sql) do
      try do
        with :ok <- Sqlite3.bind(statement, params),
             :done <- Sqlite3.step(conn, statement) do
          :ok
        end
      after
        _ = Sqlite3.release(conn, statement)
      end
    end
  end

  def transaction(conn, fun) when is_function(fun, 0) do
    with :ok <- Sqlite3.execute(conn, "BEGIN IMMEDIATE") do
      case fun.() do
        {:ok, value} -> commit(conn, value)
        :ok -> commit(conn, :ok)
        {:error, _reason} = error -> rollback(conn, error)
        other -> rollback(conn, {:error, {:invalid_transaction_result, other}})
      end
    end
  rescue
    exception ->
      _ = Sqlite3.execute(conn, "ROLLBACK")
      reraise exception, __STACKTRACE__
  end

  defp commit(conn, value) do
    case Sqlite3.execute(conn, "COMMIT") do
      :ok -> {:ok, value}
      {:error, reason} -> rollback(conn, {:error, reason})
    end
  end

  defp rollback(conn, result) do
    _ = Sqlite3.execute(conn, "ROLLBACK")
    result
  end
end
