defmodule Mix.Tasks.Stocksage.ImportSqliteTest do
  use StockSage.DataCase

  import ExUnit.CaptureIO

  alias StockSage.Analyses
  alias StockSage.LegacyFixture
  alias Mix.Tasks.Stocksage.ImportSqlite, as: ImportTask

  setup do
    path =
      Path.join(
        System.tmp_dir!(),
        "stocksage-task-fixture-#{System.unique_integer([:positive])}.db"
      )

    LegacyFixture.create!(path)

    on_exit(fn ->
      Mix.Task.reenable("stocksage.import_sqlite")
      File.rm(path)
    end)

    {:ok, path: path}
  end

  test "prints bounded import counts and defaults user to local", %{path: path} do
    output =
      capture_io(fn ->
        assert :ok = ImportTask.run([path, "--dry-run"])
      end)

    assert output =~ "StockSage import"
    assert output =~ "User: local"
    assert output =~ "analyses: inserted=3"
    refute output =~ "AAPL summary"
    assert [] = Analyses.list_analyses("local")
  end

  test "imports for explicit user", %{path: path} do
    capture_io(fn ->
      assert :ok = ImportTask.run([path, "--user", "alice"])
    end)

    assert length(Analyses.list_analyses("alice")) == 3
    assert [] = Analyses.list_analyses("bob")
  end

  test "fails fast when --user and --operator differ", %{path: path} do
    assert_raise Mix.Error, ~r/--user alice differs from --operator bob/, fn ->
      capture_io(fn ->
        ImportTask.run([path, "--user", "alice", "--operator", "bob"])
      end)
    end

    assert [] = Analyses.list_analyses("alice")
  end
end
