defmodule AllbertAssist.Artifacts.ThreadLink do
  @moduledoc """
  Queryable provenance edge between an artifact and a conversation thread.

  Thread and message ids are durable provenance strings. They are not foreign
  keys and never grant artifact authority; registered actions still enforce
  `:artifact_read`, `:artifact_write`, and `:artifact_delete`.
  """

  use Ecto.Schema

  import Ecto.Changeset

  alias AllbertAssist.Artifacts.Store

  @roles ~w[created_by referenced_by]

  @primary_key {:id, :string, autogenerate: false}

  schema "artifact_thread_links" do
    field :artifact_sha256, :string
    field :thread_id, :string
    field :message_id, :string
    field :role, :string
    field :user_id, :string
    field :metadata, :map, default: %{}

    timestamps(type: :utc_datetime_usec)
  end

  @type t :: %__MODULE__{}

  @doc false
  def changeset(link, attrs) do
    link
    |> cast(attrs, [
      :id,
      :artifact_sha256,
      :thread_id,
      :message_id,
      :role,
      :user_id,
      :metadata
    ])
    |> validate_required([:id, :artifact_sha256, :thread_id, :role, :user_id, :metadata])
    |> validate_length(:id, min: 8, max: 80)
    |> validate_change(:artifact_sha256, fn :artifact_sha256, sha256 ->
      if Store.valid_sha256?(sha256), do: [], else: [artifact_sha256: "is invalid"]
    end)
    |> validate_length(:thread_id, min: 1, max: 160)
    |> validate_length(:message_id, max: 160)
    |> validate_inclusion(:role, @roles)
    |> validate_length(:user_id, min: 1, max: 128)
  end
end
