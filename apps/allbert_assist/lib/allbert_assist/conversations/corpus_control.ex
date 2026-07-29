defmodule AllbertAssist.Conversations.CorpusControl do
  @moduledoc false

  use Ecto.Schema

  import Ecto.Changeset

  @primary_key {:consumer, :string, autogenerate: false}

  schema "conversation_corpus_controls" do
    field :eligibility_epoch, :integer, default: 0

    timestamps(type: :utc_datetime_usec)
  end

  def changeset(control, attrs) do
    control
    |> cast(attrs, [:consumer, :eligibility_epoch])
    |> validate_required([:consumer, :eligibility_epoch])
    |> validate_inclusion(:consumer, ["memory", "search"])
    |> validate_number(:eligibility_epoch, greater_than_or_equal_to: 0)
  end
end
