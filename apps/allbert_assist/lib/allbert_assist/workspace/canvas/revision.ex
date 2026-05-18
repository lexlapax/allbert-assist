defmodule AllbertAssist.Workspace.Canvas.Revision do
  @moduledoc "Browser/offline-originated workspace tile revision metadata."

  use Ecto.Schema

  import Ecto.Changeset

  alias AllbertAssist.Workspace.Canvas.Tile

  @origins ~w[server browser offline_reconnect]
  @primary_key {:id, :string, autogenerate: false}
  @foreign_key_type :string

  schema "workspace_canvas_tile_revisions" do
    belongs_to :tile, Tile

    field :base_revision_id, :string
    field :yjs_update, :binary
    field :state_vector, :binary
    field :text_snapshot, :string
    field :snapshot_yaml_path, :string
    field :origin, :string
    field :conflict_count, :integer, default: 0
    field :authored_by, :string

    timestamps(type: :utc_datetime_usec)
  end

  @type t :: %__MODULE__{}

  @doc false
  def changeset(revision, attrs) do
    revision
    |> cast(attrs, [
      :id,
      :tile_id,
      :base_revision_id,
      :yjs_update,
      :state_vector,
      :text_snapshot,
      :snapshot_yaml_path,
      :origin,
      :conflict_count,
      :authored_by
    ])
    |> validate_required([:id, :tile_id, :origin, :authored_by])
    |> validate_inclusion(:origin, @origins)
    |> validate_number(:conflict_count, greater_than_or_equal_to: 0)
    |> validate_length(:id, min: 5, max: 80)
    |> validate_length(:tile_id, min: 5, max: 80)
    |> validate_length(:base_revision_id, max: 80)
    |> validate_length(:text_snapshot, max: 262_144)
    |> validate_length(:snapshot_yaml_path, max: 512)
    |> validate_length(:authored_by, min: 1, max: 128)
    |> foreign_key_constraint(:tile_id)
  end

  def origins, do: @origins
end
