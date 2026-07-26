defmodule AllbertAssist.Database.SQLiteTopologyTest do
  use ExUnit.Case, async: false

  @moduletag :db_serial

  alias AllbertAssist.Repo
  alias Config.Reader
  alias Ecto.Adapters.SQL

  defmodule OperatorRepo do
    use Ecto.Repo,
      otp_app: :allbert_assist,
      adapter: Ecto.Adapters.SQLite3
  end

  @repo_root Path.expand("../../../../..", __DIR__)

  @operator_options [
    pool_size: 1,
    journal_mode: :wal,
    default_transaction_mode: :immediate,
    busy_timeout: 1_000
  ]

  @approved_transaction_calls %{
    "apps/allbert_assist/lib/allbert_assist/conversations.ex" => 3,
    "apps/allbert_assist/lib/allbert_assist/jobs.ex" => 1,
    "apps/allbert_assist/lib/allbert_assist/objectives.ex" => 1,
    "apps/allbert_assist/lib/allbert_assist/objectives/commands.ex" => 7,
    "apps/allbert_assist/lib/allbert_assist/objectives/fanout.ex" => 2,
    "apps/allbert_assist/lib/allbert_assist/objectives/fanout/terminal_transitions.ex" => 3,
    "apps/allbert_assist/lib/allbert_assist/objectives/lifecycle.ex" => 1,
    "apps/allbert_assist/lib/allbert_assist/objectives/steering.ex" => 1,
    "apps/allbert_assist/lib/allbert_assist/workspace/offline.ex" => 1
  }

  test "development and packaged production use the same single-writer SQLite topology" do
    root =
      Path.join(
        System.tmp_dir!(),
        "allbert-sqlite-topology-#{System.unique_integer([:positive])}"
      )

    restore_env =
      preserve_env(["ALLBERT_HOME", "ALLBERT_HOME_DIR", "DATABASE_PATH", "SECRET_KEY_BASE"])

    System.put_env("ALLBERT_HOME", root)
    System.delete_env("ALLBERT_HOME_DIR")
    System.delete_env("DATABASE_PATH")
    System.put_env("SECRET_KEY_BASE", String.duplicate("s", 64))

    on_exit(fn ->
      restore_env.()
      File.rm_rf!(root)
    end)

    assert_repo_options("config/dev.exs", :dev)
    assert_repo_options("config/runtime.exs", :prod)
  end

  test "the non-Sandbox operator topology serializes concurrent writes without busy failures" do
    root =
      Path.join(
        System.tmp_dir!(),
        "allbert-sqlite-operator-repo-#{System.unique_integer([:positive])}"
      )

    File.mkdir_p!(root)
    database = Path.join(root, "operator.sqlite3")

    assert {:ok, repo} =
             OperatorRepo.start_link(
               database: database,
               pool_size: 1,
               journal_mode: :wal,
               default_transaction_mode: :immediate,
               busy_timeout: 1_000
             )

    Process.unlink(repo)

    on_exit(fn ->
      if Process.alive?(repo), do: GenServer.stop(repo)
      File.rm_rf!(root)
    end)

    assert {:ok, _result} =
             SQL.query(
               OperatorRepo,
               "CREATE TABLE operator_writes (id INTEGER PRIMARY KEY, writer INTEGER NOT NULL)",
               []
             )

    results =
      1..8
      |> Task.async_stream(
        fn writer ->
          Enum.map(1..25, fn offset ->
            id = writer * 1_000 + offset

            SQL.query(
              OperatorRepo,
              "INSERT INTO operator_writes (id, writer) VALUES (?, ?)",
              [id, writer]
            )
          end)
        end,
        max_concurrency: 8,
        ordered: false,
        timeout: 5_000
      )
      |> Enum.to_list()

    assert Enum.all?(results, fn {:ok, writes} ->
             Enum.all?(writes, &match?({:ok, _result}, &1))
           end)

    assert %{rows: [[200]]} =
             SQL.query!(OperatorRepo, "SELECT COUNT(*) FROM operator_writes", [])

    assert %{rows: [["wal"]]} =
             SQL.query!(OperatorRepo, "PRAGMA journal_mode", [])
  end

  test "the reviewed production transaction callsite inventory cannot drift silently" do
    actual =
      [
        "apps/allbert_assist/lib/**/*.ex",
        "apps/allbert_assist_web/lib/**/*.ex",
        "plugins/*/lib/**/*.ex"
      ]
      |> Enum.flat_map(&Path.wildcard(Path.join(@repo_root, &1)))
      |> Enum.reduce(%{}, fn path, inventory ->
        count = Regex.scan(~r/Repo\.transaction\s*\(/, File.read!(path)) |> length()

        if count == 0 do
          inventory
        else
          Map.put(inventory, Path.relative_to(path, @repo_root), count)
        end
      end)

    assert actual == @approved_transaction_calls
  end

  defp assert_repo_options(path, env) do
    repo_options =
      path
      |> then(&Path.join(@repo_root, &1))
      |> Reader.read!(env: env)
      |> get_in([:allbert_assist, Repo])

    Enum.each(@operator_options, fn {key, expected} ->
      assert Keyword.fetch!(repo_options, key) == expected
    end)
  end

  defp preserve_env(names) do
    saved = Map.new(names, &{&1, System.get_env(&1)})

    fn ->
      Enum.each(saved, fn
        {name, nil} -> System.delete_env(name)
        {name, value} -> System.put_env(name, value)
      end)
    end
  end
end
