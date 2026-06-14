defmodule AllbertAssist.Repo.Migrations.AddTrustClassToChannelThreadRefs do
  use Ecto.Migration

  def change do
    alter table(:thread_channel_refs) do
      add :trust_class, :string, null: false, default: "server_readable"
    end

    alter table(:conversation_message_refs) do
      add :trust_class, :string, null: false, default: "server_readable"
    end
  end
end
