defmodule Mix.Tasks.Allbert.Ecto.Migrate do
  @moduledoc """
  Run Allbert-owned SQLite migrations through the canonical migration path list.

  This task is intentionally separate from `mix ecto.migrate` so umbrella test
  aliases do not re-expand migration paths through the root alias namespace.
  """

  use Mix.Task

  alias AllbertAssist.Database
  alias AllbertAssist.Repo

  @shortdoc "Run Allbert core and checked-in plugin migrations"
  @switches [quiet: :boolean]

  @impl true
  def run(args) do
    {opts, rest, invalid} = OptionParser.parse(args, strict: @switches)

    reject_args!(rest, invalid)
    Mix.Task.run("app.config", [])

    original_config = Application.fetch_env!(:allbert_assist, Repo)
    migration_config = migration_repo_config(original_config)

    try do
      Application.put_env(:allbert_assist, Repo, migration_config)
      run_migrations!(Keyword.get(opts, :quiet, false))
    after
      Application.put_env(:allbert_assist, Repo, original_config)
    end
  end

  defp run_migrations!(quiet?) do
    log = if quiet?, do: false, else: true

    {:ok, _migrations, _started} =
      Ecto.Migrator.with_repo(
        Repo,
        fn repo -> Database.migrate_repo(repo, :up, all: true, log: log) end,
        pool_size: 2
      )

    :ok
  end

  defp migration_repo_config(config) do
    if Mix.env() == :test do
      Keyword.put(config, :journal_mode, :delete)
    else
      config
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
