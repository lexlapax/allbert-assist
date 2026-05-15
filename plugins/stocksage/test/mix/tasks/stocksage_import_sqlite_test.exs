defmodule Mix.Tasks.Stocksage.ImportSqliteTest do
  use StockSage.DataCase

  import ExUnit.CaptureIO

  alias AllbertAssist.Settings
  alias StockSage.Analyses
  alias StockSage.LegacyFixture
  alias Mix.Tasks.Stocksage.ImportSqlite, as: ImportTask

  setup do
    original_settings_config = Application.get_env(:allbert_assist, Settings)

    path =
      Path.join(
        System.tmp_dir!(),
        "stocksage-task-fixture-#{System.unique_integer([:positive])}.db"
      )

    root =
      Path.join(
        System.tmp_dir!(),
        "stocksage-import-task-settings-#{System.unique_integer([:positive])}"
      )

    Application.put_env(:allbert_assist, Settings, root: root)
    LegacyFixture.create!(path)

    on_exit(fn ->
      restore_env(Settings, original_settings_config)
      Mix.Task.reenable("stocksage.import_sqlite")
      File.rm(path)
      File.rm_rf!(root)
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

  test "respects stocksage_write denial before opening the source database", %{path: path} do
    assert {:ok, _settings} =
             Settings.write_user_settings(%{
               "permissions" => %{"stocksage_write" => "denied"}
             })

    assert_raise Mix.Error, ~r/permission_denied/, fn ->
      capture_io(fn ->
        ImportTask.run([path, "--user", "alice"])
      end)
    end

    assert [] = Analyses.list_analyses("alice")
  end

  defp restore_env(module, nil), do: Application.delete_env(:allbert_assist, module)
  defp restore_env(module, config), do: Application.put_env(:allbert_assist, module, config)
end
