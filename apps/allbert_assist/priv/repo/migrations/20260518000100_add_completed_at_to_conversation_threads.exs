defmodule AllbertAssist.Repo.Migrations.AddCompletedAtToConversationThreads do
  use Ecto.Migration

  def change do
    alter table(:conversation_threads) do
      add :completed_at, :utc_datetime_usec
    end

    create index(:conversation_threads, [:user_id, :completed_at],
             name: :conversation_threads_user_completed_idx
           )
  end
end
