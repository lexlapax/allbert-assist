defmodule AllbertAssist.Repo.Migrations.AddV13CorpusAndManagedJobContracts do
  use Ecto.Migration

  def change do
    alter table(:conversation_messages) do
      add :origin_thread_ref_id,
          references(:thread_channel_refs, on_delete: :nilify_all)

      add :origin_principal_digest, :string
      add :principal_normalizer_version, :string
    end

    create index(:conversation_messages, [:origin_thread_ref_id],
             name: :conversation_messages_origin_thread_ref_idx
           )

    alter table(:conversation_message_refs) do
      add :thread_channel_ref_id,
          references(:thread_channel_refs, on_delete: :nilify_all)
    end

    create index(:conversation_message_refs, [:thread_channel_ref_id],
             name: :conversation_message_refs_thread_channel_ref_idx
           )

    create table(:conversation_corpus_controls, primary_key: false) do
      add :consumer, :string, primary_key: true
      add :eligibility_epoch, :integer, null: false, default: 0

      timestamps(type: :utc_datetime_usec)
    end

    alter table(:scheduled_job_runs) do
      add :admission_key, :string
    end

    create unique_index(:scheduled_job_runs, [:admission_key],
             where:
               "admission_key IS NOT NULL AND status IN ('queued', 'running', 'needs_confirmation')",
             name: :scheduled_job_runs_open_admission_uidx
           )
  end
end
