defmodule AllbertAssist.Repo.Migrations.SplitMcpServerTrustBaseline do
  use Ecto.Migration

  def up do
    alter table(:mcp_server_trust_records) do
      add :manifest_definition_hash, :string
      add :connected_tool_definition_hash, :string
      add :baseline_status, :string, null: false, default: "pending_live_verification"
    end

    execute("""
    UPDATE mcp_server_trust_records
    SET manifest_definition_hash = tool_definition_hash
    WHERE manifest_definition_hash IS NULL
    """)

    create index(:mcp_server_trust_records, [:baseline_status],
             name: :mcp_server_trust_records_baseline_status_idx
           )
  end

  def down do
    drop_if_exists index(:mcp_server_trust_records, [:baseline_status],
                     name: :mcp_server_trust_records_baseline_status_idx
                   )

    alter table(:mcp_server_trust_records) do
      remove :baseline_status
      remove :connected_tool_definition_hash
      remove :manifest_definition_hash
    end
  end
end
