defmodule AllbertAssist.Objectives.Event do
  @moduledoc "Durable objective lifecycle event."

  use Ecto.Schema

  import Ecto.Changeset

  alias AllbertAssist.Objectives.{Objective, Step}

  @kinds ~w[
    created
    updated
    step_proposed
    step_selected
    step_completed
    step_failed
    observed
    blocked
    completed
    cancelled
    impasse
  ]

  @primary_key {:id, :string, autogenerate: false}
  @foreign_key_type :string

  schema "objective_events" do
    belongs_to :objective, Objective
    belongs_to :step, Step

    field :kind, :string
    field :summary, :string
    field :payload, :string
    field :recorded_at, :utc_datetime_usec
  end

  @type t :: %__MODULE__{}

  @doc false
  def changeset(event, attrs) do
    event
    |> cast(attrs, [:id, :objective_id, :step_id, :kind, :summary, :payload, :recorded_at])
    |> validate_required([:id, :objective_id, :kind, :recorded_at])
    |> validate_inclusion(:kind, @kinds)
    |> validate_length(:id, min: 5, max: 80)
    |> validate_length(:objective_id, min: 5, max: 80)
    |> validate_length(:step_id, max: 80)
    |> validate_length(:summary, max: 1_000)
    |> validate_length(:payload, max: 2_000)
    |> foreign_key_constraint(:objective_id)
    |> foreign_key_constraint(:step_id)
  end

  def kinds, do: @kinds
end
