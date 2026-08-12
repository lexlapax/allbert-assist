defmodule StockSage.Domain.MemoryEntry do
  @moduledoc "StockSage-local memory record. This is not markdown Allbert memory."

  use Ecto.Schema

  import Ecto.Changeset

  alias StockSage.Domain
  alias StockSage.Domain.Analysis

  @kinds ~w[note lesson reflection rule]
  @sources ~w[legacy_sqlite operator analysis]

  @primary_key {:id, :string, autogenerate: false}
  @foreign_key_type :string

  schema "stocksage_memory_entries" do
    belongs_to :analysis, Analysis

    field :user_id, :string
    field :kind, :string, default: "note"
    field :content, :string
    field :tags, :map, default: %{}
    field :confidence, :decimal
    field :source, :string, default: "operator"
    field :legacy_source, :string
    field :legacy_id, :string
    field :promoted_to_allbert_memory, :boolean, default: false
    field :allbert_memory_path, :string
    field :metadata, :map, default: %{}

    timestamps(type: :utc_datetime_usec)
  end

  @type t :: %__MODULE__{}

  @doc false
  def changeset(entry, attrs) do
    entry
    |> cast(attrs, [
      :id,
      :user_id,
      :analysis_id,
      :kind,
      :content,
      :tags,
      :confidence,
      :source,
      :legacy_source,
      :legacy_id,
      :promoted_to_allbert_memory,
      :allbert_memory_path,
      :metadata
    ])
    |> update_change(:user_id, &Domain.normalize_user_id/1)
    |> validate_required([:id, :user_id, :kind, :content, :source])
    |> validate_inclusion(:kind, @kinds)
    |> validate_inclusion(:source, @sources)
    |> validate_length(:id, min: 5, max: 80)
    |> validate_length(:user_id, min: 1, max: 128)
    |> validate_length(:content, min: 1, max: 16_000)
    |> validate_number(:confidence, greater_than_or_equal_to: 0, less_than_or_equal_to: 1)
    |> foreign_key_constraint(:analysis_id)
    |> unique_constraint([:user_id, :legacy_source, :legacy_id],
      name: :stocksage_memory_user_legacy_idx
    )
  end

  def kinds, do: @kinds
  def sources, do: @sources
end
