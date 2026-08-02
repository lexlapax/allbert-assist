defmodule AllbertAssist.Runtime.FanoutObservabilityTest do
  use AllbertAssist.DataCase, async: false
  @moduletag :db_serial

  alias AllbertAssist.Conversations
  alias AllbertAssist.Intent.FanoutPlan
  alias AllbertAssist.Objectives
  alias AllbertAssist.Runtime
  alias AllbertAssist.Runtime.FanoutDiagnostics
  alias AllbertAssist.Settings

  setup do
    original_runtime = Application.get_env(:allbert_assist, Runtime)
    original_readiness = Application.get_env(:allbert_assist, :runtime_model_readiness)

    Application.put_env(
      :allbert_assist,
      :runtime_model_readiness,
      AllbertAssist.Test.ModelReadinessFake
    )

    assert {:ok, _setting} =
             Settings.put("objectives.fanout.enabled", true, %{audit?: false})

    assert {:ok, _setting} =
             Settings.put("objectives.fanout.rollout_mode", "automatic", %{audit?: false})

    assert {:ok, _setting} =
             Settings.put("objectives.fanout.confirm_before_start", false, %{audit?: false})

    assert {:ok, _setting} =
             Settings.put("intent.direct_answer_model_enabled", true, %{audit?: false})

    assert {:ok, _setting} =
             Settings.put("channels.telegram.autonomous_notify.enabled", false, %{audit?: false})

    Application.put_env(:allbert_assist, Runtime, decomposer: fn _text, _context -> :single end)

    on_exit(fn ->
      if original_runtime,
        do: Application.put_env(:allbert_assist, Runtime, original_runtime),
        else: Application.delete_env(:allbert_assist, Runtime)

      if is_nil(original_readiness),
        do: Application.delete_env(:allbert_assist, :runtime_model_readiness),
        else: Application.put_env(:allbert_assist, :runtime_model_readiness, original_readiness)
    end)

    :ok
  end

  test "request-binding rejection is visible in the response and durable action log" do
    text = "Research two independent options and compare them."

    Application.put_env(:allbert_assist, Runtime,
      decomposer: fn _text, _context -> :single end,
      agent_runner: fn _signal, _request ->
        {:ok, plan} =
          FanoutPlan.compile("Different operator request", [
            %{title: "One", objective: "Research one", expected_result: "One result"},
            %{title: "Two", objective: "Research two", expected_result: "Two result"}
          ])

        {:ok,
         %{
           message: "Safe one-turn fallback",
           status: :completed,
           parallel_work_plan: plan,
           fanout_manager: %{
             outcome: :planned,
             prompt: "manager-prompt-secret",
             provider_payload: "provider-payload-secret"
           },
           diagnostics: [
             %{
               source: :fanout_manager,
               result: :fanout,
               outcome: :planned,
               attempts: 2,
               policy_outcome: :independent_advisory,
               join_role: :parent_presentation_only,
               work_unit_count: 2,
               reviewed: true
             }
           ]
         }}
      end
    )

    assert {:ok, response} =
             Runtime.submit_user_input(%{
               text: text,
               delivery_ack_capability: Runtime.fanout_delivery_ack_capability(),
               channel: :test,
               user_id: "binding-observability"
             })

    assert response.message == "Safe one-turn fallback"
    refute Map.has_key?(response, :fanout)
    assert Objectives.list_objectives("binding-observability") == []

    assert Enum.any?(response.diagnostics, fn diagnostic ->
             diagnostic == %{
               source: :fanout_admission,
               outcome: :rejected,
               reason: :plan_request_binding_mismatch
             }
           end)

    persisted = persisted_assistant_diagnostics!("binding-observability", response.thread_id)

    assert Enum.any?(persisted, fn diagnostic ->
             diagnostic == %{
               "source" => "fanout_admission",
               "outcome" => "rejected",
               "reason" => "plan_request_binding_mismatch"
             }
           end)

    refute inspect(persisted) =~ "manager-prompt-secret"
    refute inspect(persisted) =~ "provider-payload-secret"
  end

  test "successful manager admission retains only bounded manager and admission facts" do
    text = "Research Juniper and Cedar independently, then compare them."

    Application.put_env(:allbert_assist, Runtime,
      decomposer: fn _text, _context -> :single end,
      agent_runner: fn _signal, request ->
        {:ok, plan} =
          FanoutPlan.compile(request.operator_text, [
            %{title: "Juniper", objective: "Research Juniper", expected_result: "Juniper"},
            %{title: "Cedar", objective: "Research Cedar", expected_result: "Cedar"}
          ])

        {:ok,
         %{
           message: "Safe fallback answer",
           status: :completed,
           parallel_work_plan: plan,
           fanout_manager: %{
             outcome: :planned,
             attempts: 2,
             plan_deadline_unix_ms: System.system_time(:millisecond) + 60_000,
             prompt: "admitted-manager-prompt-secret",
             children: ["admitted-child-secret"]
           },
           diagnostics: [manager_fact(:fanout, :planned)]
         }}
      end
    )

    assert {:ok, response} =
             Runtime.submit_user_input(%{
               text: text,
               delivery_ack_capability: Runtime.fanout_delivery_ack_capability(),
               channel: :test,
               user_id: "admitted-observability"
             })

    assert response.message =~ "I split this into 2 tasks"

    assert Enum.any?(response.diagnostics, fn diagnostic ->
             diagnostic.source == :fanout_manager and diagnostic.result == :fanout
           end)

    assert Enum.any?(response.diagnostics, fn diagnostic ->
             diagnostic == %{source: :fanout_admission, outcome: :admitted}
           end)

    persisted = persisted_assistant_diagnostics!("admitted-observability", response.thread_id)

    assert Enum.any?(persisted, &(&1["source"] == "fanout_manager"))

    assert Enum.any?(persisted, fn diagnostic ->
             diagnostic == %{"source" => "fanout_admission", "outcome" => "admitted"}
           end)

    refute inspect(persisted) =~ "admitted-manager-prompt-secret"
    refute inspect(persisted) =~ "admitted-child-secret"
    refute inspect(persisted) =~ "fact-provider-secret"
  end

  test "frame failure falls back once with a closed durable reason" do
    text = "Research Juniper and Cedar independently."

    Application.put_env(:allbert_assist, Runtime,
      decomposer: fn _text, _context -> :single end,
      fanout_framer: fn _attrs, _children ->
        {:error, {:provider_frame_failure, "frame-error-secret"}}
      end,
      agent_runner: fn _signal, request ->
        {:ok, plan} =
          FanoutPlan.compile(request.operator_text, [
            %{title: "Juniper", objective: "Research Juniper", expected_result: "Juniper"},
            %{title: "Cedar", objective: "Research Cedar", expected_result: "Cedar"}
          ])

        {:ok,
         %{
           message: "Safe same-call answer",
           status: :completed,
           parallel_work_plan: plan,
           fanout_manager: %{
             outcome: :planned,
             attempts: 2,
             plan_deadline_unix_ms: System.system_time(:millisecond) + 60_000,
             raw_error: "manager-error-secret"
           },
           diagnostics: [manager_fact(:fanout, :planned)]
         }}
      end
    )

    assert {:ok, response} =
             Runtime.submit_user_input(%{
               text: text,
               delivery_ack_capability: Runtime.fanout_delivery_ack_capability(),
               channel: :test,
               user_id: "frame-fallback-observability"
             })

    assert response.message == "Safe same-call answer"
    refute Map.has_key?(response, :fanout)
    assert Objectives.list_objectives("frame-fallback-observability") == []

    assert Enum.any?(response.diagnostics, fn diagnostic ->
             diagnostic == %{
               source: :fanout_admission,
               outcome: :single_turn_fallback,
               reason: :fanout_frame_failed
             }
           end)

    persisted =
      persisted_assistant_diagnostics!("frame-fallback-observability", response.thread_id)

    assert Enum.any?(persisted, fn diagnostic ->
             diagnostic == %{
               "source" => "fanout_admission",
               "outcome" => "single_turn_fallback",
               "reason" => "fanout_frame_failed"
             }
           end)

    refute inspect(persisted) =~ "frame-error-secret"
    refute inspect(persisted) =~ "manager-error-secret"
  end

  test "shadow planning is durable as advisory-only without creating work" do
    assert {:ok, _setting} =
             Settings.put("objectives.fanout.rollout_mode", "shadow", %{audit?: false})

    text = "Research two options and compare them."

    Application.put_env(:allbert_assist, Runtime,
      decomposer: fn _text, _context -> :single end,
      agent_runner: fn _signal, request ->
        {:ok, plan} =
          FanoutPlan.compile(request.operator_text, [
            %{title: "One", objective: "Research one", expected_result: "One"},
            %{title: "Two", objective: "Research two", expected_result: "Two"}
          ])

        {:ok,
         %{
           message: "One-turn shadow answer",
           status: :completed,
           parallel_work_plan: plan,
           fanout_manager: %{outcome: :planned, answer: "shadow-answer-secret"},
           diagnostics: [manager_fact(:fanout, :planned)]
         }}
      end
    )

    assert {:ok, response} =
             Runtime.submit_user_input(%{
               text: text,
               delivery_ack_capability: Runtime.fanout_delivery_ack_capability(),
               channel: :test,
               user_id: "shadow-observability"
             })

    assert response.message == "One-turn shadow answer"
    refute Map.has_key?(response, :fanout)
    assert Objectives.list_objectives("shadow-observability") == []

    assert Enum.any?(response.diagnostics, fn diagnostic ->
             diagnostic == %{source: :fanout_admission, outcome: :shadow_only}
           end)

    persisted = persisted_assistant_diagnostics!("shadow-observability", response.thread_id)

    assert Enum.any?(persisted, fn diagnostic ->
             diagnostic == %{"source" => "fanout_admission", "outcome" => "shadow_only"}
           end)

    refute inspect(persisted) =~ "shadow-answer-secret"
  end

  test "manager clarification keeps its bounded fact through Runtime rendering" do
    clarification = %{
      task_count: 3,
      max_children: 2,
      tasks: ["Research one", "Research two", "Research three"]
    }

    Application.put_env(:allbert_assist, Runtime,
      decomposer: fn _text, _context -> :single end,
      agent_runner: fn _signal, _request ->
        {:ok,
         %{
           message: "I found three tasks.",
           status: :completed,
           parallel_work_clarification: clarification,
           fanout_manager: %{outcome: :overflow, provider_payload: "clarify-provider-secret"},
           diagnostics: [
             %{
               source: :fanout_manager,
               result: :clarify,
               outcome: :overflow,
               attempts: 2,
               policy_outcome: :independent_advisory,
               join_role: :parent_presentation_only,
               work_unit_count: 3,
               reviewed: true
             }
           ]
         }}
      end
    )

    assert {:ok, response} =
             Runtime.submit_user_input(%{
               text: "Research three independent topics.",
               delivery_ack_capability: Runtime.fanout_delivery_ack_capability(),
               channel: :test,
               user_id: "clarify-observability"
             })

    assert response.status == :advisory
    assert response.decomposition_overflow == clarification

    assert Enum.any?(response.diagnostics, fn diagnostic ->
             diagnostic.source == :fanout_manager and diagnostic.result == :clarify
           end)

    persisted = persisted_assistant_diagnostics!("clarify-observability", response.thread_id)

    assert Enum.any?(persisted, fn diagnostic ->
             diagnostic["source"] == "fanout_manager" and diagnostic["result"] == "clarify"
           end)

    refute inspect(persisted) =~ "clarify-provider-secret"
  end

  test "ordinary answer and manager-error facts survive Runtime without raw metadata" do
    cases = [
      {:answer, :answered, "answer-runtime-secret"},
      {:error, :manager_unavailable, "error-runtime-secret"}
    ]

    for {result, outcome, secret} <- cases do
      user_id = "#{result}-runtime-observability"

      Application.put_env(:allbert_assist, Runtime,
        decomposer: fn _text, _context -> :single end,
        agent_runner: fn _signal, _request ->
          diagnostic =
            if result == :error do
              %{
                "source" => "fanout_manager",
                "result" => "error",
                "outcome" => "manager_unavailable",
                "raw_error" => secret
              }
            else
              %{
                source: :fanout_manager,
                result: result,
                outcome: outcome,
                raw_error: secret
              }
            end

          {:ok,
           %{
             message: "Useful one-turn answer",
             status: :completed,
             direct_answer: %{
               source: :model,
               diagnostic: %{status: :used, manager: %{raw_error: secret}}
             },
             actions: [
               %{
                 name: "direct_answer",
                 direct_answer: %{
                   source: :model,
                   diagnostic: %{status: :used, manager: %{raw_error: secret}}
                 }
               }
             ],
             fanout_manager: %{provider_payload: secret},
             diagnostics: [diagnostic]
           }}
        end
      )

      assert {:ok, response} =
               Runtime.submit_user_input(%{
                 text: "Explain one topic.",
                 delivery_ack_capability: Runtime.fanout_delivery_ack_capability(),
                 channel: :test,
                 user_id: user_id
               })

      refute inspect(response) =~ secret

      persisted = persisted_assistant_diagnostics!(user_id, response.thread_id)
      action_log = persisted_assistant_action_log!(user_id, response.thread_id)

      assert Enum.any?(persisted, fn diagnostic ->
               diagnostic == %{
                 "source" => "fanout_manager",
                 "result" => Atom.to_string(result),
                 "outcome" => Atom.to_string(outcome)
               }
             end)

      refute inspect(persisted) =~ secret
      refute inspect(action_log) =~ secret

      refute get_in(action_log, ["actions", Access.at(0), "direct_answer", "diagnostic"])[
               "manager"
             ]
    end
  end

  test "manager facts accept only closed result-coherent classifications" do
    assert [fact] =
             FanoutDiagnostics.sanitize([
               %{
                 source: :fanout_manager,
                 result: :answer,
                 outcome: :planned,
                 policy_outcome: :invented_policy,
                 join_role: :invented_join,
                 attempts: 1,
                 work_unit_count: 0,
                 reviewed: true
               }
             ])

    assert fact == %{
             source: :fanout_manager,
             result: :answer,
             outcome: :answered,
             attempts: 1,
             work_unit_count: 0,
             reviewed: true
           }
  end

  defp persisted_assistant_diagnostics!(user_id, thread_id) do
    user_id
    |> persisted_assistant_action_log!(thread_id)
    |> Map.fetch!("diagnostics")
  end

  defp persisted_assistant_action_log!(user_id, thread_id) do
    {:ok, thread} = Conversations.get_thread(user_id, thread_id)

    thread
    |> Conversations.list_messages(limit: 10)
    |> Enum.find(&(&1.role == "assistant"))
    |> Map.fetch!(:action_log)
  end

  defp manager_fact(result, outcome) do
    %{
      source: :fanout_manager,
      result: result,
      outcome: outcome,
      attempts: 2,
      policy_outcome: :independent_advisory,
      join_role: :parent_presentation_only,
      work_unit_count: 2,
      reviewed: true,
      provider_payload: "fact-provider-secret"
    }
  end
end
