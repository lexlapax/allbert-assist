defmodule AllbertAssist.DatabaseTest do
  use ExUnit.Case, async: false

  alias AllbertAssist.Database
  alias AllbertAssist.Paths
  alias AllbertAssist.Repo

  @env_vars [
    "ALLBERT_HOME",
    "ALLBERT_HOME_DIR",
    "ALLBERT_DEV_AUTO_MIGRATE",
    "ALLBERT_AUTO_MIGRATE",
    "ALLBERT_SKIP_MIGRATIONS",
    "SKIP_MIGRATIONS",
    "RELEASE_NAME"
  ]

  setup do
    original_env = Map.new(@env_vars, &{&1, System.get_env(&1)})
    original_paths_config = Application.get_env(:allbert_assist, Paths)
    original_repo_config = Application.get_env(:allbert_assist, Repo)
    original_database_config = Application.get_env(:allbert_assist, Database)

    Enum.each(@env_vars, &System.delete_env/1)
    Application.delete_env(:allbert_assist, Paths)
    Application.delete_env(:allbert_assist, Database)

    home = temp_path("home")
    System.put_env("ALLBERT_HOME", home)

    on_exit(fn ->
      File.rm_rf!(home)
      restore_env(original_env)
      restore_app_env(Paths, original_paths_config)
      restore_app_env(Repo, original_repo_config)
      restore_app_env(Database, original_database_config)
    end)

    {:ok, home: home}
  end

  test "first-run home database is detected from the canonical Allbert Home path", %{home: home} do
    database_path = Path.join([home, "db", "allbert.sqlite3"])
    configure_repo_database(database_path)

    assert Database.home_database_path() == database_path
    assert Database.first_run_home_database?()
    assert Database.skip_migrations?()

    System.put_env("ALLBERT_AUTO_MIGRATE", "1")
    refute Database.skip_migrations?()
    System.delete_env("ALLBERT_AUTO_MIGRATE")

    File.mkdir_p!(Path.dirname(database_path))
    File.write!(database_path, "not empty")

    refute Database.first_run_home_database?()
    assert Database.skip_migrations?()
  end

  test "explicit non-home database path is not treated as first-run Allbert Home", %{home: home} do
    database_path = Path.join([home, "outside", "custom.sqlite3"])
    configure_repo_database(database_path)

    refute Database.first_run_home_database?()
    assert Database.skip_migrations?()
  end

  test "auto-migrate and skip environment flags override first-run detection", %{home: home} do
    database_path = Path.join([home, "db", "allbert.sqlite3"])
    configure_repo_database(database_path)

    System.put_env("ALLBERT_SKIP_MIGRATIONS", "true")
    assert Database.skip_migrations?()

    System.delete_env("ALLBERT_SKIP_MIGRATIONS")
    System.put_env("ALLBERT_DEV_AUTO_MIGRATE", "0")
    assert Database.skip_migrations?()

    File.mkdir_p!(Path.dirname(database_path))
    File.write!(database_path, "not empty")

    System.delete_env("ALLBERT_DEV_AUTO_MIGRATE")
    System.put_env("ALLBERT_AUTO_MIGRATE", "1")
    refute Database.skip_migrations?()
  end

  test "migration paths include core and checked-in plugin migrations" do
    paths = Database.migration_paths()

    assert Enum.any?(
             paths,
             &(String.contains?(&1, "allbert_assist") and
                 String.ends_with?(&1, "priv/repo/migrations"))
           )

    assert Enum.any?(paths, &String.ends_with?(&1, "plugins/stocksage/priv/repo/migrations"))
  end

  defp configure_repo_database(database_path) do
    current = Application.get_env(:allbert_assist, Repo, [])
    Application.put_env(:allbert_assist, Repo, Keyword.put(current, :database, database_path))
  end

  defp temp_path(name) do
    Path.join(
      System.tmp_dir!(),
      "allbert-database-test-#{System.unique_integer([:positive])}-#{name}"
    )
  end

  defp restore_env(original_env) do
    Enum.each(original_env, fn
      {key, nil} -> System.delete_env(key)
      {key, value} -> System.put_env(key, value)
    end)
  end

  defp restore_app_env(module, nil), do: Application.delete_env(:allbert_assist, module)
  defp restore_app_env(module, value), do: Application.put_env(:allbert_assist, module, value)
end
