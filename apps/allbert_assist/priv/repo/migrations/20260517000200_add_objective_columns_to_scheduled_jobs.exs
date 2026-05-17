defmodule AllbertAssist.Repo.Migrations.AddObjectiveColumnsToScheduledJobs do
  use Ecto.Migration

  def up do
    alter table(:scheduled_jobs) do
      add :objective_id, :string
    end

    create index(:scheduled_jobs, [:objective_id], name: :scheduled_jobs_objective_idx)
  end

  def down do
    drop_if_exists index(:scheduled_jobs, [:objective_id], name: :scheduled_jobs_objective_idx)

    alter table(:scheduled_jobs) do
      remove :objective_id
    end
  end
end
