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
     "apps/allbert_assist/priv/repo/migrations/20260518000100_add_completed_at_to_conversation_threads.exs"},
    {20_260_715_000_000, AllbertAssist.Repo.Migrations.AddObjectiveOriginColumns,
     "apps/allbert_assist/priv/repo/migrations/20260715000000_add_objective_origin_columns.exs"},
    {20_260_722_000_100, AllbertAssist.Repo.Migrations.AddObjectiveFanoutColumns,
     "apps/allbert_assist/priv/repo/migrations/20260722000100_add_objective_fanout_columns.exs"},
    {20_260_722_000_200, AllbertAssist.Repo.Migrations.CreateChannelNotifyDeliveries,
     "apps/allbert_assist/priv/repo/migrations/20260722000200_create_channel_notify_deliveries.exs"},
    {20_260_725_052_804, AllbertAssist.Repo.Migrations.EnforceUniqueFanoutJoinEvent,
     "apps/allbert_assist/priv/repo/migrations/20260725052804_enforce_unique_fanout_join_event.exs"},
    {20_260_725_052_900, AllbertAssist.Repo.Migrations.IndexPendingFanoutReportOutbox,
     "apps/allbert_assist/priv/repo/migrations/20260725052900_index_pending_fanout_report_outbox.exs"},
    {20_260_731_000_100,
     AllbertAssist.Repo.Migrations.AddConfirmationResumeBindingToObjectiveSteps,
     "apps/allbert_assist/priv/repo/migrations/20260731000100_add_confirmation_resume_binding_to_objective_steps.exs"},
    {20_260_731_000_200, AllbertAssist.Repo.Migrations.AddFanoutReportComposition,
     "apps/allbert_assist/priv/repo/migrations/20260731000200_add_fanout_report_composition.exs"}
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

    Enum.each(Enum.drop(@migrations, -4), fn {version, module, _path} ->
      assert :ok = Ecto.Migrator.up(MigrationRepo, version, module, log: false)
    end)

    SQL.query!(
      MigrationRepo,
      "INSERT INTO objectives (id, user_id, status, title, objective, inserted_at, updated_at) VALUES (?, ?, ?, ?, ?, ?, ?)",
      [
        "pre-m6-objective",
        "alice",
        "open",
        "Existing",
        "Preserve me",
        "2026-07-22T00:00:00Z",
        "2026-07-22T00:00:00Z"
      ]
    )

    for event_id <- ["legacy-join-1", "legacy-join-2"] do
      SQL.query!(
        MigrationRepo,
        "INSERT INTO objective_events (id, objective_id, kind, payload, recorded_at) VALUES (?, ?, 'fanout_joined', '{}', ?)",
        [event_id, "pre-m6-objective", "2026-07-22T00:00:00Z"]
      )
    end

    @migrations
    |> Enum.take(-4)
    |> Enum.each(fn {version, module, _path} ->
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
    assert column_exists?("objectives", "fanout_role")
    assert column_exists?("objectives", "report_delivery_receipt_digest")
    assert index_exists?("objectives_parent_id_idx")
    assert index_exists?("objectives_fanout_start_receipt_digest_index")
    assert table_exists?("channel_notify_deliveries")
    assert index_exists?("channel_notify_deliveries_delivery_key_index")
    assert trigger_exists?("objective_events_one_fanout_join_insert")
    assert trigger_exists?("objective_events_one_fanout_join_update")
    assert index_exists?("objectives_pending_fanout_report_outbox_idx")
    assert column_exists?("objective_steps", "confirmation_resume_params_sha256")
    assert column_exists?("objectives", "report_composition_state")
    assert column_exists?("objectives", "report_body")
    assert column_exists?("objectives", "report_source")
    assert column_exists?("objectives", "report_input_digest")
    assert column_exists?("objectives", "report_selection_digest")
    assert index_exists?("objectives_fanout_report_composition_work_idx")
    assert index_exists?("objective_events_one_fanout_report_selected_idx")
    assert trigger_exists?("objective_steps_frozen_fanout_report_insert")
    assert trigger_exists?("objective_steps_frozen_fanout_report_update")
    assert trigger_exists?("objective_steps_frozen_fanout_report_delete")
    assert trigger_exists?("objectives_frozen_fanout_child_insert")
    assert trigger_exists?("objectives_frozen_fanout_child_update")
    assert trigger_exists?("objectives_frozen_fanout_child_delete")
    assert trigger_exists?("objectives_frozen_fanout_parent_input_update")

    assert SQL.query!(
             MigrationRepo,
             "SELECT count(*) FROM objective_events WHERE objective_id = ? AND kind = 'fanout_joined'",
             ["pre-m6-objective"]
           ).rows == [[2]]

    assert {:error, _constraint} =
             SQL.query(
               MigrationRepo,
               "INSERT INTO objective_events (id, objective_id, kind, payload, recorded_at) VALUES ('new-join', ?, 'fanout_joined', '{}', ?)",
               ["pre-m6-objective", "2026-07-25T00:00:00Z"]
             )

    SQL.query!(
      MigrationRepo,
      "INSERT INTO objective_events (id, objective_id, kind, payload, recorded_at) VALUES ('selected-1', ?, 'fanout_report_selected', '{}', ?)",
      ["pre-m6-objective", "2026-07-31T00:00:00Z"]
    )

    assert {:error, _constraint} =
             SQL.query(
               MigrationRepo,
               "INSERT INTO objective_events (id, objective_id, kind, payload, recorded_at) VALUES ('selected-2', ?, 'fanout_report_selected', '{}', ?)",
               ["pre-m6-objective", "2026-07-31T00:00:01Z"]
             )

    report_input_digest = String.duplicate("a", 64)
    report_selection_digest = String.duplicate("b", 64)
    report_delivery_receipt_digest = String.duplicate("c", 64)

    assert {:error, _constraint} =
             SQL.query(
               MigrationRepo,
               """
               UPDATE objectives
               SET report_composition_state = 'ready',
                   report_input_digest = ?,
                   report_body = 'selected report',
                   report_source = 'model',
                   report_delivery_state = 'pending',
                   report_delivery_receipt_digest = ?
               WHERE id = ?
               """,
               [report_input_digest, report_delivery_receipt_digest, "pre-m6-objective"]
             )

    assert %{num_rows: 1} =
             SQL.query!(
               MigrationRepo,
               """
               UPDATE objectives
               SET report_composition_state = 'ready',
                   report_input_digest = ?,
                   report_selection_digest = ?,
                   report_body = 'selected report',
                   report_source = 'model',
                   report_delivery_state = 'pending',
                   report_delivery_receipt_digest = ?
               WHERE id = ?
               """,
               [
                 report_input_digest,
                 report_selection_digest,
                 report_delivery_receipt_digest,
                 "pre-m6-objective"
               ]
             )

    assert SQL.query!(MigrationRepo, "SELECT count(*) FROM objectives WHERE id = ?", [
             "pre-m6-objective"
           ]).rows == [[1]]

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
    refute table_exists?("channel_notify_deliveries")
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

  defp index_exists?(index) do
    %{rows: rows} =
      SQL.query!(
        MigrationRepo,
        "SELECT name FROM sqlite_master WHERE type = 'index' AND name = ?",
        [index]
      )

    rows != []
  end

  defp trigger_exists?(trigger) do
    %{rows: rows} =
      SQL.query!(
        MigrationRepo,
        "SELECT name FROM sqlite_master WHERE type = 'trigger' AND name = ?",
        [trigger]
      )

    rows != []
  end
end
