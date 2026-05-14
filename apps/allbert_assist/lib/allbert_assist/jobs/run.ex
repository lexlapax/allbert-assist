defmodule AllbertAssist.Jobs.Run do
  @moduledoc """
  One scheduled job execution attempt.
  """

  use Ecto.Schema

  import Ecto.Changeset

  alias AllbertAssist.Jobs.Job

  @statuses ~w[queued running completed needs_confirmation failed skipped]
  @triggers ~w[manual scheduler]

  @primary_key {:id, :string, autogenerate: false}
  @foreign_key_type :string

  schema "scheduled_job_runs" do
    belongs_to :job, Job, type: :string

    field :status, :string
    field :trigger, :string
    field :due_at, :utc_datetime_usec
    field :started_at, :utc_datetime_usec
    field :finished_at, :utc_datetime_usec
    field :duration_ms, :integer
    field :user_id, :string
    field :operator_id, :string
    field :thread_id, :string
    field :session_id, :string
    field :app_id, :string
    field :input_signal_id, :string
    field :response_signal_id, :string
    field :trace_id, :string
    field :confirmation_id, :string
    field :decision, :map, default: %{}
    field :resource_access, :map, default: %{}
    field :approval_handoff, :map, default: %{}
    field :action_log, :map, default: %{}
    field :error, :map, default: %{}
    field :metadata, :map, default: %{}

    timestamps(type: :utc_datetime_usec)
  end

  @type t :: %__MODULE__{}

  @doc false
  def changeset(run, attrs) do
    run
    |> cast(attrs, [
      :id,
      :job_id,
      :status,
      :trigger,
      :due_at,
      :started_at,
      :finished_at,
      :duration_ms,
      :user_id,
      :operator_id,
      :thread_id,
      :session_id,
      :app_id,
      :input_signal_id,
      :response_signal_id,
      :trace_id,
      :confirmation_id,
      :decision,
      :resource_access,
      :approval_handoff,
      :action_log,
      :error,
      :metadata
    ])
    |> validate_required([:id, :job_id, :status, :trigger, :user_id, :operator_id])
    |> validate_inclusion(:status, @statuses)
    |> validate_inclusion(:trigger, @triggers)
    |> validate_number(:duration_ms, greater_than_or_equal_to: 0)
    |> validate_length(:id, min: 5)
    |> validate_length(:user_id, min: 1, max: 128)
    |> validate_length(:operator_id, min: 1, max: 128)
    |> foreign_key_constraint(:job_id)
  end

  def statuses, do: @statuses
  def triggers, do: @triggers
end
