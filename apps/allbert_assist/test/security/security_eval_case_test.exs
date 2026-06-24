defmodule AllbertAssist.SecurityEvalCaseTest do
  use AllbertAssist.SecurityEvalCase, async: true

  alias AllbertAssist.SecurityFixtures.EvalInventory

  test "run_eval supports inert allowed and denied fixtures" do
    allowed =
      run_eval(%{
        id: "harness-allowed",
        eval_result: %{
          decision: :allowed,
          result: %{message: "ok"},
          trace: %{resource_decision: :allowed},
          transport_calls: %{external_network: 0}
        }
      })

    assert_allowed(allowed)
    assert_trace_records(allowed, [:resource_decision])
    assert_fixture_transport_calls(allowed, :external_network, 0)

    denied =
      run_eval(%{
        id: "harness-denied",
        eval_result: %{
          decision: :denied,
          result: %{message: "blocked"},
          trace: %{resource_decision: :denied, side_effect_ran?: false}
        }
      })

    assert_denied(denied, no_side_effect?: true)
  end

  test "run_eval supports fixture runner functions and leak assertions" do
    eval =
      run_eval(%{
        id: "harness-runner",
        run: fn fixture ->
          %{
            decision: :denied,
            result: %{safe_user: "alice"},
            trace: %{fixture_id: fixture.id, resource_decision: :denied}
          }
        end
      })

    assert_denied(eval)
    assert_no_cross_user_leak(eval, "other-user")
    assert_no_secret_in(eval, ["super-secret-token"])
  end

  test "inventory covers every v0.28 surface group with concrete rows" do
    rows = EvalInventory.rows()

    assert length(rows) >= 25

    milestone_ids = Enum.map(rows, &{&1.milestone, &1.id})
    assert Enum.uniq(milestone_ids) == milestone_ids

    row_surfaces = rows |> Enum.map(& &1.surface) |> MapSet.new()

    assert Enum.all?(EvalInventory.required_surfaces(), &MapSet.member?(row_surfaces, &1))

    for row <- rows do
      assert is_binary(row.id)
      assert row.id =~ "-"

      assert row.milestone in [
               :m2,
               :m3,
               :m4,
               :m5,
               :m6,
               :m7,
               :v036,
               :v037,
               :v038,
               :v039,
               :v039b,
               :v040,
               :v042,
               :v043,
               :v044,
               :v045,
               :v046,
               :v047,
               :v047b,
               :v048,
               :v049,
               :v050,
               :v050b,
               :v051,
               :v052,
               :v053,
               :v055,
               :v0551,
               :v056,
               :v057
             ]

      assert row.expected in [:allowed, :needs_confirmation, :denied, :dropped, :error]
      assert is_binary(row.scenario) and byte_size(row.scenario) > 12
      assert is_atom(row.boundary)
      assert is_list(row.assert) and row.assert != []
      assert is_binary(row.test_module) and String.ends_with?(row.test_module, "Test")
    end
  end

  test "inventory can fetch milestone rows and individual ids" do
    assert [%{id: "prompt-injection-001"} | _] = EvalInventory.rows_for_milestone(:m2)
    assert %{surface: :surface_workspace_namespace} = EvalInventory.row!("namespace-claim-001")
  end
end
