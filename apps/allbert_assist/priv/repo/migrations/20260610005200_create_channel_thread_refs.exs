defmodule AllbertAssist.Repo.Migrations.CreateChannelThreadRefs do
  use Ecto.Migration

  def change do
    create table(:thread_channel_refs) do
      add :owner_scope, :string, null: false, default: "local"

      add :canonical_thread_id,
          references(:conversation_threads, type: :string, on_delete: :delete_all),
          null: false

      add :channel, :string, null: false
      add :receiver_account_ref, :string, null: false
      add :provider_thread_key, :string, null: false
      add :provider_thread_ref, :map, null: false, default: %{}

      timestamps(type: :utc_datetime_usec)
    end

    create index(:thread_channel_refs, [:canonical_thread_id],
             name: :thread_channel_refs_canonical_thread_idx
           )

    create unique_index(
             :thread_channel_refs,
             [:owner_scope, :channel, :receiver_account_ref, :provider_thread_key],
             name: :thread_channel_refs_owner_channel_provider_uidx
           )

    create table(:conversation_message_refs) do
      add :canonical_message_id,
          references(:conversation_messages, type: :string, on_delete: :delete_all),
          null: false

      add :canonical_thread_id,
          references(:conversation_threads, type: :string, on_delete: :delete_all),
          null: false

      add :owner_scope, :string, null: false, default: "local"
      add :channel, :string, null: false
      add :receiver_account_ref, :string, null: false
      add :provider_message_id, :string, null: false
      add :part_id, :string, null: false, default: "0"
      add :direction, :string, null: false

      timestamps(type: :utc_datetime_usec)
    end

    create index(:conversation_message_refs, [:canonical_thread_id],
             name: :conversation_message_refs_thread_idx
           )

    create index(:conversation_message_refs, [:canonical_message_id],
             name: :conversation_message_refs_message_idx
           )

    create unique_index(
             :conversation_message_refs,
             [:owner_scope, :channel, :receiver_account_ref, :provider_message_id, :part_id],
             name: :conversation_message_refs_provider_message_uidx
           )

    create table(:cross_channel_identity_links) do
      add :owner_scope, :string, null: false, default: "local"
      add :link_id, :string, null: false
      add :user_id, :string, null: false
      add :channel, :string, null: false
      add :receiver_account_ref, :string, null: false
      add :external_user_id, :string, null: false

      timestamps(type: :utc_datetime_usec)
    end

    create index(:cross_channel_identity_links, [:user_id],
             name: :cross_channel_identity_links_user_idx
           )

    create unique_index(
             :cross_channel_identity_links,
             [:owner_scope, :link_id, :channel, :receiver_account_ref, :external_user_id],
             name: :cross_channel_identity_links_owner_link_uidx
           )
  end
end
