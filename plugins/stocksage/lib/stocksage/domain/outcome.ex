defmodule StockSage.Domain.Outcome do
  @moduledoc "Observed outcome for a StockSage analysis or imported symbol event."

  use Ecto.Schema

  import Ecto.Changeset

  alias StockSage.Domain
  alias StockSage.Domain.Analysis

  @labels ~w[pending win loss neutral unknown]

  @primary_key {:id, :string, autogenerate: false}
  @foreign_key_type :string

  schema "stocksage_outcomes" do
    belongs_to :analysis, Analysis

    field :user_id, :string
    field :symbol, :string
    field :horizon_days, :integer
    field :observed_on, :date
    field :start_price, :decimal
    field :end_price, :decimal
    field :return_pct, :decimal
    field :label, :string, default: "pending"
    field :notes, :string
    field :legacy_source, :string
    field :legacy_id, :string
    field :metadata, :map, default: %{}

    timestamps(type: :utc_datetime_usec)
  end

  @type t :: %__MODULE__{}

  @doc false
  def changeset(outcome, attrs) do
    outcome
    |> cast(attrs, [
      :id,
      :analysis_id,
      :user_id,
      :symbol,
      :horizon_days,
      :observed_on,
      :start_price,
      :end_price,
      :return_pct,
      :label,
      :notes,
      :legacy_source,
      :legacy_id,
      :metadata
    ])
    |> Domain.normalize_common()
    |> validate_required([:id, :user_id, :symbol, :label])
    |> validate_inclusion(:label, @labels)
    |> Domain.validate_common()
    |> validate_length(:id, min: 5, max: 80)
    |> validate_number(:horizon_days, greater_than: 0)
    |> validate_length(:notes, max: 8_000)
    |> foreign_key_constraint(:analysis_id)
    |> unique_constraint([:user_id, :legacy_source, :legacy_id],
      name: :stocksage_outcomes_user_legacy_idx
    )
  end

  def labels, do: @labels
end
