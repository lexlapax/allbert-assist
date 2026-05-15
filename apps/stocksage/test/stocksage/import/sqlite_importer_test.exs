defmodule StockSage.Import.SqliteImporterTest do
  use StockSage.DataCase

  alias StockSage.{Analyses, LegacyFixture, Memory}
  alias StockSage.Import.SqliteImporter

  setup do
    path =
      Path.join(
        System.tmp_dir!(),
        "stocksage-fixture-#{System.unique_integer([:positive])}.db"
      )

    on_exit(fn -> File.rm(path) end)
    {:ok, path: path}
  end

  test "imports all supported entity types from a fixture", %{path: path} do
    LegacyFixture.create!(path)

    assert {:ok, result} = SqliteImporter.import(path, user_id: "alice")

    assert result.user_id == "alice"
    assert result.counts["analyses"].inserted == 3
    assert result.counts["analysis_details"].inserted == 6
    assert result.counts["outcomes"].inserted == 3
    assert result.counts["memory_entries"].inserted == 3
    assert Enum.any?(result.warnings, &String.contains?(&1, "ignored_column"))

    assert [%{symbol: "AAPL"} | _] = Analyses.list_analyses("alice", symbol: "aapl")
    assert length(Memory.list_entries("alice")) == 3
  end

  test "committed smoke fixture imports successfully" do
    fixture_path = Path.expand("../../fixtures/stocksage_fixture.db", __DIR__)

    assert {:ok, result} = SqliteImporter.import(fixture_path, user_id: "alice")

    assert result.counts["analyses"].inserted == 3
    assert result.counts["analysis_details"].inserted == 6
    assert result.counts["outcomes"].inserted == 3
    assert result.counts["memory_entries"].inserted == 3
  end

  test "dry-run validates and reports without writing", %{path: path} do
    LegacyFixture.create!(path)

    assert {:ok, result} = SqliteImporter.import(path, user_id: "alice", dry_run: true)

    assert result.dry_run
    assert result.counts["analyses"].inserted == 3
    assert [] = Analyses.list_analyses("alice")
    assert [] = Memory.list_entries("alice")
  end

  test "re-importing is idempotent and reports updates", %{path: path} do
    LegacyFixture.create!(path)

    assert {:ok, first} = SqliteImporter.import(path, user_id: "alice")
    assert first.counts["analyses"].inserted == 3
    assert {:ok, second} = SqliteImporter.import(path, user_id: "alice")

    assert second.counts["analyses"].inserted == 0
    assert second.counts["analyses"].updated == 3
    assert length(Analyses.list_analyses("alice")) == 3
  end

  test "unknown tables become warnings", %{path: path} do
    LegacyFixture.create!(path, unknown_table?: true)

    assert {:ok, result} = SqliteImporter.import(path, user_id: "alice")

    assert Enum.any?(result.warnings, &String.contains?(&1, "experimental_notes"))
  end

  test "rejects missing paths and remote uris before opening a database" do
    assert {:error, {:not_found, _path}} = SqliteImporter.import("/tmp/does-not-exist-stocksage.db")

    assert {:error, {:remote_uri_not_allowed, "https://example.com/stocksage.db"}} =
             SqliteImporter.import("https://example.com/stocksage.db")
  end

  test "limit caps rows per entity", %{path: path} do
    LegacyFixture.create!(path)

    assert {:ok, result} = SqliteImporter.import(path, user_id: "alice", limit: 1)

    assert result.counts["analyses"].inserted == 1
    assert result.counts["analysis_details"].inserted == 1
    assert result.counts["outcomes"].inserted == 1
    assert result.counts["memory_entries"].inserted == 1
  end
end
