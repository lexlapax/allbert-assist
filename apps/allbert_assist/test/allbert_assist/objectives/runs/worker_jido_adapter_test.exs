defmodule AllbertAssist.Objectives.Runs.WorkerJidoAdapterTest do
  @moduledoc """
  v1.3 M9.b.6 (ADR 0021 A24): a healthy fan-out child makes exactly one physical
  provider call. The draft/critic/revision transitions are gone, so these rows
  own generation, exact physical attempt accounting, deadline and cancellation
  behavior, redaction bounds, and the receipt-v3 binding.
  """
  use AllbertAssist.DataCase, async: false, lane: :db_serial

  alias AllbertAssist.Actions.Intent.DirectAnswer
  alias AllbertAssist.Models.ProviderAttempt
  alias AllbertAssist.Objectives.Fanout.Budget
  alias AllbertAssist.Objectives.ObservationSummary
  alias AllbertAssist.Objectives.Runs.{CancelToken, Worker}
  alias AllbertAssist.Objectives.Runs.Worker.JidoAdapter
  alias AllbertAssist.Objectives.Runs.Worker.QualityPolicy

  defmodule GenerationAnswerer do
    def answer(text, context) do
      :ok = ProviderAttempt.mark(context)
      send(context.test_pid, {:generation_call, text, context.fanout_worker_policy})
      {:ok, %{message: "One generated child observation.", diagnostic: %{status: :used}}}
    end
  end

  defmodule OrdinaryAnswerer do
    def answer(_text, context) do
      send(context.test_pid, {:ordinary_provider_call, Map.get(context, :fanout_worker_policy)})
      {:ok, %{message: "Ordinary one-call answer.", diagnostic: %{status: :used}}}
    end
  end

  defmodule LongRedactableAnswerer do
    @message "AIzaSyDUMMYSecretShapeForAudit59 " <> String.duplicate("durable answer ", 220)

    def message, do: @message

    def answer(_text, context) do
      :ok = ProviderAttempt.mark(context)
      send(context.test_pid, :long_redactable_generated)
      {:ok, %{message: @message, diagnostic: %{status: :used}}}
    end
  end

  defmodule BlankAnswerer do
    def answer(_text, context) do
      :ok = ProviderAttempt.mark(context)
      send(context.test_pid, :blank_generated)
      {:ok, %{message: " \n\t ", diagnostic: %{status: :used}}}
    end
  end

  defmodule BlockingAnswerer do
    def answer(_text, context) do
      :ok = ProviderAttempt.mark(context)
      send(context.test_pid, :blocking_started)
      Process.sleep(1_000)
      send(context.test_pid, :blocking_returned)
      {:ok, %{message: "Late answer must not be accepted.", diagnostic: %{status: :used}}}
    end
  end

  defmodule TimeoutRecordingAnswerer do
    def answer(_text, context) do
      :ok = ProviderAttempt.mark(context)

      send(
        context.test_pid,
        {:deadline_context, context.model_timeout_ms, context.fanout_worker_deadline_monotonic_ms}
      )

      {:ok, %{message: "Deadline-bound answer.", diagnostic: %{status: :used}}}
    end
  end

  defmodule FailingAnswerer do
    def answer(_text, context) do
      :ok = ProviderAttempt.mark(context)
      send(context.test_pid, :generation_failed)
      {:error, :provider_unavailable}
    end
  end

  defmodule RaisingAnswerer do
    def answer(_text, context) do
      :ok = ProviderAttempt.mark(context)
      send(context.test_pid, :raising_provider_called)
      raise "injected provider exception after dispatch"
    end
  end

  defmodule ExitingAnswerer do
    def answer(_text, context) do
      :ok = ProviderAttempt.mark(context)
      send(context.test_pid, :exiting_provider_called)
      exit(:injected_provider_exit_after_dispatch)
    end
  end

  defmodule PreflightFailingAnswerer do
    def answer(_text, context) do
      send(context.test_pid, :preflight_failed)
      {:error, :model_spec_unavailable}
    end
  end

  defmodule DoubleAttemptAnswerer do
    def answer(_text, context) do
      :ok = ProviderAttempt.mark(context)
      :ok = ProviderAttempt.mark(context)
      send(context.test_pid, :double_provider_attempt)
      {:ok, %{message: "Over-budget answer.", diagnostic: %{status: :used}}}
    end
  end

  defmodule CancellingAnswerer do
    alias AllbertAssist.Objectives.Runs.CancelToken

    def answer(_text, context) do
      :ok = ProviderAttempt.mark(context)
      :ok = CancelToken.cancel(context.cancel_token)
      send(context.test_pid, :cancelled_during_generation)

      {:ok,
       %{message: "Answer completed while cancellation arrived.", diagnostic: %{status: :used}}}
    end
  end

  setup do
    previous = Application.get_env(:allbert_assist, DirectAnswer)

    on_exit(fn ->
      if previous,
        do: Application.put_env(:allbert_assist, DirectAnswer, previous),
        else: Application.delete_env(:allbert_assist, DirectAnswer)

      AllbertAssist.Settings.put("intent.direct_answer_model_enabled", false, %{audit?: false})
    end)

    :ok
  end

  test "one generation terminalizes the child and mints a v4 provenance receipt" do
    Application.put_env(:allbert_assist, DirectAnswer, answerer: GenerationAnswerer)
    enable_model!()

    {grounding, context} = quality_worker_context()

    assert {:ok, %{response: %{message: message}, quality_receipt: receipt}} =
             Worker.run("direct_answer", %{text: grounding.direct_answer_text}, context)

    assert message == "One generated child observation."
    assert receipt["version"] == 4
    assert receipt["generation_call_count"] == 1
    assert receipt["provider_call_count"] == 1
    # The receipt records what happened, not a judgment: nothing evaluates the
    # answer, so it must not claim acceptance.
    assert receipt["outcome"] == "generated"
    refute Map.has_key?(receipt, "verdict")
    assert receipt["final_answer_sha256"] == sha256(message)

    assert_receive {:generation_call, _text, %{version: 1}}
    refute_receive {:generation_call, _text, _policy}
  end

  test "the generation prompt is derived from the exact task contract" do
    Application.put_env(:allbert_assist, DirectAnswer, answerer: GenerationAnswerer)
    enable_model!()

    {grounding, context} = quality_worker_context()

    assert {:ok, contract} = QualityPolicy.build(grounding)
    assert {:ok, expected_prompt} = QualityPolicy.draft_prompt(contract)

    assert {:ok, _result} =
             Worker.run("direct_answer", %{text: grounding.direct_answer_text}, context)

    assert_receive {:generation_call, ^expected_prompt, _policy}
  end

  test "a model-disabled quality child fails before any provider call with count zero" do
    Application.put_env(:allbert_assist, DirectAnswer, answerer: GenerationAnswerer)

    assert {:ok, _setting} =
             AllbertAssist.Settings.put("intent.direct_answer_model_enabled", false, %{
               audit?: false
             })

    {grounding, context} = quality_worker_context()

    assert {:error, {:fanout_worker_unresolved, %{provider_call_count: 0}}} =
             Worker.run("direct_answer", %{text: grounding.direct_answer_text}, context)

    refute_receive {:generation_call, _text, _policy}
  end

  test "a failed generation provider reports exactly one physical attempt" do
    assert_post_dispatch_failure(FailingAnswerer, :generation_failed)
  end

  test "a generation exception after dispatch remains one unresolved physical attempt" do
    assert_post_dispatch_failure(RaisingAnswerer, :raising_provider_called)
  end

  test "a generation exit after dispatch remains one unresolved physical attempt" do
    assert_post_dispatch_failure(ExitingAnswerer, :exiting_provider_called)
  end

  test "a preflight failure reports zero physical provider attempts" do
    Application.put_env(:allbert_assist, DirectAnswer, answerer: PreflightFailingAnswerer)
    enable_model!()

    {grounding, context} = quality_worker_context()

    assert {:error, {:fanout_worker_unresolved, %{provider_call_count: 0}}} =
             Worker.run("direct_answer", %{text: grounding.direct_answer_text}, context)

    assert_receive :preflight_failed
  end

  test "the receipt binds the exact redacted bounded durable answer bytes" do
    Application.put_env(:allbert_assist, DirectAnswer, answerer: LongRedactableAnswerer)
    enable_model!()

    {grounding, context} = quality_worker_context()

    expected = ObservationSummary.normalize(LongRedactableAnswerer.message())
    assert String.length(expected) == 2_000
    refute expected == LongRedactableAnswerer.message()
    refute expected =~ "AIzaSyDUMMYSecretShapeForAudit59"
    assert expected =~ "[REDACTED]"

    assert {:ok, %{response: %{message: ^expected}, quality_receipt: receipt}} =
             Worker.run("direct_answer", %{text: grounding.direct_answer_text}, context)

    assert receipt["provider_call_count"] == 1
    assert receipt["final_answer_sha256"] == sha256(expected)
    assert_receive :long_redactable_generated
  end

  test "an empty normalized answer stops after its one generation attempt" do
    Application.put_env(:allbert_assist, DirectAnswer, answerer: BlankAnswerer)
    enable_model!()

    {grounding, context} = quality_worker_context()

    assert {:error,
            {:fanout_worker_unresolved,
             %{provider_call_count: 1, reason: :quality_model_draft_unavailable}}} =
             Worker.run("direct_answer", %{text: grounding.direct_answer_text}, context)

    assert_receive :blank_generated
  end

  test "multiple provider attempts inside one generation fail closed with the exact count" do
    Application.put_env(:allbert_assist, DirectAnswer, answerer: DoubleAttemptAnswerer)
    enable_model!()

    {grounding, context} = quality_worker_context()

    assert {:error, {:fanout_worker_unresolved, %{provider_call_count: 2}}} =
             Worker.run("direct_answer", %{text: grounding.direct_answer_text}, context)

    assert_receive :double_provider_attempt
  end

  test "quality work uses the remaining plan window instead of the legacy thirty-second cap" do
    Application.put_env(:allbert_assist, DirectAnswer, answerer: TimeoutRecordingAnswerer)
    enable_model!()

    {grounding, context} = quality_worker_context()

    assert {:ok, _result} =
             Worker.run("direct_answer", %{text: grounding.direct_answer_text}, context)

    assert_receive {:deadline_context, timeout_ms, worker_deadline}
    assert timeout_ms > 30_000
    assert is_integer(worker_deadline)
  end

  test "an expired durable plan deadline stops before a Worker task or provider attempt" do
    Application.put_env(:allbert_assist, DirectAnswer, answerer: GenerationAnswerer)
    enable_model!()

    {grounding, context} = quality_worker_context()
    context = Map.put(context, :fanout_deadline_unix_ms, System.system_time(:millisecond) - 1)

    assert {:error, :fanout_plan_deadline_exhausted} =
             JidoAdapter.run(DirectAnswer, %{text: grounding.direct_answer_text}, context, [])

    refute_receive {:generation_call, _text, _policy}
  end

  test "the Worker owner rejects and kills an answer that returns after its absolute deadline" do
    Application.put_env(:allbert_assist, DirectAnswer, answerer: BlockingAnswerer)
    enable_model!()

    {grounding, context} = quality_worker_context()
    context = Map.put(context, :fanout_deadline_unix_ms, System.system_time(:millisecond) + 150)

    assert {:error, :worker_timeout} =
             JidoAdapter.run(DirectAnswer, %{text: grounding.direct_answer_text}, context, [])

    assert_receive :blocking_started
    refute_receive :blocking_returned, 1_200
  end

  test "cancellation arriving during generation prevents checked completion" do
    Application.put_env(:allbert_assist, DirectAnswer, answerer: CancellingAnswerer)
    enable_model!()

    {grounding, context} = quality_worker_context()
    context = Map.put(context, :cancel_token, CancelToken.new())

    assert {:error, {:fanout_worker_unresolved, %{provider_call_count: 1}}} =
             Worker.run("direct_answer", %{text: grounding.direct_answer_text}, context)

    assert_receive :cancelled_during_generation
  end

  test "ordinary DirectAnswer remains one provider call with no worker policy or receipt" do
    Application.put_env(:allbert_assist, DirectAnswer, answerer: OrdinaryAnswerer)
    enable_model!()

    context = %{
      user_id: "ordinary-user",
      operator_id: "ordinary-user",
      actor: "ordinary-user",
      channel: "test",
      surface: "test",
      test_pid: self()
    }

    assert {:ok, response} =
             JidoAdapter.run(DirectAnswer, %{text: "Ordinary request."}, context, [])

    refute Map.has_key?(response, :quality_receipt)
    assert_receive {:ordinary_provider_call, nil}
  end

  defp assert_post_dispatch_failure(answerer, provider_message) do
    Application.put_env(:allbert_assist, DirectAnswer, answerer: answerer)
    enable_model!()

    {grounding, context} = quality_worker_context()

    assert {:error, {:fanout_worker_unresolved, %{provider_call_count: 1}}} =
             Worker.run("direct_answer", %{text: grounding.direct_answer_text}, context)

    assert_receive ^provider_message
    refute_receive ^provider_message
  end

  defp enable_model! do
    assert {:ok, _setting} =
             AllbertAssist.Settings.put("intent.direct_answer_model_enabled", true, %{
               audit?: false
             })
  end

  defp quality_worker_context do
    assert {:ok, budget} = Budget.resolve(2, 1)
    deadline = System.system_time(:millisecond) + 60_000

    grounding = %{
      source: :conversation_manager,
      original_request: "Prepare two independent analyses.",
      child_objective: "Analyze the first mechanism.",
      expected_result: "Cover its behavior and tradeoffs.",
      steering: nil,
      decision_text: nil,
      direct_answer_text: "legacy compiled task input",
      action_text: nil,
      fanout_budget: budget,
      fanout_deadline_unix_ms: deadline
    }

    context = %{
      user_id: "quality-worker-user",
      operator_id: "quality-worker-user",
      actor: "quality-worker-user",
      channel: "test",
      surface: "test",
      test_pid: self(),
      objective_id: "objective-#{System.unique_integer([:positive])}",
      step_id: "step-#{System.unique_integer([:positive])}",
      objective_run_attempt: 1,
      fanout_budget: budget,
      fanout_deadline_unix_ms: deadline,
      fanout_grounding: grounding
    }

    {grounding, context}
  end

  defp sha256(value) do
    :sha256
    |> :crypto.hash(value)
    |> Base.encode16(case: :lower)
  end
end
