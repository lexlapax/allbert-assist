defmodule AllbertAssist.Repo.Migrations.AddObjectiveStepsAndEvents do
  use Ecto.Migration

  def up do
    create table(:objective_steps, primary_key: false) do
      add :id, :string, primary_key: true

      add :objective_id, references(:objectives, type: :string, on_delete: :delete_all),
        null: false

      add :parent_step_id, :string
      add :kind, :string, null: false
      add :status, :string, null: false
      add :stage, :string, null: false
      add :provider, :string
      add :candidate_action, :string
      add :delegate_agent_id, :string
      add :action_params, :text
      add :result_summary, :text
      add :observation_summary, :text
      add :trace_id, :string
      add :confirmation_id, :string
      add :resource_access, :text

      timestamps(type: :utc_datetime_usec)
    end

    create index(:objective_steps, [:objective_id], name: :objective_steps_objective_idx)
    create index(:objective_steps, [:status], name: :objective_steps_status_idx)
    create index(:objective_steps, [:kind], name: :objective_steps_kind_idx)
    create index(:objective_steps, [:stage], name: :objective_steps_stage_idx)
    create index(:objective_steps, [:parent_step_id], name: :objective_steps_parent_idx)
    create index(:objective_steps, [:updated_at], name: :objective_steps_updated_at_idx)

    create table(:objective_events, primary_key: false) do
      add :id, :string, primary_key: true

      add :objective_id, references(:objectives, type: :string, on_delete: :delete_all),
        null: false

      add :step_id, references(:objective_steps, type: :string, on_delete: :nilify_all)
      add :kind, :string, null: false
      add :summary, :text
      add :payload, :text
      add :recorded_at, :utc_datetime_usec, null: false
    end

    create index(:objective_events, [:objective_id], name: :objective_events_objective_idx)
    create index(:objective_events, [:kind], name: :objective_events_kind_idx)
    create index(:objective_events, [:recorded_at], name: :objective_events_recorded_at_idx)
  end

  def down do
    drop_if_exists index(:objective_events, [:recorded_at],
                     name: :objective_events_recorded_at_idx
                   )

    drop_if_exists index(:objective_events, [:kind], name: :objective_events_kind_idx)

    drop_if_exists index(:objective_events, [:objective_id],
                     name: :objective_events_objective_idx
                   )

    drop table(:objective_events)

    drop_if_exists index(:objective_steps, [:updated_at], name: :objective_steps_updated_at_idx)
    drop_if_exists index(:objective_steps, [:parent_step_id], name: :objective_steps_parent_idx)
    drop_if_exists index(:objective_steps, [:stage], name: :objective_steps_stage_idx)
    drop_if_exists index(:objective_steps, [:kind], name: :objective_steps_kind_idx)
    drop_if_exists index(:objective_steps, [:status], name: :objective_steps_status_idx)
    drop_if_exists index(:objective_steps, [:objective_id], name: :objective_steps_objective_idx)
    drop table(:objective_steps)
  end
end
