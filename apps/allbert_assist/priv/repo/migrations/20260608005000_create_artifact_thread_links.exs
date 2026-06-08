defmodule AllbertAssist.Repo.Migrations.CreateArtifactThreadLinks do
  use Ecto.Migration

  def change do
    create table(:artifact_thread_links, primary_key: false) do
      add :id, :string, primary_key: true
      add :artifact_sha256, :string, null: false
      add :thread_id, :string, null: false
      add :message_id, :string
      add :role, :string, null: false
      add :user_id, :string, null: false
      add :metadata, :map, null: false, default: %{}

      timestamps(type: :utc_datetime_usec)
    end

    create index(:artifact_thread_links, [:artifact_sha256])
    create index(:artifact_thread_links, [:thread_id, :user_id])
    create index(:artifact_thread_links, [:user_id, :artifact_sha256])

    create index(:conversation_messages, [:user_id, :thread_id, :input_signal_id],
             name: :conversation_messages_input_signal_idx
           )
  end
end
