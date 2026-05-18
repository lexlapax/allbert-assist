defmodule AllbertAssist.Workspace.Canvas.Tile do
  @moduledoc "Durable workspace canvas tile metadata."

  use Ecto.Schema

  import Ecto.Changeset

  alias AllbertAssist.Workspace.Catalog

  @primary_key {:id, :string, autogenerate: false}
  @foreign_key_type :string

  schema "workspace_canvas_tiles" do
    field :thread_id, :string
    field :user_id, :string
    field :kind, :string
    field :position, :integer, default: 0
    field :size_width, :integer, default: 400
    field :size_height, :integer, default: 300
    field :body_yaml_path, :string
    field :current_revision_id, :string
    field :pinned, :boolean, default: false
    field :metadata, :map, default: %{}
    field :deleted_at, :utc_datetime_usec
    field :body, :map, virtual: true, default: %{}
    field :read_only, :boolean, virtual: true, default: false

    timestamps(type: :utc_datetime_usec)
  end

  @type t :: %__MODULE__{}

  @doc false
  def changeset(tile, attrs) do
    tile
    |> cast(attrs, [
      :id,
      :thread_id,
      :user_id,
      :kind,
      :position,
      :size_width,
      :size_height,
      :body_yaml_path,
      :current_revision_id,
      :pinned,
      :metadata,
      :deleted_at
    ])
    |> validate_required([
      :id,
      :thread_id,
      :user_id,
      :kind,
      :position,
      :size_width,
      :size_height,
      :body_yaml_path,
      :metadata
    ])
    |> validate_inclusion(:kind, known_kinds())
    |> validate_number(:position, greater_than_or_equal_to: 0)
    |> validate_number(:size_width, greater_than_or_equal_to: 160, less_than_or_equal_to: 2400)
    |> validate_number(:size_height, greater_than_or_equal_to: 120, less_than_or_equal_to: 2400)
    |> validate_length(:id, min: 5, max: 80)
    |> validate_length(:thread_id, min: 1, max: 128)
    |> validate_length(:user_id, min: 1, max: 128)
    |> validate_length(:kind, min: 1, max: 64)
    |> validate_length(:body_yaml_path, min: 1, max: 512)
    |> validate_length(:current_revision_id, max: 80)
    |> validate_metadata()
  end

  defp known_kinds, do: Enum.map(Catalog.known_components(), &Atom.to_string/1)

  defp validate_metadata(changeset) do
    validate_change(changeset, :metadata, fn :metadata, metadata ->
      if map_size(metadata) <= 64, do: [], else: [metadata: "must have at most 64 keys"]
    end)
  end
end
