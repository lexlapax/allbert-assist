defmodule AllbertAssist.Repo.Migrations.AddObjectives do
  use Ecto.Migration

  def up do
    create table(:objectives, primary_key: false) do
      add :id, :string, primary_key: true
      add :user_id, :string, null: false
      add :source_thread_id, :string
      add :session_id, :string
      add :active_app, :string
      add :status, :string, null: false
      add :title, :string, null: false
      add :objective, :text, null: false
      add :acceptance_criteria, :text
      add :constraints, :text
      add :source_intent, :text
      add :parent_objective_id, :string
      add :current_step_id, :string
      add :progress_summary, :text
      add :last_observation_summary, :text
      add :proposer_hint, :text
      add :loop_count, :integer, null: false, default: 0
      add :completed_at, :utc_datetime_usec

      timestamps(type: :utc_datetime_usec)
    end

    create index(:objectives, [:user_id], name: :objectives_user_id_idx)
    create index(:objectives, [:status], name: :objectives_status_idx)
    create index(:objectives, [:source_thread_id], name: :objectives_source_thread_idx)
    create index(:objectives, [:active_app], name: :objectives_active_app_idx)
    create index(:objectives, [:updated_at], name: :objectives_updated_at_idx)
  end

  def down do
    drop_if_exists index(:objectives, [:updated_at], name: :objectives_updated_at_idx)
    drop_if_exists index(:objectives, [:active_app], name: :objectives_active_app_idx)
    drop_if_exists index(:objectives, [:source_thread_id], name: :objectives_source_thread_idx)
    drop_if_exists index(:objectives, [:status], name: :objectives_status_idx)
    drop_if_exists index(:objectives, [:user_id], name: :objectives_user_id_idx)
    drop table(:objectives)
  end
end
