defmodule AllbertAssist.Repo.Migrations.AddObjectiveColumnsToStockSageTables do
  use Ecto.Migration

  def up do
    alter table(:stocksage_analysis_queue) do
      add :objective_id, :string
      add :step_id, :string
    end

    alter table(:stocksage_analyses) do
      add :objective_id, :string
      add :step_id, :string
    end

    create index(:stocksage_analysis_queue, [:objective_id], name: :stocksage_queue_objective_idx)

    create index(:stocksage_analyses, [:objective_id], name: :stocksage_analyses_objective_idx)
  end

  def down do
    drop_if_exists index(:stocksage_analyses, [:objective_id],
                     name: :stocksage_analyses_objective_idx
                   )

    drop_if_exists index(:stocksage_analysis_queue, [:objective_id],
                     name: :stocksage_queue_objective_idx
                   )

    alter table(:stocksage_analyses) do
      remove :step_id
      remove :objective_id
    end

    alter table(:stocksage_analysis_queue) do
      remove :step_id
      remove :objective_id
    end
  end
end
