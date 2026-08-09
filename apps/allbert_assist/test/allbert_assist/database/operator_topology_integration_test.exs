defmodule AllbertAssist.Database.OperatorTopologyIntegrationTest do
  use ExUnit.Case, async: false

  # Primary lane follows the real non-Sandbox Repo work. The application
  # restart is a secondary global-process blocker, so release.v11 runs this
  # file in its own subprocess step.
  @moduletag :db_serial

  alias AllbertAssist.Conversations
  alias AllbertAssist.Objectives
  alias AllbertAssist.Objectives.Fanout
  alias AllbertAssist.Repo
  alias AllbertAssist.TestSupport.FanoutReportFixture
  alias AllbertAssist.TestSupport.ReadyEffectContext
  alias Ecto.Adapters.SQL.Sandbox

  setup_all do
    original_repo = Application.fetch_env!(:allbert_assist, Repo)
    source_database = Keyword.fetch!(original_repo, :database)

    root =
      Path.join(
        System.tmp_dir!(),
        "allbert-operator-topology-#{System.pid()}-#{System.unique_integer([:positive])}"
      )

    database = Path.join(root, "allbert.sqlite3")

    assert :ok = Application.stop(:allbert_assist)
    File.mkdir_p!(root)
    File.cp!(source_database, database)

    Application.put_env(
      :allbert_assist,
      Repo,
      original_repo
      |> Keyword.drop([:pool])
      |> Keyword.merge(
        database: database,
        pool_size: 1,
        journal_mode: :wal,
        default_transaction_mode: :immediate,
        busy_timeout: 1_000
      )
    )

    assert {:ok, _started} = Application.ensure_all_started(:allbert_assist)

    on_exit(fn ->
      Application.stop(:allbert_assist)
      Application.put_env(:allbert_assist, Repo, original_repo)

      {:ok, _started} = Application.ensure_all_started(:allbert_assist)
      Sandbox.mode(Repo, :manual)
      File.rm_rf!(root)
    end)

    %{database: database}
  end

  test "real Allbert writes and fan-in serialize under the operator pool", %{database: database} do
    assert Repo.config()[:database] == database
    assert Repo.config()[:pool_size] == 1
    assert Repo.config()[:journal_mode] == :wal
    assert Repo.config()[:default_transaction_mode] == :immediate
    assert Repo.config()[:busy_timeout] == 1_000
    refute Repo.config()[:pool] == Sandbox

    assert {:ok, thread} = Conversations.create_general_thread("operator-topology", "Fan-out")

    tasks = Enum.map(1..8, &"operator task #{&1}")

    assert {:ok, %{parent: parent, children: children}} =
             Fanout.frame(
               ReadyEffectContext.attach(%{
                 user_id: "operator-topology",
                 source_thread_id: thread.id,
                 source_channel: "tui",
                 source_surface: "channel",
                 title: "Production-shaped fan-out",
                 objective: "Exercise the single-writer runtime"
               }),
               tasks
             )

    results =
      children
      |> Task.async_stream(
        fn child ->
          with {:ok, _admission} <-
                 Conversations.admit_user_message(thread, "completed #{child.title}", %{}) do
            {:ok, FanoutReportFixture.complete_child!(child, "completed #{child.title}")}
          end
        end,
        max_concurrency: 8,
        ordered: false,
        timeout: 10_000
      )
      |> Enum.to_list()

    assert Enum.all?(results, &match?({:ok, {:ok, _transition}}, &1))
    assert Conversations.message_count(thread) == 8

    assert {:ok, %{status: "completed", join_outcome: "success"}} =
             Objectives.get_objective(parent.id)

    assert Enum.count(Objectives.list_events(parent.id), &(&1.kind == "fanout_joined")) == 1
  end
end
