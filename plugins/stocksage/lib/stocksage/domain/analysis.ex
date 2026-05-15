defmodule StockSage.Domain.Analysis do
  @moduledoc "Local StockSage analysis record stored in the shared Allbert database."

  use Ecto.Schema

  import Ecto.Changeset

  alias StockSage.Domain
  alias StockSage.Domain.{AnalysisDetail, Outcome}

  @statuses ~w[imported queued completed failed]
  @sources ~w[legacy_sqlite manual python_bridge native]

  @primary_key {:id, :string, autogenerate: false}
  @foreign_key_type :string

  schema "stocksage_analyses" do
    has_many :details, AnalysisDetail, foreign_key: :analysis_id
    has_many :outcomes, Outcome, foreign_key: :analysis_id

    field :user_id, :string
    field :thread_id, :string
    field :session_id, :string
    field :request_id, :string
    field :app_id, :string, default: "stocksage"
    field :symbol, :string
    field :analysis_date, :date
    field :status, :string, default: "imported"
    field :source, :string, default: "manual"
    field :recommendation, :string
    field :score, :decimal
    field :summary, :string
    field :legacy_source, :string
    field :legacy_id, :string
    field :input_signal_id, :string
    field :trace_id, :string
    field :metadata, :map, default: %{}

    timestamps(type: :utc_datetime_usec)
  end

  @type t :: %__MODULE__{}

  @doc false
  def changeset(analysis, attrs) do
    analysis
    |> cast(attrs, [
      :id,
      :user_id,
      :thread_id,
      :session_id,
      :request_id,
      :app_id,
      :symbol,
      :analysis_date,
      :status,
      :source,
      :recommendation,
      :score,
      :summary,
      :legacy_source,
      :legacy_id,
      :input_signal_id,
      :trace_id,
      :metadata
    ])
    |> Domain.normalize_common()
    |> validate_required([:id, :user_id, :app_id, :symbol, :status, :source])
    |> validate_inclusion(:status, @statuses)
    |> validate_inclusion(:source, @sources)
    |> Domain.validate_common()
    |> validate_length(:id, min: 5, max: 80)
    |> validate_length(:app_id, is: 9)
    |> validate_length(:recommendation, max: 120)
    |> validate_length(:summary, max: 8_000)
    |> unique_constraint([:user_id, :legacy_source, :legacy_id],
      name: :stocksage_analyses_user_legacy_idx
    )
  end

  def statuses, do: @statuses
  def sources, do: @sources
end
