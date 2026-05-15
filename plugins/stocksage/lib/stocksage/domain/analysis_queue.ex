defmodule StockSage.Domain.AnalysisQueue do
  @moduledoc "Durable StockSage queue entry. v0.20 stores intent; later milestones execute it."

  use Ecto.Schema

  import Ecto.Changeset

  alias StockSage.Domain
  alias StockSage.Domain.{Analysis, QueueRun}

  @statuses ~w[queued running completed failed cancelled]
  @priorities ~w[low normal high]

  @primary_key {:id, :string, autogenerate: false}
  @foreign_key_type :string

  schema "stocksage_analysis_queue" do
    has_many :runs, QueueRun, foreign_key: :queue_id
    belongs_to :analysis, Analysis

    field :user_id, :string
    field :thread_id, :string
    field :session_id, :string
    field :app_id, :string, default: "stocksage"
    field :symbol, :string
    field :requested_for, :date
    field :status, :string, default: "queued"
    field :priority, :string, default: "normal"
    field :request, :map, default: %{}
    field :input_signal_id, :string
    field :trace_id, :string
    field :metadata, :map, default: %{}

    timestamps(type: :utc_datetime_usec)
  end

  @type t :: %__MODULE__{}

  @doc false
  def changeset(queue_entry, attrs) do
    queue_entry
    |> cast(attrs, [
      :id,
      :user_id,
      :thread_id,
      :session_id,
      :app_id,
      :symbol,
      :requested_for,
      :status,
      :priority,
      :request,
      :analysis_id,
      :input_signal_id,
      :trace_id,
      :metadata
    ])
    |> Domain.normalize_common()
    |> validate_required([:id, :user_id, :app_id, :symbol, :status, :priority])
    |> validate_inclusion(:status, @statuses)
    |> validate_inclusion(:priority, @priorities)
    |> Domain.validate_common()
    |> validate_length(:id, min: 5, max: 80)
    |> validate_length(:app_id, is: 9)
    |> foreign_key_constraint(:analysis_id)
  end

  def statuses, do: @statuses
  def priorities, do: @priorities
end
