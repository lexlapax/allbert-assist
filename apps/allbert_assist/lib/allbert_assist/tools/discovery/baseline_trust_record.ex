defmodule AllbertAssist.Tools.Discovery.BaselineTrustRecord do
  @moduledoc "Baseline hash and trust posture for a discovered MCP server."

  use Ecto.Schema

  import Ecto.Changeset

  alias AllbertAssist.Tools.Discovery.CandidateRecord

  @primary_key {:id, :string, autogenerate: false}
  @foreign_key_type :string

  @trust_statuses ~w(untrusted review_required trusted revoked)
  @provenance_levels ~w(registry_with_source aggregated_with_source registry_metadata_only unknown)

  schema "tool_discovery_baseline_trust_records" do
    belongs_to :candidate, CandidateRecord, type: :string

    field :tool_definition_hash, :string
    field :trust_status, :string, default: "untrusted"
    field :provenance_level, :string
    field :recorded_by, :string
    field :metadata, :map, default: %{}

    timestamps(type: :utc_datetime_usec)
  end

  @type t :: %__MODULE__{}

  @doc false
  def changeset(record, attrs) do
    record
    |> cast(attrs, [
      :id,
      :candidate_id,
      :tool_definition_hash,
      :trust_status,
      :provenance_level,
      :recorded_by,
      :metadata
    ])
    |> validate_required([
      :id,
      :candidate_id,
      :tool_definition_hash,
      :trust_status,
      :provenance_level,
      :metadata
    ])
    |> validate_inclusion(:trust_status, @trust_statuses)
    |> validate_inclusion(:provenance_level, @provenance_levels)
    |> validate_length(:id, min: 5, max: 220)
    |> validate_length(:candidate_id, min: 5, max: 220)
    |> validate_length(:tool_definition_hash, is: 64)
    |> validate_length(:recorded_by, max: 128)
  end
end
