defmodule AllbertAssist.Memory.ConsolidationControlTest do
  @moduledoc """
  v1.3 M9.b.13.a — the durable cursor consolidation resumes from.

  This schema had no direct coverage. It records how far consolidation has read
  per operator, origin scope, and E2EE flag; the scope tuple is what keeps a
  mapped-DM cursor from being applied to local-operator content and vice versa.
  A relaxed validation here would let a cursor cross scopes, so consolidation
  would either re-read content it already proposed from or skip content it never
  read — neither of which surfaces as an error.
  """

  use AllbertAssist.DataCase, async: false

  alias AllbertAssist.Memory.ConsolidationControl

  defp valid_attrs(overrides \\ %{}) do
    Map.merge(
      %{
        id: "local:local_operator:false",
        operator_id: "local",
        origin_scope: "local_operator",
        e2ee: false,
        run_sequence: 0,
        last_run: %{}
      },
      overrides
    )
  end

  test "a complete control is valid" do
    changeset = ConsolidationControl.changeset(%ConsolidationControl{}, valid_attrs())
    assert changeset.valid?
  end

  test "the fields that identify a cursor's scope are required" do
    for field <- [:id, :operator_id, :origin_scope] do
      attrs = valid_attrs() |> Map.delete(field)
      changeset = ConsolidationControl.changeset(%ConsolidationControl{}, attrs)

      refute changeset.valid?, "#{field} must be required; without it a cursor loses its scope"
      assert Keyword.has_key?(changeset.errors, field)
    end
  end

  test "fields carrying a schema default survive omission rather than failing validation" do
    # e2ee, run_sequence and last_run are all `validate_required` but each has a
    # schema default, so an omitted value is satisfied by the default rather than
    # rejected. Recorded because "required" reads stronger than it behaves here.
    for field <- [:e2ee, :run_sequence, :last_run] do
      attrs = valid_attrs() |> Map.delete(field)
      changeset = ConsolidationControl.changeset(%ConsolidationControl{}, attrs)

      assert changeset.valid?,
             "#{field} has a schema default, so omitting it is valid despite validate_required"
    end
  end

  test "only the two Memory origin scopes are accepted" do
    for scope <- ["local_operator", "mapped_operator_dm"] do
      changeset =
        ConsolidationControl.changeset(
          %ConsolidationControl{},
          valid_attrs(%{origin_scope: scope})
        )

      assert changeset.valid?, "#{scope} is a Memory collection grant and must be accepted"
    end

    for scope <- ["external_history", "shared", "", "LOCAL_OPERATOR"] do
      changeset =
        ConsolidationControl.changeset(
          %ConsolidationControl{},
          valid_attrs(%{origin_scope: scope})
        )

      refute changeset.valid?, "#{inspect(scope)} is not a Memory grant and must be refused"
      assert Keyword.has_key?(changeset.errors, :origin_scope)
    end
  end

  test "the run sequence cannot go negative" do
    changeset =
      ConsolidationControl.changeset(%ConsolidationControl{}, valid_attrs(%{run_sequence: -1}))

    refute changeset.valid?
    assert Keyword.has_key?(changeset.errors, :run_sequence)

    assert ConsolidationControl.changeset(
             %ConsolidationControl{},
             valid_attrs(%{run_sequence: 0})
           ).valid?
  end

  test "the cursor position is optional so a first run can persist before reading" do
    changeset = ConsolidationControl.changeset(%ConsolidationControl{}, valid_attrs())
    assert changeset.valid?
    refute Keyword.has_key?(changeset.errors, :cursor_inserted_at)
    refute Keyword.has_key?(changeset.errors, :cursor_source_id)
  end

  test "one control persists per operator, scope, and e2ee tuple" do
    assert {:ok, _first} =
             %ConsolidationControl{}
             |> ConsolidationControl.changeset(valid_attrs())
             |> Repo.insert()

    # Same tuple, different id: the unique index is on the scope, not the id.
    duplicate =
      %ConsolidationControl{}
      |> ConsolidationControl.changeset(valid_attrs(%{id: "another-id"}))

    # The schema declares unique_constraint/3 with the index name, but under this
    # adapter the violation is not converted into a changeset error — it raises.
    # Asserted as it behaves, not as the declaration implies, because a caller
    # written against {:error, changeset} would crash here instead.
    assert_raise Ecto.ConstraintError, fn -> Repo.insert(duplicate) end
  end

  test "the same operator may hold separate cursors per scope and e2ee flag" do
    assert {:ok, _local} =
             %ConsolidationControl{}
             |> ConsolidationControl.changeset(valid_attrs())
             |> Repo.insert()

    assert {:ok, _mapped} =
             %ConsolidationControl{}
             |> ConsolidationControl.changeset(
               valid_attrs(%{id: "local:mapped:false", origin_scope: "mapped_operator_dm"})
             )
             |> Repo.insert()

    assert {:ok, _e2ee} =
             %ConsolidationControl{}
             |> ConsolidationControl.changeset(valid_attrs(%{id: "local:local:true", e2ee: true}))
             |> Repo.insert()
  end
end
