defmodule AllbertAssist.CLI.Areas.CancellationProofTest do
  use ExUnit.Case, async: false
  @moduletag :app_env_serial

  alias AllbertAssist.CLI.Areas.CancellationProof

  setup do
    original = Application.get_env(:allbert_assist, :cancellation_proof_action_runner)

    on_exit(fn ->
      if original,
        do: Application.put_env(:allbert_assist, :cancellation_proof_action_runner, original),
        else: Application.delete_env(:allbert_assist, :cancellation_proof_action_runner)
    end)

    :ok
  end

  test "dispatches only a closed proof mode through the registered action" do
    parent = self()

    Application.put_env(:allbert_assist, :cancellation_proof_action_runner, fn name,
                                                                               params,
                                                                               _ctx ->
      send(parent, {:run, name, params})

      {:ok,
       %{
         status: :completed,
         message:
           "OV12 status=PASS mode=#{params.mode} containment=process_group cleanup_complete=true"
       }}
    end)

    assert {output, 0} = CancellationProof.dispatch(["cancel"], %{actor: "operator"})
    assert output =~ "OV12 status=PASS mode=cancel"
    assert_received {:run, "release_cancellation_proof", %{mode: "cancel"}}

    assert {usage, 2} = CancellationProof.dispatch(["custom"], %{actor: "operator"})
    assert usage =~ "cancel|timeout|session-escape"
  end

  test "renders the durable confirmation id and returns a nonzero pending status" do
    Application.put_env(:allbert_assist, :cancellation_proof_action_runner, fn _, _, _ ->
      {:ok,
       %{
         status: :needs_confirmation,
         confirmation_id: "conf-proof",
         message: "Cancellation proof is ready for approval."
       }}
    end)

    assert {output, 1} = CancellationProof.dispatch(["timeout"], %{actor: "operator"})
    assert output =~ "conf-proof"
    assert output =~ "allbert admin confirmations approve conf-proof"
  end
end
