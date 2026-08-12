defmodule AllbertAssist.Repo.Migrations.CreateStockSageDomain do
  use Ecto.Migration

  def change do
    create table(:stocksage_analyses, primary_key: false) do
      add :id, :string, primary_key: true
      add :user_id, :string, null: false
      add :thread_id, :string
      add :session_id, :string
      add :request_id, :string
      add :app_id, :string, null: false, default: "stocksage"
      add :symbol, :string, null: false
      add :analysis_date, :date
      add :status, :string, null: false
      add :source, :string, null: false
      add :recommendation, :string
      add :score, :decimal
      add :summary, :text
      add :legacy_source, :string
      add :legacy_id, :string
      add :input_signal_id, :string
      add :trace_id, :string
      add :metadata, :map, null: false, default: %{}

      timestamps(type: :utc_datetime_usec)
    end

    create index(:stocksage_analyses, [:user_id, :symbol],
             name: :stocksage_analyses_user_symbol_idx
           )

    create index(:stocksage_analyses, [:user_id, :updated_at],
             name: :stocksage_analyses_user_updated_idx
           )

    create unique_index(:stocksage_analyses, [:user_id, :legacy_source, :legacy_id],
             where: "legacy_id IS NOT NULL",
             name: :stocksage_analyses_user_legacy_idx
           )

    create table(:stocksage_analysis_details, primary_key: false) do
      add :id, :string, primary_key: true

      add :analysis_id, references(:stocksage_analyses, type: :string, on_delete: :delete_all),
        null: false

      add :user_id, :string, null: false
      add :section, :string, null: false
      add :agent, :string
      add :content, :text
      add :payload, :map, null: false, default: %{}
      add :legacy_source, :string
      add :legacy_id, :string

      timestamps(type: :utc_datetime_usec)
    end

    create index(:stocksage_analysis_details, [:user_id, :analysis_id],
             name: :stocksage_details_user_analysis_idx
           )

    create unique_index(:stocksage_analysis_details, [:analysis_id, :legacy_source, :legacy_id],
             where: "legacy_id IS NOT NULL",
             name: :stocksage_details_analysis_legacy_idx
           )

    create table(:stocksage_outcomes, primary_key: false) do
      add :id, :string, primary_key: true
      add :analysis_id, references(:stocksage_analyses, type: :string, on_delete: :nilify_all)
      add :user_id, :string, null: false
      add :symbol, :string, null: false
      add :horizon_days, :integer
      add :observed_on, :date
      add :start_price, :decimal
      add :end_price, :decimal
      add :return_pct, :decimal
      add :label, :string, null: false
      add :notes, :text
      add :legacy_source, :string
      add :legacy_id, :string
      add :metadata, :map, null: false, default: %{}

      timestamps(type: :utc_datetime_usec)
    end

    create index(:stocksage_outcomes, [:user_id, :symbol],
             name: :stocksage_outcomes_user_symbol_idx
           )

    create index(:stocksage_outcomes, [:analysis_id], name: :stocksage_outcomes_analysis_idx)

    create unique_index(:stocksage_outcomes, [:user_id, :legacy_source, :legacy_id],
             where: "legacy_id IS NOT NULL",
             name: :stocksage_outcomes_user_legacy_idx
           )

    create table(:stocksage_analysis_queue, primary_key: false) do
      add :id, :string, primary_key: true
      add :user_id, :string, null: false
      add :thread_id, :string
      add :session_id, :string
      add :app_id, :string, null: false, default: "stocksage"
      add :symbol, :string, null: false
      add :requested_for, :date
      add :status, :string, null: false
      add :priority, :string, null: false, default: "normal"
      add :request, :map, null: false, default: %{}
      add :analysis_id, references(:stocksage_analyses, type: :string, on_delete: :nilify_all)
      add :input_signal_id, :string
      add :trace_id, :string
      add :metadata, :map, null: false, default: %{}

      timestamps(type: :utc_datetime_usec)
    end

    create index(:stocksage_analysis_queue, [:user_id, :status],
             name: :stocksage_queue_user_status_idx
           )

    create index(:stocksage_analysis_queue, [:user_id, :symbol],
             name: :stocksage_queue_user_symbol_idx
           )

    create table(:stocksage_queue_runs, primary_key: false) do
      add :id, :string, primary_key: true

      add :queue_id, references(:stocksage_analysis_queue, type: :string, on_delete: :delete_all),
        null: false

      add :user_id, :string, null: false
      add :status, :string, null: false
      add :started_at, :utc_datetime_usec
      add :finished_at, :utc_datetime_usec
      add :analysis_id, references(:stocksage_analyses, type: :string, on_delete: :nilify_all)
      add :error, :map, null: false, default: %{}
      add :metadata, :map, null: false, default: %{}

      timestamps(type: :utc_datetime_usec)
    end

    create index(:stocksage_queue_runs, [:user_id, :queue_id],
             name: :stocksage_queue_runs_user_queue_idx
           )

    create index(:stocksage_queue_runs, [:status], name: :stocksage_queue_runs_status_idx)

    create table(:stocksage_memory_entries, primary_key: false) do
      add :id, :string, primary_key: true
      add :user_id, :string, null: false
      add :analysis_id, references(:stocksage_analyses, type: :string, on_delete: :nilify_all)
      add :kind, :string, null: false
      add :content, :text, null: false
      add :tags, :map, null: false, default: %{}
      add :confidence, :decimal
      add :source, :string, null: false
      add :legacy_source, :string
      add :legacy_id, :string
      add :promoted_to_allbert_memory, :boolean, null: false, default: false
      add :allbert_memory_path, :string
      add :metadata, :map, null: false, default: %{}

      timestamps(type: :utc_datetime_usec)
    end

    create index(:stocksage_memory_entries, [:user_id, :kind],
             name: :stocksage_memory_user_kind_idx
           )

    create unique_index(:stocksage_memory_entries, [:user_id, :legacy_source, :legacy_id],
             where: "legacy_id IS NOT NULL",
             name: :stocksage_memory_user_legacy_idx
           )
  end
end
