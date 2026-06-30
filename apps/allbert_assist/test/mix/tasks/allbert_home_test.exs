defmodule Mix.Tasks.Allbert.HomeTest do
  use ExUnit.Case, async: false
  @moduletag :app_env_serial

  import ExUnit.CaptureIO

  alias AllbertAssist.Paths
  alias AllbertAssist.Settings
  alias Exqlite.Sqlite3
  alias Mix.Tasks.Allbert.Home.Export, as: ExportTask
  alias Mix.Tasks.Allbert.Home.Import, as: ImportTask

  setup do
    original_paths_config = Application.get_env(:allbert_assist, Paths)
    original_settings_config = Application.get_env(:allbert_assist, Settings)

    root =
      Path.join(
        System.tmp_dir!(),
        "allbert-home-task-#{System.unique_integer([:positive])}"
      )

    home = Path.join(root, "home")
    target = Path.join(root, "target")
    evidence = Path.join(root, "evidence")

    Application.put_env(:allbert_assist, Paths, home: home)
    Application.delete_env(:allbert_assist, Settings)

    on_exit(fn ->
      restore_env(Paths, original_paths_config)
      restore_env(Settings, original_settings_config)
      Mix.Task.reenable("allbert.home.export")
      Mix.Task.reenable("allbert.home.import")
      File.rm_rf!(root)
    end)

    Paths.ensure_home!()
    File.mkdir_p!(target)
    File.mkdir_p!(evidence)
    File.mkdir_p!(Path.join(home, "memory/notes"))
    File.write!(Path.join(home, "memory/notes/task.md"), "task note\n")

    {:ok, root: root, home: home, target: target, evidence: evidence}
  end

  test "exports and dry-run validates a Home envelope", %{evidence: evidence, target: target} do
    envelope_path = Path.join(evidence, "home.envelope.json")
    diagnostic_path = Path.join(evidence, "import-diagnostic.json")

    export_output =
      capture_io(fn ->
        assert :ok = ExportTask.run(["--out", envelope_path])
      end)

    assert export_output =~ "Exported Allbert Home envelope"
    assert export_output =~ "envelope_version=1"
    assert File.exists?(envelope_path)

    before = tree_digest(target)
    Application.put_env(:allbert_assist, Paths, home: target)

    import_output =
      capture_io(fn ->
        assert :ok =
                 ImportTask.run([
                   "--dry-run",
                   "--in",
                   envelope_path,
                   "--evidence-out",
                   diagnostic_path
                 ])
      end)

    assert import_output =~ "Dry-run diagnostic:"
    assert import_output =~ "status=ok applied=false"
    assert File.exists?(diagnostic_path)
    assert before == tree_digest(target)

    diagnostic = diagnostic_path |> File.read!() |> Jason.decode!()
    assert diagnostic["dry_run"] == true
    assert diagnostic["applied"] == false
    assert diagnostic["message"] =~ "applied nothing"
  end

  test "rejects evidence paths inside the target Home", %{evidence: evidence, target: target} do
    envelope_path = Path.join(evidence, "home.envelope.json")

    capture_io(fn ->
      assert :ok = ExportTask.run(["--out", envelope_path])
    end)

    Mix.Task.reenable("allbert.home.import")
    Application.put_env(:allbert_assist, Paths, home: target)

    assert_raise Mix.Error, ~r/outside the target Allbert Home/, fn ->
      ImportTask.run([
        "--dry-run",
        "--in",
        envelope_path,
        "--evidence-out",
        Path.join(target, "diagnostic.json")
      ])
    end
  end

  test "dry-run import CLI leaves a migrated target Home byte-identical", %{
    evidence: evidence,
    target: target
  } do
    envelope_path = Path.join(evidence, "home.envelope.json")
    diagnostic_path = Path.join(evidence, "import-diagnostic.json")

    capture_io(fn ->
      assert :ok = ExportTask.run(["--out", envelope_path])
    end)

    {migrate_output, migrate_status} =
      System.cmd(
        mix_executable(),
        ["allbert.ecto.migrate", "--quiet"],
        cd: repo_root(),
        env: mix_env(target),
        stderr_to_stdout: true
      )

    assert migrate_status == 0, migrate_output
    assert sqlite_journal_mode(Path.join([target, "db", "allbert.sqlite3"])) == "wal"

    before = tree_digest(target)

    {import_output, import_status} =
      System.cmd(
        mix_executable(),
        [
          "allbert.home.import",
          "--dry-run",
          "--in",
          envelope_path,
          "--evidence-out",
          diagnostic_path
        ],
        cd: repo_root(),
        env: mix_env(target),
        stderr_to_stdout: true
      )

    assert import_status == 0, import_output
    assert import_output =~ "status=ok applied=false"
    assert File.exists?(diagnostic_path)
    assert before == tree_digest(target), import_output
  end

  defp tree_digest(root) do
    root
    |> Path.join("**/*")
    |> Path.wildcard()
    |> Enum.filter(&File.regular?/1)
    |> Enum.sort()
    |> Enum.map_join("\n", fn path ->
      rel = Path.relative_to(path, root)
      "#{rel}:#{file_hash(path)}"
    end)
    |> then(&:crypto.hash(:sha256, &1))
    |> Base.encode16(case: :lower)
  end

  defp file_hash(path) do
    path
    |> File.read!()
    |> then(&:crypto.hash(:sha256, &1))
    |> Base.encode16(case: :lower)
  end

  defp sqlite_journal_mode(database_path) do
    {:ok, conn} = Sqlite3.open(database_path, mode: :readonly)

    try do
      {:ok, statement} = Sqlite3.prepare(conn, "PRAGMA journal_mode")
      {:ok, [[mode]]} = Sqlite3.fetch_all(conn, statement)
      mode
    after
      Sqlite3.close(conn)
    end
  end

  defp restore_env(module, nil), do: Application.delete_env(:allbert_assist, module)
  defp restore_env(module, config), do: Application.put_env(:allbert_assist, module, config)

  defp mix_executable do
    System.find_executable("mix") || raise "mix executable not found"
  end

  defp mix_env(home) do
    [
      {"ALLBERT_HOME", home},
      {"ALLBERT_HOME_DIR", home},
      {"DATABASE_PATH", Path.join([home, "db", "allbert.sqlite3"])},
      {"MIX_ENV", "test"}
    ]
  end

  defp repo_root do
    Path.expand("../../../../..", __DIR__)
  end
end
