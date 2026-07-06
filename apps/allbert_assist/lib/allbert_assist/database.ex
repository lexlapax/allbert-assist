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
    {:ok, _migrations, _started} =
      Ecto.Migrator.with_repo(
        Repo,
        fn repo -> migrate_repo(repo, :up, all: true, log: false) end,
        pool_size: @startup_migration_pool_size
      )

    :ok
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
