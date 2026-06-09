defmodule AllbertAssist.PublicProtocol.CallResult do
  @moduledoc """
  Ecto row backing public protocol poll-by-id result readback.

  This is a client-ownership record, not a confirmation record. It stores only
  the public call id, caller scope, redacted result/error metadata, and expiry.
  """

  use Ecto.Schema

  import Ecto.Changeset

  @primary_key {:id, :string, autogenerate: false}
  @foreign_key_type :string

  @statuses ~w[pending approved_with_result denied expired]
  @surfaces ~w[mcp_stdio mcp_http openai_api acp_stdio]

  schema "public_protocol_call_results" do
    field :surface, :string
    field :client_id, :string
    field :action_label, :string
    field :turn_label, :string
    field :confirmation_id, :string
    field :trace_id, :string
    field :status, :string, default: "pending"
    field :result, :map, default: %{}
    field :error, :map, default: %{}
    field :trace_metadata, :map, default: %{}
    field :resolved_at, :utc_datetime_usec
    field :expires_at, :utc_datetime_usec
    field :expired_at, :utc_datetime_usec

    timestamps(type: :utc_datetime_usec)
  end

  @type t :: %__MODULE__{}

  @doc false
  def changeset(call_result, attrs) do
    call_result
    |> cast(attrs, [
      :id,
      :surface,
      :client_id,
      :action_label,
      :turn_label,
      :confirmation_id,
      :trace_id,
      :status,
      :result,
      :error,
      :trace_metadata,
      :resolved_at,
      :expires_at,
      :expired_at
    ])
    |> validate_required([
      :id,
      :surface,
      :client_id,
      :status,
      :result,
      :error,
      :trace_metadata,
      :expires_at
    ])
    |> validate_inclusion(:status, @statuses)
    |> validate_inclusion(:surface, @surfaces)
    |> validate_length(:id, min: 5, max: 100)
    |> validate_length(:client_id, min: 1, max: 128)
    |> validate_length(:action_label, max: 128)
    |> validate_length(:turn_label, max: 128)
    |> validate_length(:confirmation_id, max: 128)
    |> validate_length(:trace_id, max: 128)
  end

  def statuses, do: @statuses
  def surfaces, do: @surfaces
end
