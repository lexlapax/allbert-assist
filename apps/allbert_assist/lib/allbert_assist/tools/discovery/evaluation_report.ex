defmodule AllbertAssist.Tools.Discovery.EvaluationReport do
  @moduledoc "Durable safety and provenance report for a discovered MCP server."

  use Ecto.Schema

  import Ecto.Changeset

  alias AllbertAssist.Tools.Discovery.CandidateRecord

  @primary_key {:id, :string, autogenerate: false}
  @foreign_key_type :string

  @provenance_levels ~w(registry_with_source aggregated_with_source registry_metadata_only unknown)
  @health_statuses ~w(not_probed not_probeable probe_denied reachable http_error unreachable)
  @authority_values ~w(descriptive_metadata_only)

  schema "tool_discovery_evaluation_reports" do
    belongs_to :candidate, CandidateRecord, type: :string

    field :provider, :string
    field :remote_server_id, :string
    field :provenance_level, :string
    field :dangerous_command_flags, :map, default: %{}
    field :health_status, :string
    field :health_diagnostics, :map, default: %{}
    field :tool_definition_hash, :string
    field :metadata_authority, :string
    field :manifest, :map, default: %{}
    field :diagnostics, :map, default: %{}
    field :evaluated_at, :utc_datetime_usec

    timestamps(type: :utc_datetime_usec)
  end

  @type t :: %__MODULE__{}

  @doc false
  def changeset(report, attrs) do
    report
    |> cast(attrs, [
      :id,
      :candidate_id,
      :provider,
      :remote_server_id,
      :provenance_level,
      :dangerous_command_flags,
      :health_status,
      :health_diagnostics,
      :tool_definition_hash,
      :metadata_authority,
      :manifest,
      :diagnostics,
      :evaluated_at
    ])
    |> validate_required([
      :id,
      :candidate_id,
      :provenance_level,
      :dangerous_command_flags,
      :health_status,
      :health_diagnostics,
      :tool_definition_hash,
      :metadata_authority,
      :manifest,
      :diagnostics,
      :evaluated_at
    ])
    |> validate_inclusion(:provenance_level, @provenance_levels)
    |> validate_inclusion(:health_status, @health_statuses)
    |> validate_inclusion(:metadata_authority, @authority_values)
    |> validate_length(:id, min: 5, max: 220)
    |> validate_length(:candidate_id, min: 5, max: 220)
    |> validate_length(:provider, max: 80)
    |> validate_length(:remote_server_id, max: 260)
    |> validate_length(:tool_definition_hash, is: 64)
  end
end
