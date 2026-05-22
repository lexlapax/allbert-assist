defmodule StockSage.ReflectionsTest do
  use StockSage.DataCase

  alias AllbertAssist.Memory, as: AllbertMemory
  alias StockSage.{Analyses, Memory, Reflections}

  setup do
    original_memory_config = Application.get_env(:allbert_assist, AllbertMemory)

    root =
      Path.join(
        System.tmp_dir!(),
        "stocksage-reflections-memory-#{System.unique_integer([:positive])}"
      )

    Application.put_env(:allbert_assist, AllbertMemory, root: root)

    on_exit(fn ->
      restore_env(AllbertMemory, original_memory_config)
      File.rm_rf!(root)
    end)

    :ok
  end

  test "generate creates an idempotent StockSage-local reflection only" do
    %{outcome: outcome} = resolved_outcome_fixture()

    assert {:ok, reflection} = Reflections.generate("alice", outcome.id)

    assert reflection.outcome_id == outcome.id
    assert reflection.symbol == "AAPL"
    assert reflection.promoted_to_allbert_memory == false
    assert reflection.content =~ "Observed outcome"
    assert reflection.content =~ "not durable Allbert markdown memory"

    assert [entry] = Memory.list_entries("alice", kind: "reflection")
    assert entry.id == reflection.entry_id
    assert entry.legacy_source == "stocksage_reflection"
    assert entry.legacy_id == outcome.id

    assert {:ok, []} = AllbertMemory.list_entries(limit: 10)

    assert {:ok, second} = Reflections.generate("alice", outcome.id)
    assert second.entry_id == reflection.entry_id
    assert [_one] = Memory.list_entries("alice", kind: "reflection")
  end

  test "generate rejects unresolved outcomes" do
    assert {:ok, analysis} =
             Analyses.create_analysis(%{
               user_id: "alice",
               symbol: "msft",
               status: "completed",
               source: "manual",
               recommendation: "Sell"
             })

    assert {:ok, pending} =
             Analyses.create_outcome(%{
               user_id: "alice",
               analysis_id: analysis.id,
               symbol: "msft",
               label: "pending"
             })

    assert {:error, :unresolved_outcome} = Reflections.generate("alice", pending.id)
    assert [] = Memory.list_entries("alice", kind: "reflection")
  end

  defp resolved_outcome_fixture do
    assert {:ok, analysis} =
             Analyses.create_analysis(%{
               user_id: "alice",
               symbol: "aapl",
               status: "completed",
               source: "manual",
               engine: "native",
               recommendation: "Buy",
               objective_id: "obj_reflection_1",
               step_id: "step_reflection_1"
             })

    assert {:ok, outcome} =
             Analyses.create_outcome(%{
               user_id: "alice",
               analysis_id: analysis.id,
               symbol: "aapl",
               label: "win",
               horizon_days: 30,
               observed_on: ~D[2026-05-01],
               return_pct: Decimal.new("12.0")
             })

    %{analysis: analysis, outcome: outcome}
  end

  defp restore_env(module, nil), do: Application.delete_env(:allbert_assist, module)
  defp restore_env(module, config), do: Application.put_env(:allbert_assist, module, config)
end
