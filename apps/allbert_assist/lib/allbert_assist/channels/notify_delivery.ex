defmodule AllbertAssist.Channels.NotifyDelivery do
  @moduledoc "Durable idempotency and outcome row for autonomous channel notification."

  use Ecto.Schema

  import Ecto.Changeset

  @states ~w[reserved sending delivered failed uncertain suppressed]
  @kinds ~w[status completion confirmation_request consent_offer]
  @offer_states ~w[not_applicable pending delivered accepted]

  schema "channel_notify_deliveries" do
    field :delivery_key, :string
    field :fanout_id, :string
    field :child_objective_id, :string
    field :local_user_id, :string
    field :channel, :string
    field :origin_thread_ref_id, :string
    field :origin_thread_ref_digest, :string
    field :kind, :string
    field :state, :string, default: "reserved"
    field :provider_message_id, :string
    field :throttle_at, :utc_datetime_usec
    field :attempt_count, :integer, default: 0
    field :error_class, :string
    field :offer_state, :string, default: "not_applicable"

    timestamps(type: :utc_datetime_usec)
  end

  @type t :: %__MODULE__{}

  def changeset(delivery, attrs) do
    delivery
    |> cast(attrs, [
      :delivery_key,
      :fanout_id,
      :child_objective_id,
      :local_user_id,
      :channel,
      :origin_thread_ref_id,
      :origin_thread_ref_digest,
      :kind,
      :state,
      :provider_message_id,
      :throttle_at,
      :attempt_count,
      :error_class,
      :offer_state
    ])
    |> validate_required([
      :delivery_key,
      :fanout_id,
      :local_user_id,
      :channel,
      :origin_thread_ref_id,
      :origin_thread_ref_digest,
      :kind,
      :state,
      :offer_state
    ])
    |> validate_inclusion(:state, @states)
    |> validate_inclusion(:kind, @kinds)
    |> validate_inclusion(:offer_state, @offer_states)
    |> validate_number(:attempt_count, greater_than_or_equal_to: 0, less_than_or_equal_to: 2)
    |> validate_length(:delivery_key, max: 160)
    |> validate_length(:fanout_id, max: 80)
    |> validate_length(:child_objective_id, max: 80)
    |> validate_length(:local_user_id, max: 128)
    |> validate_length(:channel, max: 64)
    |> validate_length(:origin_thread_ref_id, max: 128)
    |> validate_length(:origin_thread_ref_digest, max: 128)
    |> validate_length(:provider_message_id, max: 256)
    |> validate_length(:error_class, max: 128)
    |> unique_constraint(:delivery_key)
  end
end
