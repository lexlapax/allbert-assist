defmodule AllbertAssist.Repo.Migrations.ExtendStockSageAnalysesForNativeEngine do
  use Ecto.Migration

  def up do
    alter table(:stocksage_analyses) do
      add :engine, :string, null: false, default: "tradingagents"
      add :parity_diff, :text
    end

    create index(:stocksage_analyses, [:engine], name: :stocksage_analyses_engine_idx)
  end

  def down do
    drop_if_exists index(:stocksage_analyses, [:engine], name: :stocksage_analyses_engine_idx)

    alter table(:stocksage_analyses) do
      remove :parity_diff
      remove :engine
    end
  end
end
