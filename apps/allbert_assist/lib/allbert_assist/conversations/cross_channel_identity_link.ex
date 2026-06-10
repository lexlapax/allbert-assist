defmodule AllbertAssist.Conversations.CrossChannelIdentityLink do
  @moduledoc """
  Operator-declared grouping of already-authenticated channel identities.

  These links support unified history and explicit resume flows. They do not
  authenticate users and are never auto-derived from provider display data.
  """

  use Ecto.Schema

  import Ecto.Changeset

  schema "cross_channel_identity_links" do
    field :owner_scope, :string, default: "local"
    field :link_id, :string
    field :user_id, :string
    field :channel, :string
    field :receiver_account_ref, :string
    field :external_user_id, :string

    timestamps(type: :utc_datetime_usec)
  end

  @type t :: %__MODULE__{}

  @doc false
  def changeset(link, attrs) do
    link
    |> cast(attrs, [
      :owner_scope,
      :link_id,
      :user_id,
      :channel,
      :receiver_account_ref,
      :external_user_id
    ])
    |> validate_required([
      :owner_scope,
      :link_id,
      :user_id,
      :channel,
      :receiver_account_ref,
      :external_user_id
    ])
    |> validate_length(:owner_scope, min: 1, max: 64)
    |> validate_length(:link_id, min: 1, max: 160)
    |> validate_length(:user_id, min: 1, max: 128)
    |> validate_length(:channel, min: 1, max: 64)
    |> validate_length(:receiver_account_ref, min: 1, max: 160)
    |> validate_length(:external_user_id, min: 1, max: 160)
    |> unique_constraint(
      [:owner_scope, :link_id, :channel, :receiver_account_ref, :external_user_id],
      name: :cross_channel_identity_links_owner_link_uidx
    )
  end
end
