defmodule AllbertAssist.Memory.Proposals.Suppression do
  @moduledoc false

  use Ecto.Schema

  import Ecto.Changeset

  @reasons ~w[operator_rejected forgotten]
  @primary_key {:id, :string, autogenerate: false}

  schema "memory_proposal_suppressions" do
    field :operator_id, :string
    field :namespace, :string, default: "default"
    field :proposal_digest, :string
    field :source_digest, :string
    field :normalizer_version, :integer
    field :reason, :string

    timestamps(type: :utc_datetime_usec, updated_at: false)
  end

  def changeset(suppression, attrs) do
    suppression
    |> cast(attrs, [
      :id,
      :operator_id,
      :namespace,
      :proposal_digest,
      :source_digest,
      :normalizer_version,
      :reason
    ])
    |> validate_required([
      :id,
      :operator_id,
      :namespace,
      :proposal_digest,
      :source_digest,
      :normalizer_version,
      :reason
    ])
    |> validate_inclusion(:reason, @reasons)
    |> validate_number(:normalizer_version, greater_than: 0)
    |> unique_constraint(
      [:operator_id, :namespace, :proposal_digest, :source_digest, :normalizer_version],
      name: :memory_proposal_suppressions_exact_uidx
    )
    |> check_constraint(:reason, name: :memory_proposal_suppressions_reason_check)
  end
end
