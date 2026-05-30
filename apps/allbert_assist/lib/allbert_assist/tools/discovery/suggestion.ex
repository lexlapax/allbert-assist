defmodule AllbertAssist.Tools.Discovery.Suggestion do
  @moduledoc "Operator-review suggestion derived from discovered tool metadata."

  use Ecto.Schema

  import Ecto.Changeset

  alias AllbertAssist.Tools.Discovery.CandidateRecord

  @primary_key {:id, :string, autogenerate: false}
  @foreign_key_type :string

  @statuses ~w(pending accepted dismissed expired)
  @suggestion_types ~w(mcp_server_candidate)

  schema "tool_discovery_suggestions" do
    belongs_to :candidate, CandidateRecord, type: :string

    field :suggestion_type, :string
    field :status, :string, default: "pending"
    field :candidate_snapshot, :map, default: %{}
    field :evaluation_snapshot, :map, default: %{}
    field :metadata, :map, default: %{}

    timestamps(type: :utc_datetime_usec)
  end

  @type t :: %__MODULE__{}

  @doc false
  def changeset(suggestion, attrs) do
    suggestion
    |> cast(attrs, [
      :id,
      :candidate_id,
      :suggestion_type,
      :status,
      :candidate_snapshot,
      :evaluation_snapshot,
      :metadata
    ])
    |> validate_required([
      :id,
      :candidate_id,
      :suggestion_type,
      :status,
      :candidate_snapshot,
      :evaluation_snapshot,
      :metadata
    ])
    |> validate_inclusion(:status, @statuses)
    |> validate_inclusion(:suggestion_type, @suggestion_types)
    |> validate_length(:id, min: 5, max: 220)
    |> validate_length(:candidate_id, min: 5, max: 220)
  end
end
