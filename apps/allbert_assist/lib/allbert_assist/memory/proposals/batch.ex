defmodule AllbertAssist.Memory.Proposals.Batch do
  @moduledoc false

  use Ecto.Schema

  import Ecto.Changeset

  @statuses ~w[pending applying complete forgotten error]
  @primary_key {:id, :string, autogenerate: false}

  schema "memory_proposal_batches" do
    field :operator_id, :string
    field :namespace, :string, default: "default"
    field :status, :string, default: "pending"
    field :bindings, :map
    field :results, :map, default: %{}
    field :requested_by, :string
    field :completed_at, :utc_datetime_usec

    timestamps(type: :utc_datetime_usec)
  end

  def changeset(batch, attrs) do
    batch
    |> cast(attrs, [
      :id,
      :operator_id,
      :namespace,
      :status,
      :bindings,
      :results,
      :requested_by,
      :completed_at
    ])
    |> validate_required([
      :id,
      :operator_id,
      :namespace,
      :status,
      :bindings,
      :results,
      :requested_by
    ])
    |> validate_inclusion(:status, @statuses)
    |> validate_length(:operator_id, min: 1, max: 128)
    |> validate_length(:namespace, min: 1, max: 128)
    |> validate_length(:requested_by, min: 1, max: 128)
    |> check_constraint(:status, name: :memory_proposal_batches_status_check)
  end
end
