defmodule AllbertAssist.Conversations.Message do
  @moduledoc """
  One persisted conversation turn message.

  Message rows are SQLite conversation history, not markdown long-term memory.
  """

  use Ecto.Schema

  import Ecto.Changeset

  alias AllbertAssist.Conversations.Thread

  @roles ~w[user assistant]

  @primary_key {:id, :string, autogenerate: false}
  @foreign_key_type :string

  schema "conversation_messages" do
    belongs_to :thread, Thread, type: :string

    field :user_id, :string
    field :role, :string
    field :content, :string
    field :action_log, :map, default: %{}
    field :trace_id, :string
    field :input_signal_id, :string
    field :response_signal_id, :string
    field :metadata, :map, default: %{}

    timestamps(type: :utc_datetime_usec, updated_at: false)
  end

  @doc false
  def changeset(message, attrs) do
    message
    |> cast(attrs, [
      :id,
      :thread_id,
      :user_id,
      :role,
      :content,
      :action_log,
      :trace_id,
      :input_signal_id,
      :response_signal_id,
      :metadata
    ])
    |> validate_required([:id, :thread_id, :user_id, :role, :content])
    |> validate_inclusion(:role, @roles)
    |> validate_length(:id, min: 5)
    |> validate_length(:user_id, min: 1, max: 128)
    |> validate_length(:content, min: 1)
    |> foreign_key_constraint(:thread_id)
  end
end
