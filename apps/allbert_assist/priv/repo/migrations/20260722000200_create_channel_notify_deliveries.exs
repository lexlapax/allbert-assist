defmodule AllbertAssist.Repo.Migrations.CreateChannelNotifyDeliveries do
  use Ecto.Migration

  def change do
    create table(:channel_notify_deliveries) do
      add :delivery_key, :string, null: false
      add :fanout_id, :string, null: false
      add :child_objective_id, :string
      add :local_user_id, :string, null: false
      add :channel, :string, null: false
      add :origin_thread_ref_id, :string, null: false
      add :origin_thread_ref_digest, :string, null: false
      add :kind, :string, null: false
      add :state, :string, null: false, default: "reserved"
      add :provider_message_id, :string
      add :throttle_at, :utc_datetime_usec
      add :attempt_count, :integer, null: false, default: 0
      add :error_class, :string
      add :offer_state, :string, null: false, default: "not_applicable"

      timestamps(type: :utc_datetime_usec)
    end

    create unique_index(:channel_notify_deliveries, [:delivery_key])
    create index(:channel_notify_deliveries, [:fanout_id, :channel, :kind])
  end
end
