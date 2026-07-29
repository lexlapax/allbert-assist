defmodule AllbertAssist.Repo.Migrations.AddTuiReceiptColumnsToChannelEvents do
  use Ecto.Migration

  def change do
    alter table(:channel_events) do
      add :receipt_normalizer_version, :string
      add :receipt_hmac_key_ref, :string
      add :receipt_hmac_key_version, :integer
      add :receipt_payload_hmac, :string
      add :receipt_state, :string
      add :receipt_message_id, :string
      add :receipt_result_ref, :string
      add :receipt_outcome, :string
    end
  end
end
