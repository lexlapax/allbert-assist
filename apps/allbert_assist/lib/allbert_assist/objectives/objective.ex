defmodule AllbertAssist.Objectives.Objective do
  @moduledoc "Durable cross-turn objective."

  use Ecto.Schema

  import Ecto.Changeset

  alias AllbertAssist.Objectives.AcceptanceCriteria
  alias AllbertAssist.Objectives.Step

  @statuses ~w[open running blocked completed cancelled failed abandoned]
  @fanout_roles ~w[parent child]
  @join_policies ~w[all_terminal]
  @join_outcomes ~w[success partial failed cancelled]
  @kickoff_delivery_states ~w[pending blocked acknowledged cancelled]
  @report_delivery_states ~w[not_ready pending delivered]

  @primary_key {:id, :string, autogenerate: false}
  @foreign_key_type :string

  schema "objectives" do
    has_many :steps, Step, foreign_key: :objective_id

    field :user_id, :string
    field :source_thread_id, :string
    field :source_channel, :string
    field :source_surface, :string
    field :session_id, :string
    field :active_app, :string
    field :status, :string, default: "open"
    field :title, :string
    field :objective, :string
    field :acceptance_criteria, :string
    field :constraints, :string
    field :source_intent, :string
    field :parent_objective_id, :string
    field :fanout_role, :string
    field :join_policy, :string
    field :join_outcome, :string
    field :kickoff_delivery_state, :string
    field :fanout_start_receipt_digest, :string
    field :report_delivery_state, :string
    field :report_delivery_receipt_digest, :string
    field :origin_thread_ref_id, :string
    field :origin_thread_ref_digest, :string
    field :origin_receiver_account_ref, :string
    field :queue_position, :integer
    field :run_attempt_count, :integer, default: 0
    field :review_reason, :string
    field :current_step_id, :string
    field :progress_summary, :string
    field :last_observation_summary, :string
    field :proposer_hint, :string
    field :loop_count, :integer, default: 0
    field :completed_at, :utc_datetime_usec

    timestamps(type: :utc_datetime_usec)
  end

  @type t :: %__MODULE__{}

  @doc false
  def changeset(objective, attrs) do
    objective
    |> cast(attrs, [
      :id,
      :user_id,
      :source_thread_id,
      :source_channel,
      :source_surface,
      :session_id,
      :active_app,
      :status,
      :title,
      :objective,
      :acceptance_criteria,
      :constraints,
      :source_intent,
      :parent_objective_id,
      :fanout_role,
      :join_policy,
      :join_outcome,
      :kickoff_delivery_state,
      :fanout_start_receipt_digest,
      :report_delivery_state,
      :report_delivery_receipt_digest,
      :origin_thread_ref_id,
      :origin_thread_ref_digest,
      :origin_receiver_account_ref,
      :queue_position,
      :run_attempt_count,
      :review_reason,
      :current_step_id,
      :progress_summary,
      :last_observation_summary,
      :proposer_hint,
      :loop_count,
      :completed_at
    ])
    |> validate_required([:id, :user_id, :status, :title, :objective])
    |> validate_inclusion(:status, @statuses)
    |> validate_number(:loop_count, greater_than_or_equal_to: 0)
    |> validate_number(:queue_position, greater_than_or_equal_to: 0)
    |> validate_number(:run_attempt_count, greater_than_or_equal_to: 0)
    |> validate_optional_inclusion(:fanout_role, @fanout_roles)
    |> validate_optional_inclusion(:join_policy, @join_policies)
    |> validate_optional_inclusion(:join_outcome, @join_outcomes)
    |> validate_optional_inclusion(:kickoff_delivery_state, @kickoff_delivery_states)
    |> validate_optional_inclusion(:report_delivery_state, @report_delivery_states)
    |> validate_length(:id, min: 5, max: 80)
    |> validate_length(:user_id, min: 1, max: 128)
    |> validate_length(:source_thread_id, max: 128)
    |> validate_length(:source_channel, max: 64)
    |> validate_length(:source_surface, max: 200)
    |> validate_length(:session_id, max: 128)
    |> validate_length(:active_app, max: 64)
    |> validate_length(:title, min: 1, max: 200)
    |> validate_length(:objective, min: 1, max: 2_000)
    |> validate_length(:acceptance_criteria, max: 2_000)
    |> validate_length(:constraints, max: 2_000)
    |> validate_length(:source_intent, max: 500)
    |> validate_length(:progress_summary, max: 2_000)
    |> validate_length(:last_observation_summary, max: 2_000)
    |> validate_length(:proposer_hint, max: 4_000)
    |> validate_length(:fanout_start_receipt_digest, max: 128)
    |> validate_length(:report_delivery_receipt_digest, max: 128)
    |> validate_length(:origin_thread_ref_id, max: 128)
    |> validate_length(:origin_thread_ref_digest, max: 128)
    |> validate_length(:origin_receiver_account_ref, max: 128)
    |> validate_length(:review_reason, max: 240)
    |> unique_constraint(:fanout_start_receipt_digest)
    |> unique_constraint(:report_delivery_receipt_digest)
    |> validate_acceptance_criteria()
  end

  def statuses, do: @statuses

  defp validate_optional_inclusion(changeset, field, values) do
    case get_field(changeset, field) do
      nil -> changeset
      _value -> validate_inclusion(changeset, field, values)
    end
  end

  defp validate_acceptance_criteria(changeset) do
    validate_change(changeset, :acceptance_criteria, fn :acceptance_criteria, value ->
      case AcceptanceCriteria.validate_text(value) do
        :ok ->
          []

        {:error, reason} ->
          [acceptance_criteria: "invalid acceptance criteria: #{inspect(reason)}"]
      end
    end)
  end
end
