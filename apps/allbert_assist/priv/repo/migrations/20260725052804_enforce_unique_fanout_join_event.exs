defmodule AllbertAssist.Repo.Migrations.EnforceUniqueFanoutJoinEvent do
  use Ecto.Migration

  # Preserve append-only history from installations that may already contain
  # duplicate join events while preventing any new duplicate. A partial unique
  # index cannot be added when legacy duplicates exist; guards give upgraded
  # homes the same forward invariant without rewriting audit evidence.
  def up do
    execute("""
    CREATE TRIGGER objective_events_one_fanout_join_insert
    BEFORE INSERT ON objective_events
    WHEN NEW.kind = 'fanout_joined'
      AND EXISTS (
        SELECT 1 FROM objective_events
        WHERE objective_id = NEW.objective_id AND kind = 'fanout_joined'
      )
    BEGIN
      SELECT RAISE(ABORT, 'fanout_joined event already exists');
    END
    """)

    execute("""
    CREATE TRIGGER objective_events_one_fanout_join_update
    BEFORE UPDATE OF objective_id, kind ON objective_events
    WHEN NEW.kind = 'fanout_joined'
      AND EXISTS (
        SELECT 1 FROM objective_events
        WHERE objective_id = NEW.objective_id
          AND kind = 'fanout_joined'
          AND id != OLD.id
      )
    BEGIN
      SELECT RAISE(ABORT, 'fanout_joined event already exists');
    END
    """)
  end

  def down do
    execute("DROP TRIGGER IF EXISTS objective_events_one_fanout_join_update")
    execute("DROP TRIGGER IF EXISTS objective_events_one_fanout_join_insert")
  end
end
