defmodule AllbertAssist.Repo.Migrations.CreateMcpServerTrustRecords do
  use Ecto.Migration

  def up do
    create table(:mcp_server_trust_records, primary_key: false) do
      add :server_id, :string, primary_key: true

      add :candidate_id,
          references(:tool_discovery_candidates, type: :string, on_delete: :delete_all),
          null: false

      add :tool_definition_hash, :string, null: false
      add :trust_status, :string, null: false, default: "trusted"
      add :transport, :string, null: false
      add :endpoint_fingerprint, :string, null: false
      add :manifest, :map, null: false, default: %{}
      add :evaluation_report, :map, null: false, default: %{}
      add :connected_at, :utc_datetime_usec, null: false
      add :connected_by, :string
      add :metadata, :map, null: false, default: %{}

      timestamps(type: :utc_datetime_usec)
    end

    create index(:mcp_server_trust_records, [:candidate_id],
             name: :mcp_server_trust_records_candidate_idx
           )
  end

  def down do
    drop_if_exists index(:mcp_server_trust_records, [:candidate_id],
                     name: :mcp_server_trust_records_candidate_idx
                   )

    drop table(:mcp_server_trust_records)
  end
end
