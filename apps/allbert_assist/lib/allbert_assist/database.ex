defmodule AllbertAssist.Database do
  @moduledoc """
  Local SQLite database bootstrap helpers.

  This is a plain module because it owns no process state. Application startup
  uses it to decide whether the supervised Ecto migrator should run for the
  canonical Allbert Home database.
  """

  alias AllbertAssist.Paths
  alias AllbertAssist.Repo

  @app :allbert_assist
  @stocksage_migrations Path.expand(
                          "../../../../plugins/stocksage/priv/repo/migrations",
                          __DIR__
                        )

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

    [Ecto.Migrator.migrations_path(repo), @stocksage_migrations] ++ configured_paths
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
    Code.ensure_loaded?(Mix) and function_exported?(Mix, :env, 0) and Mix.env() == :test
  rescue
    _error -> false
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
