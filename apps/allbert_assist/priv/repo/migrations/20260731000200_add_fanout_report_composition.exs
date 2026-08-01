defmodule AllbertAssist.Repo.Migrations.AddFanoutReportComposition do
  use Ecto.Migration

  def change do
    alter table(:objectives) do
      add :report_composition_state, :string,
        null: false,
        default: "not_ready",
        check: %{
          name: "objectives_report_composition_state_check",
          expr:
            "report_composition_state IN ('not_ready', 'queued', 'composing', 'ready', 'fallback')"
        }

      add :report_body, :text,
        check: %{
          name: "objectives_report_body_size_check",
          expr: "report_body IS NULL OR length(CAST(report_body AS BLOB)) <= 32768"
        }

      add :report_source, :string,
        check: %{
          name: "objectives_report_source_check",
          expr: "report_source IS NULL OR report_source IN ('model', 'deterministic_fallback')"
        }

      add :report_selection_digest, :string

      add :report_input_digest, :string,
        check: %{
          name: "objectives_report_composition_contract_check",
          expr: """
          (report_composition_state = 'not_ready'
            AND report_input_digest IS NULL
            AND report_selection_digest IS NULL
            AND report_body IS NULL
            AND report_source IS NULL)
          OR
          (report_composition_state IN ('queued', 'composing')
            AND report_input_digest IS NOT NULL
            AND length(report_input_digest) = 64
            AND report_input_digest NOT GLOB '*[^0-9a-f]*'
            AND report_selection_digest IS NULL
            AND report_body IS NULL
            AND report_source IS NULL
            AND report_delivery_state = 'not_ready'
            AND report_delivery_receipt_digest IS NULL)
          OR
          (report_composition_state = 'ready'
            AND report_input_digest IS NOT NULL
            AND length(report_input_digest) = 64
            AND report_input_digest NOT GLOB '*[^0-9a-f]*'
            AND report_selection_digest IS NOT NULL
            AND length(report_selection_digest) = 64
            AND report_selection_digest NOT GLOB '*[^0-9a-f]*'
            AND report_body IS NOT NULL
            AND report_source = 'model'
            AND report_delivery_state IN ('pending', 'delivered')
            AND report_delivery_receipt_digest IS NOT NULL)
          OR
          (report_composition_state = 'fallback'
            AND report_input_digest IS NOT NULL
            AND length(report_input_digest) = 64
            AND report_input_digest NOT GLOB '*[^0-9a-f]*'
            AND report_selection_digest IS NOT NULL
            AND length(report_selection_digest) = 64
            AND report_selection_digest NOT GLOB '*[^0-9a-f]*'
            AND report_body IS NOT NULL
            AND report_source = 'deterministic_fallback'
            AND report_delivery_state IN ('pending', 'delivered')
            AND report_delivery_receipt_digest IS NOT NULL)
          """
        }
    end

    create index(:objectives, [:report_composition_state, :completed_at, :id],
             name: :objectives_fanout_report_composition_work_idx,
             where:
               "fanout_role = 'parent' AND report_composition_state IN ('queued', 'composing')"
           )

    create unique_index(:objective_events, [:objective_id],
             name: :objective_events_one_fanout_report_selected_idx,
             where: "kind = 'fanout_report_selected'"
           )

    execute(
      """
      CREATE TRIGGER objective_steps_frozen_fanout_report_insert
      BEFORE INSERT ON objective_steps
      WHEN EXISTS (
        SELECT 1
        FROM objectives child
        JOIN objectives parent ON parent.id = child.parent_objective_id
        WHERE child.id = NEW.objective_id
          AND child.fanout_role = 'child'
          AND parent.fanout_role = 'parent'
          AND (parent.report_composition_state != 'not_ready'
            OR parent.report_delivery_state != 'not_ready')
      )
      BEGIN
        SELECT RAISE(ABORT, 'fanout report input is frozen');
      END
      """,
      "DROP TRIGGER IF EXISTS objective_steps_frozen_fanout_report_insert"
    )

    execute(
      """
      CREATE TRIGGER objective_steps_frozen_fanout_report_update
      BEFORE UPDATE ON objective_steps
      WHEN EXISTS (
        SELECT 1
        FROM objectives child
        JOIN objectives parent ON parent.id = child.parent_objective_id
        WHERE child.id IN (OLD.objective_id, NEW.objective_id)
          AND child.fanout_role = 'child'
          AND parent.fanout_role = 'parent'
          AND (parent.report_composition_state != 'not_ready'
            OR parent.report_delivery_state != 'not_ready')
      )
      BEGIN
        SELECT RAISE(ABORT, 'fanout report input is frozen');
      END
      """,
      "DROP TRIGGER IF EXISTS objective_steps_frozen_fanout_report_update"
    )

    execute(
      """
      CREATE TRIGGER objective_steps_frozen_fanout_report_delete
      BEFORE DELETE ON objective_steps
      WHEN EXISTS (
        SELECT 1
        FROM objectives child
        JOIN objectives parent ON parent.id = child.parent_objective_id
        WHERE child.id = OLD.objective_id
          AND child.fanout_role = 'child'
          AND parent.fanout_role = 'parent'
          AND (parent.report_composition_state != 'not_ready'
            OR parent.report_delivery_state != 'not_ready')
      )
      BEGIN
        SELECT RAISE(ABORT, 'fanout report input is frozen');
      END
      """,
      "DROP TRIGGER IF EXISTS objective_steps_frozen_fanout_report_delete"
    )

    execute(
      """
      CREATE TRIGGER objectives_frozen_fanout_child_insert
      BEFORE INSERT ON objectives
      WHEN NEW.fanout_role = 'child'
        AND EXISTS (
          SELECT 1
          FROM objectives parent
          WHERE parent.id = NEW.parent_objective_id
            AND parent.fanout_role = 'parent'
            AND (parent.report_composition_state != 'not_ready'
              OR parent.report_delivery_state != 'not_ready')
        )
      BEGIN
        SELECT RAISE(ABORT, 'fanout report child snapshot is frozen');
      END
      """,
      "DROP TRIGGER IF EXISTS objectives_frozen_fanout_child_insert"
    )

    execute(
      """
      CREATE TRIGGER objectives_frozen_fanout_child_update
      BEFORE UPDATE ON objectives
      WHEN (
        OLD.fanout_role = 'child'
        AND EXISTS (
          SELECT 1
          FROM objectives parent
          WHERE parent.id = OLD.parent_objective_id
            AND parent.fanout_role = 'parent'
            AND (parent.report_composition_state != 'not_ready'
              OR parent.report_delivery_state != 'not_ready')
        )
      ) OR (
        NEW.fanout_role = 'child'
        AND EXISTS (
          SELECT 1
          FROM objectives parent
          WHERE parent.id = NEW.parent_objective_id
            AND parent.fanout_role = 'parent'
            AND (parent.report_composition_state != 'not_ready'
              OR parent.report_delivery_state != 'not_ready')
        )
      )
      BEGIN
        SELECT RAISE(ABORT, 'fanout report child snapshot is frozen');
      END
      """,
      "DROP TRIGGER IF EXISTS objectives_frozen_fanout_child_update"
    )

    execute(
      """
      CREATE TRIGGER objectives_frozen_fanout_child_delete
      BEFORE DELETE ON objectives
      WHEN OLD.fanout_role = 'child'
        AND EXISTS (
          SELECT 1
          FROM objectives parent
          WHERE parent.id = OLD.parent_objective_id
            AND parent.fanout_role = 'parent'
            AND (parent.report_composition_state != 'not_ready'
              OR parent.report_delivery_state != 'not_ready')
        )
      BEGIN
        SELECT RAISE(ABORT, 'fanout report child snapshot is frozen');
      END
      """,
      "DROP TRIGGER IF EXISTS objectives_frozen_fanout_child_delete"
    )

    execute(
      """
      CREATE TRIGGER objectives_frozen_fanout_parent_input_update
      BEFORE UPDATE OF title, objective, status, join_outcome, proposer_hint ON objectives
      WHEN OLD.fanout_role = 'parent'
        AND (OLD.report_composition_state != 'not_ready'
          OR OLD.report_delivery_state != 'not_ready')
        AND (NEW.title IS NOT OLD.title
          OR NEW.objective IS NOT OLD.objective
          OR NEW.status IS NOT OLD.status
          OR NEW.join_outcome IS NOT OLD.join_outcome
          OR NEW.proposer_hint IS NOT OLD.proposer_hint)
      BEGIN
        SELECT RAISE(ABORT, 'fanout report parent input is frozen');
      END
      """,
      "DROP TRIGGER IF EXISTS objectives_frozen_fanout_parent_input_update"
    )
  end
end
