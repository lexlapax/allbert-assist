defmodule AllbertAssist.DatabaseBackupTest do
  @moduledoc """
  v0.62 M2 (Locked Decision 15) — backup-before-migrate writes a recovery-point
  copy before version-changing migrations run in a packaged release, and a
  failed backup refuses the boot (not silent, not automated rollback).
  """
  use ExUnit.Case, async: false
  @moduletag :db_serial

  alias AllbertAssist.Actions.Runner
  alias AllbertAssist.Database
  alias AllbertAssist.Repo
  alias AllbertAssist.SecurityFixtures.AssertBinding

  setup do
    saved_release = System.get_env("RELEASE_NAME")
    saved_skip = System.get_env("ALLBERT_SKIP_BACKUP")
    original_repo_config = Application.get_env(:allbert_assist, Repo)
    System.delete_env("ALLBERT_SKIP_BACKUP")

    on_exit(fn ->
      restore("RELEASE_NAME", saved_release)
      restore("ALLBERT_SKIP_BACKUP", saved_skip)
      restore_app_env(Repo, original_repo_config)
    end)

    home =
      Path.join(
        System.tmp_dir!(),
        "allbert-db-backup-#{System.pid()}-#{System.unique_integer([:positive])}"
      )

    File.rm_rf!(home)
    File.mkdir_p!(home)
    on_exit(fn -> File.rm_rf!(home) end)

    {:ok, home: home}
  end

  defp restore(var, nil), do: System.delete_env(var)
  defp restore(var, value), do: System.put_env(var, value)

  test "no backup runs outside a release (Mix dev/test)" do
    System.delete_env("RELEASE_NAME")
    # In :test build_env, release?/0 is false → no-op regardless of DB state.
    assert Database.maybe_backup_before_migrate() == :ok
  end

  test "release? gates the backup path" do
    # The public entry is safe to call; without a release env it never touches
    # the filesystem. (The full release-mode backup is exercised by the M8
    # artifact smoke harness, which runs migrations against a temp Home.)
    System.delete_env("RELEASE_NAME")
    refute AllbertAssist.RuntimeEnv.release?()
    assert Database.maybe_backup_before_migrate() == :ok
  end

  test "lists and restores backup-before-migrate copies newest first", %{home: home} do
    database_path = Path.join([home, "db", "allbert.sqlite3"])
    configure_repo_database(database_path)
    backups = Path.join([home, "db", "backups"])
    File.mkdir_p!(backups)

    old = Path.join(backups, "allbert-premigrate-2026-07-01T00-00-00Z.sqlite3")
    latest = Path.join(backups, "allbert-premigrate-2026-07-02T00-00-00Z.sqlite3")
    File.write!(old, "old-db")
    File.write!(latest, "latest-db")

    assert [^latest, ^old] = Database.list_backups()
    assert {:ok, %{backup: ^latest, database: ^database_path}} = Database.restore_from_backup()
    assert File.read!(database_path) == "latest-db"

    assert {:ok, %{backup: ^old}} = Database.restore_from_backup(Path.basename(old))
    assert File.read!(database_path) == "old-db"
  end

  test "restore rejects backups outside the backup directory", %{home: home} do
    database_path = Path.join([home, "db", "allbert.sqlite3"])
    configure_repo_database(database_path)
    outside = Path.join(home, "outside.sqlite3")
    File.write!(outside, "outside")

    assert {:error, :backup_outside_backup_dir} = Database.restore_from_backup(outside)
    refute File.exists?(database_path)
  end

  test "restore action is confirmation gated and supports dry-run", %{home: home} do
    database_path = Path.join([home, "db", "allbert.sqlite3"])
    configure_repo_database(database_path)
    backups = Path.join([home, "db", "backups"])
    File.mkdir_p!(backups)
    backup = Path.join(backups, "allbert-premigrate-2026-07-02T00-00-00Z.sqlite3")
    File.write!(backup, "restored-db")

    assert [^backup] = Database.list_backups()

    outside = Path.join(home, "outside.sqlite3")
    File.write!(outside, "outside")
    assert {:error, :backup_outside_backup_dir} = Database.restore_from_backup(outside)

    assert {:ok, dry} =
             Runner.run("restore_database_backup", %{backup: "latest", dry_run: true}, %{
               user_id: "local"
             })

    assert dry.status == :completed
    assert dry.actions |> hd() |> Map.fetch!(:executed) == false

    assert {:ok, _} =
             AllbertAssist.Settings.put("permissions.command_execute", "needs_confirmation", %{
               audit?: false
             })

    assert {:ok, gated} =
             Runner.run("restore_database_backup", %{backup: "latest"}, %{
               actor: "local",
               channel: :cli
             })

    assert gated.status == :needs_confirmation
    assert gated.confirmation_id

    assert {:ok, restored} =
             Runner.run("restore_database_backup", %{backup: "latest"}, %{
               user_id: "local",
               confirmation: %{approved?: true}
             })

    assert restored.status == :completed
    assert File.read!(database_path) == "restored-db"

    AssertBinding.check!("trusted-install-rollback-restore-001", [
      :backups_list_newest_first,
      :restore_rejects_outside_dir,
      :restore_action_confirmation_gated
    ])
  end

  defp configure_repo_database(database_path) do
    current = Application.get_env(:allbert_assist, Repo, [])
    Application.put_env(:allbert_assist, Repo, Keyword.put(current, :database, database_path))
  end

  defp restore_app_env(module, nil), do: Application.delete_env(:allbert_assist, module)
  defp restore_app_env(module, value), do: Application.put_env(:allbert_assist, module, value)
end
