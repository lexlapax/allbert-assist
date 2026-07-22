defmodule AllbertAssist.Repo.Migrations.AddObjectiveFanoutColumns do
  use Ecto.Migration

  def change do
    alter table(:objectives) do
      add :fanout_role, :string
      add :join_policy, :string
      add :join_outcome, :string
      add :kickoff_delivery_state, :string
      add :fanout_start_receipt_digest, :string
      add :report_delivery_state, :string
      add :report_delivery_receipt_digest, :string
      add :origin_thread_ref_id, :string
      add :origin_thread_ref_digest, :string
      add :origin_receiver_account_ref, :string
      add :queue_position, :integer
      add :run_attempt_count, :integer, null: false, default: 0
      add :review_reason, :string
    end

    create index(:objectives, [:parent_objective_id], name: :objectives_parent_id_idx)

    create unique_index(:objectives, [:fanout_start_receipt_digest],
             where: "fanout_start_receipt_digest IS NOT NULL"
           )

    create unique_index(:objectives, [:report_delivery_receipt_digest],
             where: "report_delivery_receipt_digest IS NOT NULL"
           )
  end
end
