defmodule AllbertAssist.Repo.Migrations.CreateToolDiscoveryRecords do
  use Ecto.Migration

  def up do
    create table(:tool_discovery_candidates, primary_key: false) do
      add :id, :string, primary_key: true
      add :name, :string, null: false
      add :description, :text, null: false, default: ""
      add :source, :string, null: false
      add :usable_now, :boolean, null: false, default: false
      add :requires, :string, null: false
      add :provider, :string
      add :remote_server_id, :string
      add :manifest_url, :text
      add :server_url, :text
      add :provenance, :map, null: false, default: %{}
      add :signals, :map, null: false, default: %{}
      add :registry_record, :map, null: false, default: %{}
      add :first_seen_at, :utc_datetime_usec, null: false
      add :last_seen_at, :utc_datetime_usec, null: false

      timestamps(type: :utc_datetime_usec)
    end

    create index(:tool_discovery_candidates, [:source, :name],
             name: :tool_discovery_candidates_source_name_idx
           )

    create index(:tool_discovery_candidates, [:provider, :remote_server_id],
             name: :tool_discovery_candidates_provider_server_idx
           )

    create table(:tool_discovery_evaluation_reports, primary_key: false) do
      add :id, :string, primary_key: true

      add :candidate_id,
          references(:tool_discovery_candidates, type: :string, on_delete: :delete_all),
          null: false

      add :provider, :string
      add :remote_server_id, :string
      add :provenance_level, :string, null: false
      add :dangerous_command_flags, :map, null: false, default: %{}
      add :health_status, :string, null: false
      add :health_diagnostics, :map, null: false, default: %{}
      add :tool_definition_hash, :string, null: false
      add :metadata_authority, :string, null: false
      add :manifest, :map, null: false, default: %{}
      add :diagnostics, :map, null: false, default: %{}
      add :evaluated_at, :utc_datetime_usec, null: false

      timestamps(type: :utc_datetime_usec)
    end

    create unique_index(:tool_discovery_evaluation_reports, [:candidate_id],
             name: :tool_discovery_evaluation_reports_candidate_idx
           )

    create index(:tool_discovery_evaluation_reports, [:tool_definition_hash],
             name: :tool_discovery_evaluation_reports_hash_idx
           )

    create table(:tool_discovery_suggestions, primary_key: false) do
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

    create index(:tool_discovery_suggestions, [:status, :inserted_at],
             name: :tool_discovery_suggestions_status_inserted_idx
           )

    create table(:tool_discovery_baseline_trust_records, primary_key: false) do
      add :id, :string, primary_key: true

      add :candidate_id,
          references(:tool_discovery_candidates, type: :string, on_delete: :delete_all),
          null: false

      add :tool_definition_hash, :string, null: false
      add :trust_status, :string, null: false, default: "untrusted"
      add :provenance_level, :string, null: false
      add :recorded_by, :string
      add :metadata, :map, null: false, default: %{}

      timestamps(type: :utc_datetime_usec)
    end

    create unique_index(:tool_discovery_baseline_trust_records, [:candidate_id],
             name: :tool_discovery_baseline_trust_records_candidate_idx
           )
  end

  def down do
    drop_if_exists unique_index(:tool_discovery_baseline_trust_records, [:candidate_id],
                     name: :tool_discovery_baseline_trust_records_candidate_idx
                   )

    drop table(:tool_discovery_baseline_trust_records)

    drop_if_exists index(:tool_discovery_suggestions, [:status, :inserted_at],
                     name: :tool_discovery_suggestions_status_inserted_idx
                   )

    drop table(:tool_discovery_suggestions)

    drop_if_exists index(:tool_discovery_evaluation_reports, [:tool_definition_hash],
                     name: :tool_discovery_evaluation_reports_hash_idx
                   )

    drop_if_exists unique_index(:tool_discovery_evaluation_reports, [:candidate_id],
                     name: :tool_discovery_evaluation_reports_candidate_idx
                   )

    drop table(:tool_discovery_evaluation_reports)

    drop_if_exists index(:tool_discovery_candidates, [:provider, :remote_server_id],
                     name: :tool_discovery_candidates_provider_server_idx
                   )

    drop_if_exists index(:tool_discovery_candidates, [:source, :name],
                     name: :tool_discovery_candidates_source_name_idx
                   )

    drop table(:tool_discovery_candidates)
  end
end
