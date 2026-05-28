defmodule AllbertAssist.Objectives.Step do
  @moduledoc "Durable objective step."

  use Ecto.Schema

  import Ecto.Changeset

  alias AllbertAssist.Objectives.{Objective, Stage}

  @kinds ~w[action ask_user wait observe reflect delegate_agent]
  @statuses ~w[proposed selected running blocked completed skipped cancelled failed]

  @primary_key {:id, :string, autogenerate: false}
  @foreign_key_type :string

  schema "objective_steps" do
    belongs_to :objective, Objective

    field :parent_step_id, :string
    field :kind, :string
    field :status, :string, default: "proposed"
    field :stage, :string
    field :provider, :string
    field :candidate_action, :string
    field :delegate_agent_id, :string
    field :action_params, :string
    field :result_summary, :string
    field :observation_summary, :string
    field :trace_id, :string
    field :confirmation_id, :string
    field :resource_access, :string

    timestamps(type: :utc_datetime_usec)
  end

  @type t :: %__MODULE__{}

  @doc false
  def changeset(step, attrs) do
    step
    |> cast(attrs, [
      :id,
      :objective_id,
      :parent_step_id,
      :kind,
      :status,
      :stage,
      :provider,
      :candidate_action,
      :delegate_agent_id,
      :action_params,
      :result_summary,
      :observation_summary,
      :trace_id,
      :confirmation_id,
      :resource_access
    ])
    |> validate_required([:id, :objective_id, :kind, :status, :stage])
    |> validate_inclusion(:kind, @kinds)
    |> validate_inclusion(:status, @statuses)
    |> validate_inclusion(:stage, Stage.names())
    |> validate_length(:id, min: 5, max: 80)
    |> validate_length(:objective_id, min: 5, max: 80)
    |> validate_length(:parent_step_id, max: 80)
    |> validate_length(:provider, max: 120)
    |> validate_length(:candidate_action, max: 240)
    |> validate_length(:delegate_agent_id, max: 128)
    |> validate_length(:action_params, max: 2_000)
    |> validate_length(:result_summary, max: 2_000)
    |> validate_length(:observation_summary, max: 2_000)
    |> validate_length(:trace_id, max: 128)
    |> validate_length(:confirmation_id, max: 128)
    |> validate_length(:resource_access, max: 4_000)
    |> foreign_key_constraint(:objective_id)
  end

  def kinds, do: @kinds
  def statuses, do: @statuses
end
