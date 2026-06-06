defmodule AllbertAssist.Tools.Discovery.Suggestion do
  @moduledoc """
  Operator-review suggestion derived from discovered tool metadata or
  self-improvement evidence.
  """

  use Ecto.Schema

  import Ecto.Changeset

  alias AllbertAssist.Tools.Discovery.CandidateRecord

  @primary_key {:id, :string, autogenerate: false}
  @foreign_key_type :string

  @statuses ~w(pending accepted dismissed expired)
  @suggestion_types ~w(
    mcp_server_candidate
    trace_to_skill
    trace_to_workflow
    memory_promotion
    memory_update
    template_backed
    marketplace_backed
    capability_gap
    objective
  )
  @provenances ~w(discovery self_improvement)
  @self_improvement_types ~w(
    trace_to_skill
    trace_to_workflow
    memory_promotion
    memory_update
    template_backed
    marketplace_backed
    capability_gap
    objective
  )

  schema "tool_discovery_suggestions" do
    belongs_to :candidate, CandidateRecord, type: :string

    field :suggestion_type, :string
    field :status, :string, default: "pending"
    field :provenance, :string, default: "discovery"
    field :candidate_snapshot, :map, default: %{}
    field :evaluation_snapshot, :map, default: %{}
    field :metadata, :map, default: %{}
    field :expires_at, :utc_datetime_usec
    field :draft_id, :string

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
      :provenance,
      :candidate_snapshot,
      :evaluation_snapshot,
      :metadata,
      :expires_at,
      :draft_id
    ])
    |> validate_required([
      :id,
      :suggestion_type,
      :status,
      :provenance,
      :candidate_snapshot,
      :evaluation_snapshot,
      :metadata
    ])
    |> validate_inclusion(:status, @statuses)
    |> validate_inclusion(:suggestion_type, @suggestion_types)
    |> validate_inclusion(:provenance, @provenances)
    |> validate_length(:id, min: 5, max: 220)
    |> validate_candidate_id()
    |> validate_provenance()
  end

  defp validate_candidate_id(changeset) do
    type = get_field(changeset, :suggestion_type)
    candidate_id = get_field(changeset, :candidate_id)

    cond do
      type == "mcp_server_candidate" ->
        changeset
        |> validate_required([:candidate_id])
        |> validate_length(:candidate_id, min: 5, max: 220)

      type in @self_improvement_types and candidate_id not in [nil, ""] ->
        add_error(changeset, :candidate_id, "must be empty for self-improvement suggestions")

      true ->
        changeset
    end
  end

  defp validate_provenance(changeset) do
    type = get_field(changeset, :suggestion_type)
    provenance = get_field(changeset, :provenance)

    cond do
      type == "mcp_server_candidate" and provenance != "discovery" ->
        add_error(changeset, :provenance, "must be discovery for MCP candidate suggestions")

      type in @self_improvement_types and provenance != "self_improvement" ->
        add_error(
          changeset,
          :provenance,
          "must be self_improvement for self-improvement suggestions"
        )

      true ->
        changeset
    end
  end
end
