defmodule AllbertAssist.Memory.Proposals.Proposal do
  @moduledoc false

  use Ecto.Schema

  import Ecto.Changeset

  @categories ~w[notes preferences traces skills identity]
  @kinds ~w[ordinary protected_stub]
  @statuses ~w[pending applying kept rejected stale forgotten error]
  @classifications ~w[ordinary protected_third_party protected_minor protected_dependent]

  @primary_key {:id, :string, autogenerate: false}

  schema "memory_proposals" do
    field :operator_id, :string
    field :namespace, :string, default: "default"
    field :category, :string
    field :kind, :string
    field :status, :string, default: "pending"
    field :classification, :string
    field :proposed_claim, :map
    field :span_provenance, :map
    field :source_evidence, :map
    field :proposal_digest, :string
    field :source_digest, :string
    field :principal_digest, :string
    field :origin_scope, :string
    field :extractor_profile, :string
    field :extractor_version, :integer
    field :run_id, :string
    field :revision, :integer, default: 1
    field :idempotency_key, :string
    field :applying_transition_id, :string
    field :applying_decision_digest, :string
    field :applying_payload, :map
    field :result, :map, default: %{}
    field :reviewed_by, :string
    field :reviewed_at, :utc_datetime_usec

    timestamps(type: :utc_datetime_usec)
  end

  @type t :: %__MODULE__{}

  def changeset(proposal, attrs) do
    proposal
    |> cast(attrs, [
      :id,
      :operator_id,
      :namespace,
      :category,
      :kind,
      :status,
      :classification,
      :proposed_claim,
      :span_provenance,
      :source_evidence,
      :proposal_digest,
      :source_digest,
      :principal_digest,
      :origin_scope,
      :extractor_profile,
      :extractor_version,
      :run_id,
      :revision,
      :idempotency_key,
      :applying_transition_id,
      :applying_decision_digest,
      :applying_payload,
      :result,
      :reviewed_by,
      :reviewed_at
    ])
    |> validate_required([
      :id,
      :operator_id,
      :namespace,
      :category,
      :kind,
      :status,
      :classification,
      :source_evidence,
      :proposal_digest,
      :source_digest,
      :principal_digest,
      :origin_scope,
      :extractor_profile,
      :extractor_version,
      :run_id,
      :revision,
      :idempotency_key,
      :result
    ])
    |> validate_inclusion(:category, @categories)
    |> validate_inclusion(:kind, @kinds)
    |> validate_inclusion(:status, @statuses)
    |> validate_inclusion(:classification, @classifications)
    |> validate_number(:extractor_version, greater_than: 0)
    |> validate_number(:revision, greater_than: 0)
    |> validate_length(:operator_id, min: 1, max: 128)
    |> validate_length(:namespace, min: 1, max: 128)
    |> validate_length(:extractor_profile, min: 1, max: 128)
    |> validate_length(:run_id, min: 1, max: 128)
    |> validate_kind_content()
    |> check_constraint(:kind, name: :memory_proposals_kind_check)
    |> check_constraint(:status, name: :memory_proposals_status_check)
    |> check_constraint(:kind, name: :memory_proposals_protected_stub_content_check)
    |> check_constraint(:kind, name: :memory_proposals_ordinary_content_check)
    |> unique_constraint([:operator_id, :namespace, :idempotency_key],
      name: :memory_proposals_idempotency_uidx
    )
  end

  def kinds, do: @kinds
  def statuses, do: @statuses
  def classifications, do: @classifications

  defp validate_kind_content(changeset) do
    case get_field(changeset, :kind) do
      "ordinary" ->
        validate_required(changeset, [:proposed_claim, :span_provenance])

      "protected_stub" ->
        changeset
        |> reject_present(:proposed_claim)
        |> reject_present(:span_provenance)
        |> reject_present(:applying_payload)

      _other ->
        changeset
    end
  end

  defp reject_present(changeset, field) do
    if is_nil(get_field(changeset, field)),
      do: changeset,
      else: add_error(changeset, field, "must be absent from a protected stub")
  end
end
