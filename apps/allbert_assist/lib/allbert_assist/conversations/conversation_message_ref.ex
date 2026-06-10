defmodule AllbertAssist.Conversations.ConversationMessageRef do
  @moduledoc """
  Provider message id mapping for reply placement, dedupe, and echo checks.

  One canonical conversation message can map to multiple provider parts through
  distinct `part_id` values.
  """

  use Ecto.Schema

  import Ecto.Changeset

  alias AllbertAssist.Conversations.Message
  alias AllbertAssist.Conversations.Thread

  @directions ~w[in out]
  @foreign_key_type :string

  schema "conversation_message_refs" do
    belongs_to :canonical_message, Message,
      foreign_key: :canonical_message_id,
      references: :id,
      type: :string

    belongs_to :canonical_thread, Thread,
      foreign_key: :canonical_thread_id,
      references: :id,
      type: :string

    field :owner_scope, :string, default: "local"
    field :channel, :string
    field :receiver_account_ref, :string
    field :provider_message_id, :string
    field :part_id, :string, default: "0"
    field :direction, :string

    timestamps(type: :utc_datetime_usec)
  end

  @type t :: %__MODULE__{}

  @doc false
  def changeset(ref, attrs) do
    ref
    |> cast(attrs, [
      :canonical_message_id,
      :canonical_thread_id,
      :owner_scope,
      :channel,
      :receiver_account_ref,
      :provider_message_id,
      :part_id,
      :direction
    ])
    |> validate_required([
      :canonical_message_id,
      :canonical_thread_id,
      :owner_scope,
      :channel,
      :receiver_account_ref,
      :provider_message_id,
      :part_id,
      :direction
    ])
    |> validate_inclusion(:direction, @directions)
    |> validate_length(:canonical_message_id, min: 5, max: 160)
    |> validate_length(:canonical_thread_id, min: 5, max: 160)
    |> validate_length(:owner_scope, min: 1, max: 64)
    |> validate_length(:channel, min: 1, max: 64)
    |> validate_length(:receiver_account_ref, min: 1, max: 160)
    |> validate_length(:provider_message_id, min: 1, max: 160)
    |> validate_length(:part_id, min: 1, max: 64)
    |> foreign_key_constraint(:canonical_message_id)
    |> foreign_key_constraint(:canonical_thread_id)
    |> unique_constraint(
      [:owner_scope, :channel, :receiver_account_ref, :provider_message_id, :part_id],
      name: :conversation_message_refs_provider_message_uidx
    )
  end
end
