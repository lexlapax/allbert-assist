defmodule AllbertAssist.Database do
  @moduledoc """
  Local SQLite database bootstrap helpers.

  This is a plain module because it owns no process state. Application startup
  uses it to migrate the canonical Allbert Home database before the normal Repo
  pool and plugin supervisors start.
  """

  alias AllbertAssist.Paths
  alias AllbertAssist.Repo

  @app :allbert_assist
  @startup_migration_pool_size 1

  @doc "Return the canonical SQLite path derived from Allbert Home."
  @spec home_database_path() :: String.t()
  def home_database_path do
    Path.expand(Path.join([Paths.home(), "db", "allbert.sqlite3"]))
  end

  @doc "Return true when the configured Repo database is the missing or empty Allbert Home DB."
  @spec first_run_home_database?() :: boolean()
  def first_run_home_database? do
    case repo_database_path() do
      nil -> false
      path -> same_path?(path, home_database_path()) and missing_or_empty?(path)
    end
  end

  @doc "Return whether startup migrations should be skipped."
  @spec skip_migrations?() :: boolean()
  def skip_migrations? do
    cond do
      migration_skip_forced?() ->
        true

      migration_required?() ->
        false

      true ->
        true
    end
  end

  @doc """
  Run startup migrations before the normal application supervisor starts.

  Returns `true` when this invocation ran migrations. A single SQLite
  connection avoids first-run lock noise while no runtime workers are using the
  database yet.
  """
  @spec migrate_before_supervision!() :: boolean()
  @spec migrate_before_supervision!((-> :ok)) :: boolean()
  def migrate_before_supervision!(runner \\ &run_migrations_before_supervision!/0)
      when is_function(runner, 0) do
    if skip_migrations?() do
      false
    else
      :ok = runner.()
      true
    end
  end

  @doc "Run all Allbert-owned migrations for a repo."
  @spec migrate_repo(module(), :up | :down, keyword()) :: [integer()]
  def migrate_repo(repo, direction, opts) do
    Ecto.Migrator.run(repo, migration_paths(repo), direction, opts)
  end

  @doc "Return migration directories for core Allbert and checked-in plugin domain tables."
  @spec migration_paths(module()) :: [String.t()]
  def migration_paths(repo \\ Repo) do
    repo
    |> core_and_plugin_migration_paths()
    |> Enum.map(&Path.expand/1)
    |> Enum.uniq()
    |> Enum.filter(&File.dir?/1)
  end

  @doc "Return the configured Repo database path."
  @spec repo_database_path() :: String.t() | nil
  def repo_database_path do
    @app
    |> Application.get_env(Repo, [])
    |> Keyword.get(:database)
    |> case do
      path when is_binary(path) -> Path.expand(path)
      _other -> nil
    end
  end

  @doc "Return the backup directory beside the configured Repo database."
  @spec backup_dir() :: String.t() | nil
  def backup_dir do
    case repo_database_path() do
      path when is_binary(path) -> Path.join(Path.dirname(path), "backups")
      _other -> nil
    end
  end

  @doc "List backup-before-migrate SQLite copies newest first."
  @spec list_backups() :: [String.t()]
  def list_backups do
    case backup_dir() do
      nil ->
        []

      dir ->
        dir
        |> Path.join("allbert-premigrate-*.sqlite3")
        |> Path.wildcard()
        |> Enum.filter(&File.regular?/1)
        |> Enum.sort(:desc)
    end
  end

  @doc """
  Restore the configured Repo database from a backup-before-migrate copy.

  `backup` may be an absolute backup path under the configured backups
  directory, a basename from `list_backups/0`, or `"latest"`. The destination is
  always `repo_database_path/0`; arbitrary restore targets are intentionally not
  supported.
  """
  @spec restore_from_backup(String.t()) ::
          {:ok, %{backup: String.t(), database: String.t()}} | {:error, term()}
  def restore_from_backup(backup \\ "latest") when is_binary(backup) do
    with path when is_binary(path) <- repo_database_path(),
         {:ok, backup_path} <- resolve_backup(backup) do
      File.mkdir_p!(Path.dirname(path))
      File.cp!(backup_path, path)
      {:ok, %{backup: backup_path, database: path}}
    else
      nil -> {:error, :database_path_not_configured}
      {:error, _reason} = error -> error
    end
  rescue
    error in [File.Error, File.CopyError] -> {:error, error}
  end

  defp core_and_plugin_migration_paths(repo) do
    configured_paths =
      @app
      |> Application.get_env(__MODULE__, [])
      |> Keyword.get(:migration_paths, [])

    [Ecto.Migrator.migrations_path(repo)] ++ plugin_migration_paths() ++ configured_paths
  end

  # v0.62 M1: plugin migrations resolve through the release-safe plugins root
  # at RUNTIME — the old compile-time `Path.expand(..., __DIR__)` froze the
  # build machine's checkout path into the artifact, and the missing-dir
  # filter then silently dropped stocksage's migrations on user machines. A
  # missing path now logs loudly instead of vanishing.
  defp plugin_migration_paths do
    case AllbertAssist.Plugin.Paths.plugin_path("stocksage", ["priv", "repo", "migrations"]) do
      nil ->
        require Logger
        Logger.warning("plugin migrations skipped: no plugins root resolved (stocksage)")
        []

      path ->
        if File.dir?(path) do
          [path]
        else
          require Logger
          Logger.warning("plugin migrations skipped: missing directory #{path}")
          []
        end
    end
  end

  defp run_migrations_before_supervision! do
    {:ok, migrations, _started} =
      Ecto.Migrator.with_repo(
        Repo,
        # F6: only back up + run migrations when something is actually pending. The Repo
        # is started here, so we can check first — previously the backup ran on EVERY boot
        # (a full SQLite copy per command → unbounded `db/backups/` clutter) even though
        # "Migrations already up". v0.62 M2 (Locked Decision 15): pending migrations are
        # LOGGED at boot, not silent — `brew upgrade` schema changes stay operator-visible.
        fn repo ->
          if pending_migrations?(repo) do
            maybe_backup_before_migrate()
            migrate_repo(repo, :up, all: true, log: migration_log_level())
          else
            []
          end
        end,
        pool_size: @startup_migration_pool_size
      )

    if migrations != [] do
      require Logger
      Logger.info("startup migrations applied: #{length(migrations)}")
    end

    :ok
  end

  # Any Allbert-owned migration (core + checked-in plugin paths) not yet applied.
  defp pending_migrations?(repo) do
    repo
    |> Ecto.Migrator.migrations(migration_paths(repo))
    |> Enum.any?(fn {status, _version, _name} -> status == :down end)
  rescue
    # If migration status cannot be determined, be conservative: back up and migrate.
    _error -> true
  end

  # Under Mix (dev/test) migrations run constantly — keep them quiet there;
  # in a packaged release they are an operator-visible upgrade event.
  defp migration_log_level do
    if AllbertAssist.RuntimeEnv.release?(), do: :info, else: false
  end

  @doc """
  v0.62 M2 (Locked Decision 15): back up the SQLite database before
  version-changing migrations run in a packaged release. This is
  backup-before-migrate, NOT automated rollback (deferred to v0.64) — the copy
  gives an operator a recovery point, and a failed backup refuses the boot
  rather than migrating unprotected. No-op under Mix and when there are no
  pending migrations.
  """
  @spec maybe_backup_before_migrate() :: :ok
  def maybe_backup_before_migrate do
    # F6: the caller now runs this only when migrations are actually pending (checked with
    # the Repo started), so a packaged release gets exactly one recovery copy per real
    # schema change — not one per command. A non-empty release DB gets the copy here.
    with true <- AllbertAssist.RuntimeEnv.release?(),
         path when is_binary(path) <- repo_database_path(),
         true <- File.exists?(path),
         false <- missing_or_empty?(path) do
      backup_database!(path)
    else
      _no_backup_needed -> :ok
    end
  rescue
    error in [File.Error, File.CopyError] ->
      require Logger

      Logger.error("""
      backup-before-migrate failed: #{Exception.message(error)}
      Refusing to run migrations without a recovery point. Free disk space or
      set ALLBERT_SKIP_BACKUP=1 to proceed at your own risk.
      """)

      unless truthy_env?("ALLBERT_SKIP_BACKUP"), do: reraise(error, __STACKTRACE__)
      :ok
  end

  defp backup_database!(path) do
    require Logger
    dir = Path.join(Path.dirname(path), "backups")
    File.mkdir_p!(dir)
    stamp = DateTime.utc_now() |> DateTime.to_iso8601() |> String.replace(~r/[:.]/, "-")
    target = Path.join(dir, "allbert-premigrate-#{stamp}.sqlite3")
    File.cp!(path, target)
    Logger.info("backup-before-migrate: wrote #{target}")
    :ok
  end

  defp resolve_backup("latest") do
    case list_backups() do
      [path | _rest] -> {:ok, path}
      [] -> {:error, :no_backups}
    end
  end

  defp resolve_backup(backup) do
    with dir when is_binary(dir) <- backup_dir(),
         path <- backup_path(dir, backup),
         :ok <- validate_backup_path(dir, path),
         true <- File.regular?(path) do
      {:ok, path}
    else
      nil -> {:error, :database_path_not_configured}
      false -> {:error, :backup_not_found}
      {:error, _reason} = error -> error
    end
  end

  defp backup_path(dir, backup) do
    if Path.type(backup) == :absolute do
      Path.expand(backup)
    else
      Path.expand(Path.join(dir, backup))
    end
  end

  defp validate_backup_path(dir, path) do
    dir = Path.expand(dir)
    path = Path.expand(path)
    relative = Path.relative_to(path, dir)

    cond do
      relative == "." or String.starts_with?(relative, "..") or Path.type(relative) == :absolute ->
        {:error, :backup_outside_backup_dir}

      not String.starts_with?(Path.basename(path), "allbert-premigrate-") ->
        {:error, :invalid_backup_name}

      Path.extname(path) != ".sqlite3" ->
        {:error, :invalid_backup_name}

      true ->
        :ok
    end
  end

  defp missing_or_empty?(path) do
    not File.exists?(path) or File.stat!(path).size == 0
  end

  defp same_path?(left, right), do: Path.expand(left) == Path.expand(right)

  defp migration_skip_forced? do
    truthy_env?("SKIP_MIGRATIONS") or
      truthy_env?("ALLBERT_SKIP_MIGRATIONS") or
      falsy_env?("ALLBERT_DEV_AUTO_MIGRATE") or
      test_migration_without_override?()
  end

  defp migration_required? do
    release?() or
      truthy_env?("ALLBERT_AUTO_MIGRATE") or
      truthy_env?("ALLBERT_DEV_AUTO_MIGRATE") or
      first_run_home_database?()
  end

  defp release?, do: present_env?("RELEASE_NAME")

  defp test_migration_without_override? do
    test_env?() and not truthy_env?("ALLBERT_AUTO_MIGRATE")
  end

  defp test_env? do
    AllbertAssist.RuntimeEnv.test?()
  end

  defp truthy_env?(name) do
    System.get_env(name)
    |> normalize_env_value()
    |> Kernel.in(["1", "true", "yes", "on"])
  end

  defp falsy_env?(name) do
    System.get_env(name)
    |> normalize_env_value()
    |> Kernel.in(["0", "false", "no", "off"])
  end

  defp present_env?(name) do
    case System.get_env(name) do
      nil -> false
      value -> String.trim(value) != ""
    end
  end

  defp normalize_env_value(nil), do: nil

  defp normalize_env_value(value) do
    value
    |> String.trim()
    |> String.downcase()
  end
end
