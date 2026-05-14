defmodule AllbertAssist.Repo.Migrations.CreateChannelEvents do
  use Ecto.Migration

  def change do
    create table(:channel_events) do
      add :channel, :string, null: false
      add :provider, :string, null: false
      add :direction, :string, null: false
      add :external_event_id, :string, null: false
      add :external_user_id, :string
      add :external_chat_id, :string
      add :external_message_id, :string
      add :user_id, :string
      add :session_id, :string
      add :thread_id, :string
      add :input_signal_id, :string
      add :trace_id, :string
      add :status, :string, null: false
      add :reason, :string
      add :payload_summary, :string
      add :error, :string

      timestamps(type: :utc_datetime_usec)
    end

    create unique_index(:channel_events, [:channel, :external_event_id],
             where: "direction IN ('inbound', 'callback')",
             name: :channel_events_inbound_callback_dedup
           )

    create index(:channel_events, [:channel, :user_id], name: :channel_events_channel_user_idx)

    create index(:channel_events, [:channel, :external_user_id],
             name: :channel_events_channel_external_user_idx
           )

    create index(:channel_events, [:status], name: :channel_events_status_idx)
  end
end
