defmodule StockSage.Domain.AnalysisDetail do
  @moduledoc "Section-level detail attached to a StockSage analysis."

  use Ecto.Schema

  import Ecto.Changeset

  alias StockSage.Domain
  alias StockSage.Domain.Analysis

  @primary_key {:id, :string, autogenerate: false}
  @foreign_key_type :string

  schema "stocksage_analysis_details" do
    belongs_to :analysis, Analysis

    field :user_id, :string
    field :section, :string
    field :agent, :string
    field :content, :string
    field :payload, :map, default: %{}
    field :legacy_source, :string
    field :legacy_id, :string

    timestamps(type: :utc_datetime_usec)
  end

  @type t :: %__MODULE__{}

  @doc false
  def changeset(detail, attrs) do
    detail
    |> cast(attrs, [
      :id,
      :analysis_id,
      :user_id,
      :section,
      :agent,
      :content,
      :payload,
      :legacy_source,
      :legacy_id
    ])
    |> update_change(:user_id, &Domain.normalize_user_id/1)
    |> validate_required([:id, :analysis_id, :user_id, :section])
    |> validate_length(:id, min: 5, max: 80)
    |> validate_length(:analysis_id, min: 5, max: 80)
    |> validate_length(:user_id, min: 1, max: 128)
    |> validate_length(:section, min: 1, max: 120)
    |> validate_length(:agent, max: 120)
    |> validate_length(:content, max: 16_000)
    |> foreign_key_constraint(:analysis_id)
    |> unique_constraint([:analysis_id, :legacy_source, :legacy_id],
      name: :stocksage_details_analysis_legacy_idx
    )
  end
end
