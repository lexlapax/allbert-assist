defmodule AllbertAssist.Workspace.Ephemeral.Surface do
  @moduledoc "Durable workspace ephemeral surface metadata."

  use Ecto.Schema

  import Ecto.Changeset

  alias AllbertAssist.Workspace.Catalog

  @dismissed_by ~w[operator gc thread_closed cap_evicted]
  @primary_key {:id, :string, autogenerate: false}
  @foreign_key_type :string

  schema "workspace_ephemeral_surfaces" do
    field :thread_id, :string
    field :user_id, :string
    field :kind, :string
    field :body_yaml_path, :string
    field :pinned, :boolean, default: false
    field :metadata, :map, default: %{}
    field :opened_at, :utc_datetime_usec
    field :dismissed_at, :utc_datetime_usec
    field :dismissed_by, :string
    field :body, :map, virtual: true, default: %{}
  end

  @type t :: %__MODULE__{}

  @doc false
  def changeset(surface, attrs) do
    surface
    |> cast(attrs, [
      :id,
      :thread_id,
      :user_id,
      :kind,
      :body_yaml_path,
      :pinned,
      :metadata,
      :opened_at,
      :dismissed_at,
      :dismissed_by
    ])
    |> validate_required([:id, :thread_id, :user_id, :kind, :body_yaml_path, :opened_at])
    |> validate_inclusion(:kind, known_kinds())
    |> validate_inclusion(:dismissed_by, @dismissed_by)
    |> validate_length(:id, min: 5, max: 80)
    |> validate_length(:thread_id, min: 1, max: 128)
    |> validate_length(:user_id, min: 1, max: 128)
    |> validate_length(:kind, min: 1, max: 64)
    |> validate_length(:body_yaml_path, min: 1, max: 512)
    |> validate_metadata()
    |> unique_constraint(:id, name: "workspace_ephemeral_surfaces_id_index")
  end

  def dismissed_by, do: @dismissed_by

  defp known_kinds, do: Enum.map(Catalog.known_components(), &Atom.to_string/1)

  defp validate_metadata(changeset) do
    validate_change(changeset, :metadata, fn :metadata, metadata ->
      if map_size(metadata) <= 64, do: [], else: [metadata: "must have at most 64 keys"]
    end)
  end
end
