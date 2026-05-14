defmodule AllbertAssist.Repo.Migrations.CreateConversationHistory do
  use Ecto.Migration

  def change do
    create table(:conversation_threads, primary_key: false) do
      add :id, :string, primary_key: true
      add :user_id, :string, null: false
      add :title, :string, null: false
      add :kind, :string, null: false, default: "general"
      add :app_id, :string
      add :last_message_at, :utc_datetime_usec, null: false

      timestamps(type: :utc_datetime_usec)
    end

    create index(:conversation_threads, [:user_id])

    create index(:conversation_threads, [:user_id, :app_id, :kind, :last_message_at],
             name: :conversation_threads_recent_idx
           )

    create table(:conversation_messages, primary_key: false) do
      add :id, :string, primary_key: true

      add :thread_id,
          references(:conversation_threads, type: :string, on_delete: :delete_all),
          null: false

      add :user_id, :string, null: false
      add :role, :string, null: false
      add :content, :text, null: false
      add :action_log, :map, null: false, default: %{}
      add :trace_id, :string
      add :input_signal_id, :string
      add :response_signal_id, :string
      add :metadata, :map, null: false, default: %{}

      timestamps(type: :utc_datetime_usec, updated_at: false)
    end

    create index(:conversation_messages, [:thread_id, :inserted_at, :id],
             name: :conversation_messages_thread_order_idx
           )

    create index(:conversation_messages, [:user_id, :inserted_at],
             name: :conversation_messages_user_inserted_idx
           )
  end
end
