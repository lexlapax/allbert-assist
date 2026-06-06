defmodule AllbertAssist.Repo.Migrations.GeneralizeToolDiscoverySuggestions do
  use Ecto.Migration

  @table :tool_discovery_suggestions
  @legacy_table :tool_discovery_suggestions_legacy_v047_m2
  @status_index :tool_discovery_suggestions_status_inserted_idx

  def up do
    drop_if_exists index(@table, [:status, :inserted_at], name: @status_index)
    rename table(@table), to: table(@legacy_table)
    create_generalized_table()

    execute("""
    INSERT INTO tool_discovery_suggestions (
      id,
      candidate_id,
      suggestion_type,
      status,
      provenance,
      candidate_snapshot,
      evaluation_snapshot,
      metadata,
      expires_at,
      draft_id,
      inserted_at,
      updated_at
    )
    SELECT
      id,
      candidate_id,
      suggestion_type,
      status,
      'discovery',
      candidate_snapshot,
      evaluation_snapshot,
      metadata,
      NULL,
      NULL,
      inserted_at,
      updated_at
    FROM tool_discovery_suggestions_legacy_v047_m2
    """)

    drop table(@legacy_table)
    create_status_index()
  end

  def down do
    execute("DELETE FROM tool_discovery_suggestions WHERE candidate_id IS NULL")

    drop_if_exists index(@table, [:status, :inserted_at], name: @status_index)
    rename table(@table), to: table(@legacy_table)
    create_legacy_table()

    execute("""
    INSERT INTO tool_discovery_suggestions (
      id,
      candidate_id,
      suggestion_type,
      status,
      candidate_snapshot,
      evaluation_snapshot,
      metadata,
      inserted_at,
      updated_at
    )
    SELECT
      id,
      candidate_id,
      suggestion_type,
      status,
      candidate_snapshot,
      evaluation_snapshot,
      metadata,
      inserted_at,
      updated_at
    FROM tool_discovery_suggestions_legacy_v047_m2
    WHERE candidate_id IS NOT NULL
    """)

    drop table(@legacy_table)
    create_status_index()
  end

  defp create_generalized_table do
    create table(@table, primary_key: false) do
      add :id, :string, primary_key: true

      add :candidate_id,
          references(:tool_discovery_candidates, type: :string, on_delete: :delete_all),
          null: true

      add :suggestion_type, :string, null: false
      add :status, :string, null: false, default: "pending"
      add :provenance, :string, null: false, default: "discovery"
      add :candidate_snapshot, :map, null: false, default: %{}
      add :evaluation_snapshot, :map, null: false, default: %{}
      add :metadata, :map, null: false, default: %{}
      add :expires_at, :utc_datetime_usec
      add :draft_id, :string

      timestamps(type: :utc_datetime_usec)
    end
  end

  defp create_legacy_table do
    create table(@table, primary_key: false) do
      add :id, :string, primary_key: true

      add :candidate_id,
          references(:tool_discovery_candidates, type: :string, on_delete: :delete_all),
          null: false

      add :suggestion_type, :string, null: false
      add :status, :string, null: false, default: "pending"
      add :candidate_snapshot, :map, null: false, default: %{}
      add :evaluation_snapshot, :map, null: false, default: %{}
      add :metadata, :map, null: false, default: %{}

      timestamps(type: :utc_datetime_usec)
    end
  end

  defp create_status_index do
    create index(@table, [:status, :inserted_at], name: @status_index)
  end
end
