defmodule AllbertAssist.Repo.Migrations.CreateMemoryConsolidationControls do
  use Ecto.Migration

  def change do
    create table(:memory_consolidation_controls, primary_key: false) do
      add :id, :string, primary_key: true
      add :operator_id, :string, null: false
      add :origin_scope, :string, null: false
      add :e2ee, :boolean, null: false, default: false
      add :cursor_inserted_at, :utc_datetime_usec
      add :cursor_source_id, :string
      add :run_sequence, :integer, null: false, default: 0
      add :last_run, :map, null: false, default: %{}

      timestamps(type: :utc_datetime_usec)
    end

    create unique_index(
             :memory_consolidation_controls,
             [:operator_id, :origin_scope, :e2ee],
             name: :memory_consolidation_controls_scope_uidx
           )
  end
end
