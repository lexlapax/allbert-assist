defmodule AllbertAssist.DatabaseBackupTest do
  @moduledoc """
  v0.62 M2 (Locked Decision 15) — backup-before-migrate writes a recovery-point
  copy before version-changing migrations run in a packaged release, and a
  failed backup refuses the boot (not silent, not automated rollback).
  """
  use ExUnit.Case, async: false

  alias AllbertAssist.Database

  setup do
    saved_release = System.get_env("RELEASE_NAME")
    saved_skip = System.get_env("ALLBERT_SKIP_BACKUP")
    System.delete_env("ALLBERT_SKIP_BACKUP")

    on_exit(fn ->
      restore("RELEASE_NAME", saved_release)
      restore("ALLBERT_SKIP_BACKUP", saved_skip)
    end)

    :ok
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
end
