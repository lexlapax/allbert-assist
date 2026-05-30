defmodule AllbertAssist.Tools.Discovery.CandidateRecord do
  @moduledoc "Durable metadata for an inert discovered tool candidate."

  use Ecto.Schema

  import Ecto.Changeset

  @primary_key {:id, :string, autogenerate: false}
  @foreign_key_type :string

  @sources ~w(local_action local_skill configured_mcp remote_mcp)
  @requirements ~w(none connect_confirmation)

  schema "tool_discovery_candidates" do
    field :name, :string
    field :description, :string, default: ""
    field :source, :string
    field :usable_now, :boolean, default: false
    field :requires, :string
    field :provider, :string
    field :remote_server_id, :string
    field :manifest_url, :string
    field :server_url, :string
    field :provenance, :map, default: %{}
    field :signals, :map, default: %{}
    field :registry_record, :map, default: %{}
    field :first_seen_at, :utc_datetime_usec
    field :last_seen_at, :utc_datetime_usec

    timestamps(type: :utc_datetime_usec)
  end

  @type t :: %__MODULE__{}

  @doc false
  def changeset(record, attrs) do
    record
    |> cast(attrs, [
      :id,
      :name,
      :description,
      :source,
      :usable_now,
      :requires,
      :provider,
      :remote_server_id,
      :manifest_url,
      :server_url,
      :provenance,
      :signals,
      :registry_record,
      :first_seen_at,
      :last_seen_at
    ])
    |> validate_required([
      :id,
      :name,
      :description,
      :source,
      :usable_now,
      :requires,
      :provenance,
      :signals,
      :registry_record,
      :first_seen_at,
      :last_seen_at
    ])
    |> validate_inclusion(:source, @sources)
    |> validate_inclusion(:requires, @requirements)
    |> validate_length(:id, min: 5, max: 220)
    |> validate_length(:name, min: 1, max: 240)
    |> validate_length(:provider, max: 80)
    |> validate_length(:remote_server_id, max: 260)
  end
end
