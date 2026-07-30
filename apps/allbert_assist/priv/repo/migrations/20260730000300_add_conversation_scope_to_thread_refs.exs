defmodule AllbertAssist.Repo.Migrations.AddConversationScopeToThreadRefs do
  use Ecto.Migration

  def change do
    alter table(:thread_channel_refs) do
      add :conversation_scope, :string, null: false, default: "unknown"
    end
  end
end
