defmodule AllbertAssist.Repo.Migrations.IndexPendingFanoutReportOutbox do
  use Ecto.Migration

  def change do
    create index(:objectives, [:completed_at, :id],
             name: :objectives_pending_fanout_report_outbox_idx,
             where: "fanout_role = 'parent' AND report_delivery_state = 'pending'"
           )
  end
end
