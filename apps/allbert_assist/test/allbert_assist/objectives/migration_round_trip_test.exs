defmodule AllbertAssist.Objectives.MigrationRoundTripTest do
  use ExUnit.Case, async: false
  @moduletag :db_serial

  defmodule MigrationRepo do
    use Ecto.Repo,
      otp_app: :allbert_assist,
      adapter: Ecto.Adapters.SQLite3
  end

  alias Ecto.Adapters.SQL

  @migrations [
    {20_260_513_000_000, AllbertAssist.Repo.Migrations.CreateConversationHistory,
     "apps/allbert_assist/priv/repo/migrations/20260513000000_create_conversation_history.exs"},
    {20_260_514_000_000, AllbertAssist.Repo.Migrations.CreateScheduledJobs,
     "apps/allbert_assist/priv/repo/migrations/20260514000000_create_scheduled_jobs.exs"},
    {20_260_515_000_000, AllbertAssist.Repo.Migrations.CreateStockSageDomain,
     "plugins/stocksage/priv/repo/migrations/20260515000000_create_stocksage_domain.exs"},
    {20_260_517_000_000, AllbertAssist.Repo.Migrations.AddObjectives,
     "apps/allbert_assist/priv/repo/migrations/20260517000000_add_objectives.exs"},
    {20_260_517_000_100, AllbertAssist.Repo.Migrations.AddObjectiveStepsAndEvents,
     "apps/allbert_assist/priv/repo/migrations/20260517000100_add_objective_steps_and_events.exs"},
    {20_260_517_000_200, AllbertAssist.Repo.Migrations.AddObjectiveColumnsToScheduledJobs,
     "apps/allbert_assist/priv/repo/migrations/20260517000200_add_objective_columns_to_scheduled_jobs.exs"},
    {20_260_517_000_300, AllbertAssist.Repo.Migrations.AddObjectiveColumnsToStockSageTables,
     "plugins/stocksage/priv/repo/migrations/20260517000300_add_objective_columns_to_stocksage_tables.exs"},
    {20_260_517_000_400, AllbertAssist.Repo.Migrations.ExtendStockSageAnalysesForNativeEngine,
     "plugins/stocksage/priv/repo/migrations/20260517000400_extend_stocksage_analyses_for_native_engine.exs"},
    {20_260_518_000_000, AllbertAssist.Repo.Migrations.AddWorkspaceCanvasTables,
     "apps/allbert_assist/priv/repo/migrations/20260518000000_add_workspace_canvas_tables.exs"},
    {20_260_518_000_100, AllbertAssist.Repo.Migrations.AddCompletedAtToConversationThreads,
     "apps/allbert_assist/priv/repo/migrations/20260518000100_add_completed_at_to_conversation_threads.exs"}
  ]

  test "objective and workspace migrations run up and down on an isolated sqlite database" do
    db_path =
      Path.join(
        System.tmp_dir!(),
        "allbert-v024-migration-#{System.unique_integer([:positive])}.db"
      )

    {:ok, pid} = MigrationRepo.start_link(database: db_path, pool_size: 1)
    ensure_migration_modules!()

    on_exit(fn ->
      if Process.alive?(pid) do
        try do
          GenServer.stop(pid)
        catch
          :exit, _reason -> :ok
        end
      end

      File.rm(db_path)
    end)

    Enum.each(@migrations, fn {version, module, _path} ->
      assert :ok = Ecto.Migrator.up(MigrationRepo, version, module, log: false)
    end)

    assert table_exists?("objectives")
    assert table_exists?("objective_steps")
    assert table_exists?("objective_events")
    assert column_exists?("scheduled_jobs", "objective_id")
    assert column_exists?("stocksage_analyses", "objective_id")
    assert column_exists?("stocksage_analyses", "engine")
    assert column_exists?("stocksage_analyses", "parity_diff")
    assert column_exists?("stocksage_analysis_queue", "step_id")
    assert table_exists?("workspace_canvas_tiles")
    assert table_exists?("workspace_canvas_tile_revisions")
    assert table_exists?("workspace_ephemeral_surfaces")
    assert column_exists?("workspace_canvas_tiles", "pinned")
    assert column_exists?("workspace_canvas_tile_revisions", "yjs_update")
    assert column_exists?("workspace_ephemeral_surfaces", "dismissed_by")
    assert column_exists?("conversation_threads", "completed_at")

    @migrations
    |> Enum.reverse()
    |> Enum.each(fn {version, module, _path} ->
      assert :ok = Ecto.Migrator.down(MigrationRepo, version, module, log: false)
    end)

    refute table_exists?("objectives")
    refute table_exists?("objective_steps")
    refute table_exists?("objective_events")
    refute column_exists?("scheduled_jobs", "objective_id")
    refute column_exists?("stocksage_analyses", "objective_id")
    refute column_exists?("stocksage_analyses", "engine")
    refute column_exists?("stocksage_analyses", "parity_diff")
    refute column_exists?("stocksage_analysis_queue", "step_id")
    refute table_exists?("workspace_canvas_tiles")
    refute table_exists?("workspace_canvas_tile_revisions")
    refute table_exists?("workspace_ephemeral_surfaces")
    refute table_exists?("conversation_threads")
  end

  defp ensure_migration_modules! do
    root = Path.expand("../../../../..", __DIR__)

    Enum.each(@migrations, fn {_version, module, path} ->
      unless Code.ensure_loaded?(module) do
        Code.require_file(Path.join(root, path))
      end
    end)
  end

  defp table_exists?(table) do
    %{rows: rows} =
      SQL.query!(
        MigrationRepo,
        "SELECT name FROM sqlite_master WHERE type = 'table' AND name = ?",
        [table]
      )

    rows != []
  end

  defp column_exists?(table, column) do
    %{rows: rows} = SQL.query!(MigrationRepo, "PRAGMA table_info(#{table})", [])

    Enum.any?(rows, fn row -> Enum.at(row, 1) == column end)
  end
end
