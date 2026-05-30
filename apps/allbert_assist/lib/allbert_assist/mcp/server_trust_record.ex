defmodule AllbertAssist.Mcp.ServerTrustRecord do
  @moduledoc "Approved baseline trust record for a configured MCP server."

  use Ecto.Schema

  import Ecto.Changeset

  alias AllbertAssist.Tools.Discovery.CandidateRecord

  @primary_key {:server_id, :string, autogenerate: false}
  @foreign_key_type :string

  @trust_statuses ~w(trusted revoked review_required)
  @transports ~w(stdio sse streamable_http)

  schema "mcp_server_trust_records" do
    belongs_to :candidate, CandidateRecord, type: :string

    field :tool_definition_hash, :string
    field :trust_status, :string, default: "trusted"
    field :transport, :string
    field :endpoint_fingerprint, :string
    field :manifest, :map, default: %{}
    field :evaluation_report, :map, default: %{}
    field :connected_at, :utc_datetime_usec
    field :connected_by, :string
    field :metadata, :map, default: %{}

    timestamps(type: :utc_datetime_usec)
  end

  @type t :: %__MODULE__{}

  @doc false
  def changeset(record, attrs) do
    record
    |> cast(attrs, [
      :server_id,
      :candidate_id,
      :tool_definition_hash,
      :trust_status,
      :transport,
      :endpoint_fingerprint,
      :manifest,
      :evaluation_report,
      :connected_at,
      :connected_by,
      :metadata
    ])
    |> validate_required([
      :server_id,
      :candidate_id,
      :tool_definition_hash,
      :trust_status,
      :transport,
      :endpoint_fingerprint,
      :manifest,
      :evaluation_report,
      :connected_at,
      :metadata
    ])
    |> validate_inclusion(:trust_status, @trust_statuses)
    |> validate_inclusion(:transport, @transports)
    |> validate_length(:server_id, min: 1, max: 80)
    |> validate_length(:candidate_id, min: 5, max: 220)
    |> validate_length(:tool_definition_hash, is: 64)
    |> validate_length(:endpoint_fingerprint, min: 1, max: 260)
    |> validate_length(:connected_by, max: 128)
  end
end
