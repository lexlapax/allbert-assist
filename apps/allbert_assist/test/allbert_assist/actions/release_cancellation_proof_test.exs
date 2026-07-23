defmodule AllbertAssist.Actions.ReleaseCancellationProofTest do
  use AllbertAssist.DataCase, async: false, lane: :app_env_serial

  alias AllbertAssist.Actions.Execution.ReleaseCancellationProof
  alias AllbertAssist.Actions.Runner
  alias AllbertAssist.CLI.Areas.Confirmations
  alias AllbertAssist.Settings
  alias AllbertAssist.Surfaces.ContextBuilder

  setup do
    original = Application.get_env(:allbert_assist, :cancellation_proof_runner)

    on_exit(fn ->
      if original,
        do: Application.put_env(:allbert_assist, :cancellation_proof_runner, original),
        else: Application.delete_env(:allbert_assist, :cancellation_proof_runner)
    end)

    :ok
  end

  test "an approved resume executes the closed proof and renders stable evidence" do
    parent = self()

    Application.put_env(:allbert_assist, :cancellation_proof_runner, fn mode ->
      send(parent, {:proof, mode})

      {:ok,
       %{
         status: :passed,
         mode: mode,
         containment: :process_group,
         target_tree_dead?: true,
         cleanup_complete?: true
       }}
    end)

    assert {:ok, response} =
             ReleaseCancellationProof.run(
               %{mode: "timeout"},
               %{user_id: "local", confirmation: %{approved?: true}}
             )

    assert response.status == :completed
    assert response.message =~ "OV12 status=PASS mode=timeout"
    assert response.message =~ "cleanup_complete?=true"
    assert_received {:proof, "timeout"}
  end

  test "invalid mode never reaches the execution service" do
    Application.put_env(:allbert_assist, :cancellation_proof_runner, fn _mode ->
      flunk("invalid mode reached proof runner")
    end)

    assert {:ok, response} =
             ReleaseCancellationProof.run(%{mode: "custom"}, %{user_id: "local"})

    assert response.status == :error
  end

  test "unsupported host capability is an explicit failed proof, not a pass" do
    Application.put_env(:allbert_assist, :cancellation_proof_runner, fn mode ->
      {:ok,
       %{
         status: :unsupported,
         mode: mode,
         containment: :process_group,
         boundary: :setsid_unavailable,
         cleanup_complete?: true
       }}
    end)

    assert {:ok, response} =
             ReleaseCancellationProof.run(
               %{mode: "session-escape"},
               %{user_id: "local", confirmation: %{approved?: true}}
             )

    assert response.status == :failed
    assert response.message =~ "status=UNSUPPORTED"
    refute response.message =~ "status=PASS"
  end

  test "normal runner invocation creates a durable confirmation before execution" do
    assert {:ok, _} =
             Settings.put("permissions.command_execute", "needs_confirmation", %{audit?: false})

    parent = self()

    Application.put_env(:allbert_assist, :cancellation_proof_runner, fn mode ->
      send(parent, {:approved_proof, mode})

      {:ok,
       %{
         status: :passed,
         mode: mode,
         containment: :process_group,
         target_tree_dead?: true,
         sibling_survived?: true,
         cleanup_complete?: true
       }}
    end)

    assert {:ok, response} =
             Runner.run(
               "release_cancellation_proof",
               %{mode: "cancel"},
               ContextBuilder.cli_context(%{user_id: "local", actor: "operator"})
             )

    assert response.status == :needs_confirmation, inspect(response, pretty: true)
    assert is_binary(response.confirmation_id)
    assert response.message =~ response.confirmation_id
    refute_received {:approved_proof, _mode}

    assert {output, 0} =
             Confirmations.dispatch(
               ["approve", response.confirmation_id],
               ContextBuilder.cli_context(%{user_id: "local", actor: "operator"})
             )

    assert output =~ "OV12 status=PASS mode=cancel containment=process_group"
    assert output =~ "cleanup_complete?=true"
    assert_received {:approved_proof, "cancel"}
  end
end
