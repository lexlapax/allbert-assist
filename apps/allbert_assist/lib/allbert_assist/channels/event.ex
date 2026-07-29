defmodule AllbertAssist.Channels.Event do
  @moduledoc """
  Durable provider event record for channel adapters.

  Channel events are transport metadata and dedupe state. Conversation text
  remains in `AllbertAssist.Conversations` after runtime acceptance.
  """

  use Ecto.Schema

  import Ecto.Changeset

  @directions ~w[inbound outbound callback]
  @statuses ~w[received processed rejected failed]
  @receipt_states ~w[received admitted in_progress completed rejected failed outcome_unknown]
  @receipt_outcomes ~w[completed rejected failed outcome_unknown]
  @receipt_normalizer_versions ["tui-input-v1"]
  @receipt_hmac_key_refs ["secret://system/integrity_v1"]

  schema "channel_events" do
    field :channel, :string
    field :provider, :string
    field :direction, :string
    field :external_event_id, :string
    field :external_user_id, :string
    field :external_chat_id, :string
    field :external_message_id, :string
    field :user_id, :string
    field :session_id, :string
    field :thread_id, :string
    field :input_signal_id, :string
    field :trace_id, :string
    field :status, :string
    field :reason, :string
    field :payload_summary, :string
    field :error, :string
    field :receipt_normalizer_version, :string
    field :receipt_hmac_key_ref, :string
    field :receipt_hmac_key_version, :integer
    field :receipt_payload_hmac, :string
    field :receipt_state, :string
    field :receipt_message_id, :string
    field :receipt_result_ref, :string
    field :receipt_outcome, :string

    timestamps(type: :utc_datetime_usec)
  end

  @type t :: %__MODULE__{}

  @doc false
  def changeset(event, attrs) do
    event
    |> cast(attrs, [
      :channel,
      :provider,
      :direction,
      :external_event_id,
      :external_user_id,
      :external_chat_id,
      :external_message_id,
      :user_id,
      :session_id,
      :thread_id,
      :input_signal_id,
      :trace_id,
      :status,
      :reason,
      :payload_summary,
      :error,
      :receipt_normalizer_version,
      :receipt_hmac_key_ref,
      :receipt_hmac_key_version,
      :receipt_payload_hmac,
      :receipt_state,
      :receipt_message_id,
      :receipt_result_ref,
      :receipt_outcome
    ])
    |> validate_required([:channel, :provider, :direction, :external_event_id, :status])
    |> validate_inclusion(:direction, @directions)
    |> validate_inclusion(:status, @statuses)
    |> validate_length(:channel, min: 1, max: 64)
    |> validate_length(:provider, min: 1, max: 128)
    |> validate_length(:direction, min: 1, max: 32)
    |> validate_length(:external_event_id, min: 1, max: 255)
    |> validate_length(:external_user_id, max: 255)
    |> validate_length(:external_chat_id, max: 255)
    |> validate_length(:external_message_id, max: 255)
    |> validate_length(:user_id, max: 128)
    |> validate_length(:session_id, max: 128)
    |> validate_length(:thread_id, max: 128)
    |> validate_length(:input_signal_id, max: 128)
    |> validate_length(:trace_id, max: 500)
    |> validate_length(:reason, max: 500)
    |> validate_length(:payload_summary, max: 500)
    |> validate_length(:error, max: 500)
    |> validate_inclusion(:receipt_normalizer_version, @receipt_normalizer_versions)
    |> validate_inclusion(:receipt_hmac_key_ref, @receipt_hmac_key_refs)
    |> validate_inclusion(:receipt_hmac_key_version, [1])
    |> validate_format(:receipt_payload_hmac, ~r/\A[A-Za-z0-9_-]{43}\z/)
    |> validate_inclusion(:receipt_state, @receipt_states)
    |> validate_length(:receipt_message_id, max: 128)
    |> validate_length(:receipt_result_ref, max: 256)
    |> validate_inclusion(:receipt_outcome, @receipt_outcomes)
    |> unique_constraint(:external_event_id,
      name: :channel_events_inbound_callback_dedup
    )
    |> unique_constraint(:external_event_id,
      name: :channel_events_channel_external_event_id_index
    )
  end

  def directions, do: @directions
  def statuses, do: @statuses
end
