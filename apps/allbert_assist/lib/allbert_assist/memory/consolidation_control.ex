defmodule AllbertAssist.Memory.ConsolidationControl do
  @moduledoc false

  use Ecto.Schema

  import Ecto.Changeset

  @primary_key {:id, :string, autogenerate: false}

  schema "memory_consolidation_controls" do
    field :operator_id, :string
    field :origin_scope, :string
    field :e2ee, :boolean, default: false
    field :cursor_inserted_at, :utc_datetime_usec
    field :cursor_source_id, :string
    field :run_sequence, :integer, default: 0
    field :last_run, :map, default: %{}

    timestamps(type: :utc_datetime_usec)
  end

  def changeset(control, attrs) do
    control
    |> cast(attrs, [
      :id,
      :operator_id,
      :origin_scope,
      :e2ee,
      :cursor_inserted_at,
      :cursor_source_id,
      :run_sequence,
      :last_run
    ])
    |> validate_required([
      :id,
      :operator_id,
      :origin_scope,
      :e2ee,
      :run_sequence,
      :last_run
    ])
    |> validate_inclusion(:origin_scope, ["local_operator", "mapped_operator_dm"])
    |> validate_number(:run_sequence, greater_than_or_equal_to: 0)
    |> unique_constraint([:operator_id, :origin_scope, :e2ee],
      name: :memory_consolidation_controls_scope_uidx
    )
  end
end
