defmodule AllbertAssist.Repo.Migrations.CreateScheduledJobs do
  use Ecto.Migration

  def change do
    create table(:scheduled_jobs, primary_key: false) do
      add :id, :string, primary_key: true
      add :name, :string, null: false
      add :description, :text
      add :target_type, :string, null: false
      add :target, :map, null: false, default: %{}
      add :schedule, :map, null: false, default: %{}
      add :timezone, :string, null: false
      add :status, :string, null: false
      add :user_id, :string, null: false
      add :operator_id, :string, null: false
      add :thread_id, :string
      add :thread_mode, :string, null: false
      add :session_id, :string
      add :app_id, :string
      add :channel, :string, null: false, default: "job"
      add :next_due_at, :utc_datetime_usec
      add :last_run_at, :utc_datetime_usec
      add :blocked_confirmation_id, :string
      add :metadata, :map, null: false, default: %{}

      timestamps(type: :utc_datetime_usec)
    end

    create unique_index(:scheduled_jobs, [:user_id, :name], name: :scheduled_jobs_user_name_idx)

    create index(:scheduled_jobs, [:status, :next_due_at], name: :scheduled_jobs_due_idx)
    create index(:scheduled_jobs, [:user_id, :status], name: :scheduled_jobs_user_status_idx)

    create table(:scheduled_job_runs, primary_key: false) do
      add :id, :string, primary_key: true

      add :job_id,
          references(:scheduled_jobs, type: :string, on_delete: :restrict),
          null: false

      add :status, :string, null: false
      add :trigger, :string, null: false
      add :due_at, :utc_datetime_usec
      add :started_at, :utc_datetime_usec
      add :finished_at, :utc_datetime_usec
      add :duration_ms, :integer
      add :user_id, :string, null: false
      add :operator_id, :string, null: false
      add :thread_id, :string
      add :session_id, :string
      add :app_id, :string
      add :input_signal_id, :string
      add :response_signal_id, :string
      add :trace_id, :string
      add :confirmation_id, :string
      add :decision, :map, null: false, default: %{}
      add :resource_access, :map, null: false, default: %{}
      add :approval_handoff, :map, null: false, default: %{}
      add :action_log, :map, null: false, default: %{}
      add :error, :map, null: false, default: %{}
      add :metadata, :map, null: false, default: %{}

      timestamps(type: :utc_datetime_usec)
    end

    create index(:scheduled_job_runs, [:job_id, :inserted_at],
             name: :scheduled_job_runs_job_order_idx
           )

    create index(:scheduled_job_runs, [:user_id, :inserted_at],
             name: :scheduled_job_runs_user_inserted_idx
           )
  end
end
