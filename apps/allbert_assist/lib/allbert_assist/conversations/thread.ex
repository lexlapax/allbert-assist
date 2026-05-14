defmodule AllbertAssist.Conversations.Thread do
  @moduledoc """
  SQLite-backed conversation thread for local workspace history.

  Threads are scoped by string `user_id`; they are not hosted accounts and do
  not grant authorization.
  """

  use Ecto.Schema

  import Ecto.Changeset

  @primary_key {:id, :string, autogenerate: false}
  @foreign_key_type :string

  schema "conversation_threads" do
    field :user_id, :string
    field :title, :string
    field :kind, :string, default: "general"
    field :app_id, :string
    field :last_message_at, :utc_datetime_usec

    timestamps(type: :utc_datetime_usec)
  end

  @type t :: %__MODULE__{}

  @doc false
  def changeset(thread, attrs) do
    thread
    |> cast(attrs, [:id, :user_id, :title, :kind, :app_id, :last_message_at])
    |> validate_required([:id, :user_id, :title, :kind, :last_message_at])
    |> validate_length(:id, min: 5)
    |> validate_length(:user_id, min: 1, max: 128)
    |> validate_length(:title, min: 1, max: 160)
    |> validate_length(:kind, min: 1, max: 64)
  end

  @doc false
  def last_message_changeset(thread, timestamp) do
    thread
    |> change(last_message_at: timestamp)
    |> validate_required([:last_message_at])
  end
end
