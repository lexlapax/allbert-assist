defmodule StockSage.Domain.QueueRun do
  @moduledoc "Execution-attempt record for a StockSage queue entry."

  use Ecto.Schema

  import Ecto.Changeset

  alias StockSage.Domain
  alias StockSage.Domain.{Analysis, AnalysisQueue}

  @statuses ~w[started completed failed cancelled]

  @primary_key {:id, :string, autogenerate: false}
  @foreign_key_type :string

  schema "stocksage_queue_runs" do
    belongs_to :queue, AnalysisQueue
    belongs_to :analysis, Analysis

    field :user_id, :string
    field :status, :string, default: "started"
    field :started_at, :utc_datetime_usec
    field :finished_at, :utc_datetime_usec
    field :error, :map, default: %{}
    field :metadata, :map, default: %{}

    timestamps(type: :utc_datetime_usec)
  end

  @type t :: %__MODULE__{}

  @doc false
  def changeset(run, attrs) do
    run
    |> cast(attrs, [
      :id,
      :queue_id,
      :user_id,
      :status,
      :started_at,
      :finished_at,
      :analysis_id,
      :error,
      :metadata
    ])
    |> update_change(:user_id, &Domain.normalize_user_id/1)
    |> validate_required([:id, :queue_id, :user_id, :status])
    |> validate_inclusion(:status, @statuses)
    |> validate_length(:id, min: 5, max: 80)
    |> validate_length(:queue_id, min: 5, max: 80)
    |> validate_length(:user_id, min: 1, max: 128)
    |> foreign_key_constraint(:queue_id)
    |> foreign_key_constraint(:analysis_id)
  end

  def statuses, do: @statuses
end
