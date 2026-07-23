defmodule AllbertAssist.Execution.CancellationProofTest do
  use ExUnit.Case, async: false
  @moduletag :external_runtime_serial

  alias AllbertAssist.Execution.CancellationProof

  test "cancel kills the addressed ordinary tree and preserves its sibling" do
    assert {:ok, proof} = CancellationProof.run("cancel")
    assert proof.status == :passed
    assert proof.mode == "cancel"
    assert proof.containment == :process_group
    assert proof.target_tree_dead?
    assert proof.sibling_survived?
    assert proof.cleanup_complete?
  end

  test "timeout kills the complete ordinary tree" do
    assert {:ok, proof} = CancellationProof.run("timeout")
    assert proof.status == :passed
    assert proof.mode == "timeout"
    assert proof.timed_out?
    assert proof.target_tree_dead?
    assert proof.cleanup_complete?
  end

  test "session escape reports the process-group boundary and cleans the escapee" do
    assert {:ok, proof} = CancellationProof.run("session-escape")
    assert proof.mode == "session-escape"
    assert proof.containment == :process_group
    assert proof.boundary in [:escape_observed, :setsid_unavailable]
    assert proof.cleanup_complete?
  end

  test "rejects every mode outside the closed proof vocabulary" do
    assert {:error, {:unsupported_mode, "custom"}} = CancellationProof.run("custom")
  end
end
