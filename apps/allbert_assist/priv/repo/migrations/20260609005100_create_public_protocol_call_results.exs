defmodule AllbertAssist.Repo.Migrations.CreatePublicProtocolCallResults do
  use Ecto.Migration

  def change do
    create table(:public_protocol_call_results, primary_key: false) do
      add :id, :string, primary_key: true
      add :surface, :string, null: false
      add :client_id, :string, null: false
      add :action_label, :string
      add :turn_label, :string
      add :confirmation_id, :string
      add :trace_id, :string
      add :status, :string, null: false, default: "pending"
      add :result, :map, null: false, default: %{}
      add :error, :map, null: false, default: %{}
      add :trace_metadata, :map, null: false, default: %{}
      add :resolved_at, :utc_datetime_usec
      add :expires_at, :utc_datetime_usec, null: false
      add :expired_at, :utc_datetime_usec

      timestamps(type: :utc_datetime_usec)
    end

    create index(:public_protocol_call_results, [:surface, :client_id, :id],
             name: :public_protocol_call_results_client_idx
           )

    create index(:public_protocol_call_results, [:confirmation_id],
             name: :public_protocol_call_results_confirmation_idx
           )

    create index(:public_protocol_call_results, [:status, :expires_at],
             name: :public_protocol_call_results_expiry_idx
           )
  end
end
