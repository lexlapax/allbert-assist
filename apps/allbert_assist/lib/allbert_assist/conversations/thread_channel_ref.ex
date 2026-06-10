defmodule AllbertAssist.Conversations.ThreadChannelRef do
  @moduledoc """
  Durable mapping from a canonical Allbert thread to a provider thread root.

  Provider ids are lookup metadata only. They never grant authority and never
  replace `conversation_threads.id` as the canonical thread id.
  """

  use Ecto.Schema

  import Ecto.Changeset

  alias AllbertAssist.Conversations.Thread

  @foreign_key_type :string

  schema "thread_channel_refs" do
    belongs_to :canonical_thread, Thread,
      foreign_key: :canonical_thread_id,
      references: :id,
      type: :string

    field :owner_scope, :string, default: "local"
    field :channel, :string
    field :receiver_account_ref, :string
    field :provider_thread_key, :string
    field :provider_thread_ref, :map, default: %{}

    timestamps(type: :utc_datetime_usec)
  end

  @type t :: %__MODULE__{}

  @doc false
  def changeset(ref, attrs) do
    ref
    |> cast(attrs, [
      :owner_scope,
      :canonical_thread_id,
      :channel,
      :receiver_account_ref,
      :provider_thread_key,
      :provider_thread_ref
    ])
    |> validate_required([
      :owner_scope,
      :canonical_thread_id,
      :channel,
      :receiver_account_ref,
      :provider_thread_key,
      :provider_thread_ref
    ])
    |> validate_length(:owner_scope, min: 1, max: 64)
    |> validate_length(:canonical_thread_id, min: 5, max: 160)
    |> validate_length(:channel, min: 1, max: 64)
    |> validate_length(:receiver_account_ref, min: 1, max: 160)
    |> validate_length(:provider_thread_key, min: 1, max: 160)
    |> foreign_key_constraint(:canonical_thread_id)
    |> unique_constraint([:owner_scope, :channel, :receiver_account_ref, :provider_thread_key],
      name: :thread_channel_refs_owner_channel_provider_uidx
    )
  end
end
