defmodule AllbertAssist.Jobs.Job do
  @moduledoc """
  Durable local scheduled job definition.

  Jobs are scoped by string `user_id`. Targets are stored in full for
  execution, while redaction belongs at CLI, trace, log, and run-summary
  boundaries.
  """

  use Ecto.Schema

  import Ecto.Changeset

  alias AllbertAssist.Jobs.Run

  @statuses ~w[paused active blocked]
  @target_types ~w[runtime_prompt registered_action]
  @thread_modes ~w[origin_thread recent_general new_thread_per_run]

  @primary_key {:id, :string, autogenerate: false}
  @foreign_key_type :string

  schema "scheduled_jobs" do
    has_many :runs, Run, foreign_key: :job_id

    field :name, :string
    field :description, :string
    field :target_type, :string
    field :target, :map, default: %{}
    field :schedule, :map, default: %{}
    field :timezone, :string
    field :status, :string
    field :user_id, :string
    field :operator_id, :string
    field :thread_id, :string
    field :thread_mode, :string
    field :session_id, :string
    field :app_id, :string
    field :objective_id, :string
    field :channel, :string, default: "job"
    field :next_due_at, :utc_datetime_usec
    field :last_run_at, :utc_datetime_usec
    field :blocked_confirmation_id, :string
    field :metadata, :map, default: %{}

    timestamps(type: :utc_datetime_usec)
  end

  @type t :: %__MODULE__{}

  @doc false
  def changeset(job, attrs) do
    job
    |> cast(attrs, [
      :id,
      :name,
      :description,
      :target_type,
      :target,
      :schedule,
      :timezone,
      :status,
      :user_id,
      :operator_id,
      :thread_id,
      :thread_mode,
      :session_id,
      :app_id,
      :objective_id,
      :channel,
      :next_due_at,
      :last_run_at,
      :blocked_confirmation_id,
      :metadata
    ])
    |> validate_required([
      :id,
      :name,
      :target_type,
      :target,
      :schedule,
      :timezone,
      :status,
      :user_id,
      :operator_id,
      :thread_mode,
      :channel
    ])
    |> validate_inclusion(:status, @statuses)
    |> validate_inclusion(:target_type, @target_types)
    |> validate_inclusion(:thread_mode, @thread_modes)
    |> validate_length(:id, min: 5)
    |> validate_length(:name, min: 1, max: 120)
    |> validate_length(:description, max: 1_000)
    |> validate_length(:timezone, min: 1, max: 128)
    |> validate_length(:user_id, min: 1, max: 128)
    |> validate_length(:operator_id, min: 1, max: 128)
    |> validate_length(:channel, min: 1, max: 64)
    |> unique_constraint([:user_id, :name], name: :scheduled_jobs_user_id_name_index)
  end

  def statuses, do: @statuses
  def target_types, do: @target_types
  def thread_modes, do: @thread_modes
end
