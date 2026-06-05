defmodule Mix.Tasks.Allbert.Ecto.Migrate do
  @moduledoc """
  Run Allbert-owned SQLite migrations through the canonical migration path list.

  This task is intentionally separate from `mix ecto.migrate` so umbrella test
  aliases do not re-expand migration paths through the root alias namespace.
  """

  use Mix.Task

  alias AllbertAssist.Database
  alias AllbertAssist.Repo
  alias Exqlite.Sqlite3

  @shortdoc "Run Allbert core and checked-in plugin migrations"
  @switches [quiet: :boolean]

  @impl true
  def run(args) do
    {opts, rest, invalid} = OptionParser.parse(args, strict: @switches)

    reject_args!(rest, invalid)
    Mix.Task.run("app.config", [])

    original_config = Application.fetch_env!(:allbert_assist, Repo)
    migration_config = migration_repo_config(original_config)

    if test_database_current?(migration_config) do
      :ok
    else
      try do
        Application.put_env(:allbert_assist, Repo, migration_config)
        run_migrations!(Keyword.get(opts, :quiet, false))
      after
        Application.put_env(:allbert_assist, Repo, original_config)
      end
    end
  end

  defp run_migrations!(quiet?) do
    log = if quiet?, do: false, else: true

    {:ok, _migrations, _started} =
      Ecto.Migrator.with_repo(
        Repo,
        fn repo -> Database.migrate_repo(repo, :up, all: true, log: log) end,
        pool_size: 1
      )

    :ok
  end

  defp migration_repo_config(config) do
    if Mix.env() == :test do
      Keyword.put(config, :journal_mode, :delete)
      |> Keyword.put(:pool, DBConnection.ConnectionPool)
    else
      config
    end
  end

  defp test_database_current?(config) do
    with true <- Mix.env() == :test,
         path when is_binary(path) <- Keyword.get(config, :database),
         true <- File.regular?(path),
         expected when expected != [] <- expected_migration_versions(),
         {:ok, migrated} <- migrated_versions(path) do
      MapSet.subset?(MapSet.new(expected), MapSet.new(migrated))
    else
      _other -> false
    end
  end

  defp expected_migration_versions do
    Repo
    |> Database.migration_paths()
    |> Enum.flat_map(&Path.wildcard(Path.join(&1, "*.exs")))
    |> Enum.map(&Path.basename(&1))
    |> Enum.flat_map(fn filename ->
      case Regex.run(~r/^(\d+)_/, filename) do
        [_, version] -> [String.to_integer(version)]
        _other -> []
      end
    end)
    |> Enum.uniq()
  end

  defp migrated_versions(path) do
    with {:ok, conn} <- Sqlite3.open(path, mode: :readonly) do
      try do
        case query_migrated_versions(conn) do
          {:ok, versions} -> {:ok, versions}
          {:error, _reason} -> {:error, :schema_migrations_unavailable}
        end
      after
        Sqlite3.close(conn)
      end
    end
  end

  defp query_migrated_versions(conn) do
    with {:ok, statement} <-
           Sqlite3.prepare(conn, "SELECT version FROM schema_migrations"),
         {:ok, rows} <- Sqlite3.fetch_all(conn, statement) do
      {:ok, Enum.map(rows, fn [version] -> version end)}
    end
  end

  defp reject_args!([], []), do: :ok

  defp reject_args!(rest, invalid) do
    details =
      []
      |> maybe_add_args("unexpected args", rest)
      |> maybe_add_args("invalid options", invalid)
      |> Enum.join("; ")

    Mix.raise("Invalid allbert.ecto.migrate arguments: #{details}")
  end

  defp maybe_add_args(parts, _label, []), do: parts
  defp maybe_add_args(parts, label, values), do: parts ++ ["#{label}: #{inspect(values)}"]
end
