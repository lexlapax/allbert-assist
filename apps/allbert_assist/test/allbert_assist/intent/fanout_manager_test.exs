defmodule AllbertAssist.Intent.FanoutManagerTest do
  use ExUnit.Case, async: true
  @moduletag :pure_async

  alias AllbertAssist.Actions.Intent.DirectAnswer.Policy, as: DirectAnswerPolicy
  alias AllbertAssist.Intent.{FanoutManager, FanoutPlan}
  alias AllbertAssist.Intent.FanoutManager.Policy, as: FanoutPolicy
  alias AllbertAssist.Intent.FanoutManager.ReqLLMImplementation

  defmodule ScriptedModel do
    def respond(text, profile, context) do
      attempt = Map.fetch!(context, :fanout_manager_attempt)
      send(context.test_pid, {:model_call, attempt, text, profile.name})

      case attempt do
        :initial -> Map.fetch!(context, :initial_response)
        {:repair, _reason} -> Map.fetch!(context, :repair_response)
      end
    end
  end

  defmodule RaisingModel do
    def respond(_text, _profile, _context), do: raise("provider exploded")
  end

  defmodule SlowInvalidModel do
    def respond(text, profile, context) do
      send(
        context.test_pid,
        {:timed_model_call, context.fanout_manager_attempt, context.timeout_ms}
      )

      case context.fanout_manager_attempt do
        :initial ->
          Process.sleep(20)

          {:ok,
           %{
             "mode" => "fanout",
             "answer" => "I can answer this safely without parallel work.",
             "children_json" => "[]"
           }}

        {:repair, _reason} ->
          send(context.test_pid, {:unexpected_repair, text, profile.name})
          {:error, :unexpected_repair}
      end
    end
  end

  defmodule RecordingReqLLM do
    def generate_object(model_spec, prompt, schema, opts) do
      send(Keyword.fetch!(opts, :test_pid), {:req_llm_call, model_spec, prompt, schema, opts})

      {:ok,
       %{
         object: %{
           "mode" => "answer",
           "answer" => "A useful structured answer.",
           "children_json" => "[]"
         }
       }}
    end
  end

  @profile %{
    name: "local",
    provider: "local_ollama",
    provider_endpoint_kind: "local_endpoint",
    provider_type: "openai_compatible",
    model: "fixture-model",
    max_tokens: 1_024,
    timeout_ms: 5_000
  }

  @request "Research alpha and beta independently, then report the findings."

  test "one qualified call returns a useful answer without inventing a plan" do
    context =
      context(
        initial_response:
          {:ok,
           %{
             "mode" => "answer",
             "answer" => "Alpha and beta are names used in the supplied request.",
             "children_json" => "[]"
           }}
      )

    assert {:ok,
            %{
              kind: :answer,
              message: "Alpha and beta are names used in the supplied request.",
              diagnostic: %{attempts: 1, outcome: :answered}
            }} = FanoutManager.respond(@request, context)

    assert_received {:model_call, :initial, @request, "local"}
    refute_received {:model_call, {:repair, _reason}, _text, _profile}
  end

  test "one qualified call returns an inert ordered plan with a useful fallback answer" do
    context = context(initial_response: {:ok, fanout_response()})

    assert {:ok,
            %{
              kind: :fanout,
              fallback_answer: "I can research both options and compare the findings.",
              plan: %FanoutPlan{} = plan,
              diagnostic: %{
                attempts: 1,
                outcome: :planned,
                model_profile: "local",
                model_profile_sha256: profile_digest
              }
            }} = FanoutManager.respond(@request, context)

    assert profile_digest =~ ~r/^[0-9a-f]{64}$/
    assert Enum.map(plan.children, & &1["title"]) == ["Research alpha", "Research beta"]
    assert plan.original_request == @request
    assert_received {:model_call, :initial, @request, "local"}
    refute_received {:model_call, {:repair, _reason}, _text, _profile}
  end

  test "qualified profile binding is content-free, deterministic, and detects configuration drift" do
    binding = FanoutManager.profile_binding(@profile)

    assert binding == FanoutManager.profile_binding(Map.new(@profile))
    assert binding["name"] == "local"
    assert binding["configuration_sha256"] =~ ~r/^[0-9a-f]{64}$/
    refute inspect(binding) =~ "fixture-model"

    assert FanoutManager.profile_matches?(@profile, binding)
    refute FanoutManager.profile_matches?(%{@profile | model: "different-model"}, binding)
  end

  test "validated overflow returns the existing complete-list clarification without repair" do
    children =
      for index <- 1..3 do
        %{
          title: "Task #{index}",
          objective: "Research task #{index}.",
          expected_result: "A factual result for task #{index}."
        }
      end

    context =
      context(
        max_children_per_fanout: 2,
        initial_response:
          {:ok,
           %{
             "mode" => "fanout",
             "answer" => "I found three separate tasks.",
             "children_json" => Jason.encode!(children)
           }}
      )

    assert {:ok,
            %{
              kind: :clarify,
              fallback_answer: "I found three separate tasks.",
              clarification: %{
                task_count: 3,
                max_children: 2,
                tasks: ["Research task 1.", "Research task 2.", "Research task 3."]
              },
              diagnostic: %{attempts: 1, outcome: :overflow}
            }} = FanoutManager.respond(@request, context)

    assert_received {:model_call, :initial, @request, "local"}
    refute_received {:model_call, {:repair, _reason}, _text, _profile}
  end

  test "invalid plan receives at most one repair" do
    invalid =
      put_in(
        fanout_response(),
        ["children_json"],
        Jason.encode!([
          %{
            title: "Research alpha",
            objective: "Research alpha",
            expected_result: "Facts",
            permission: "allowed"
          },
          %{title: "Research beta", objective: "Research beta", expected_result: "Facts"}
        ])
      )

    context =
      context(
        initial_response: {:ok, invalid},
        repair_response: {:ok, fanout_response()}
      )

    assert {:ok, %{kind: :fanout, diagnostic: %{attempts: 2, outcome: :planned}}} =
             FanoutManager.respond(@request, context)

    assert_received {:model_call, :initial, @request, "local"}
    assert_received {:model_call, {:repair, {:invalid_child_keys, 0}}, @request, "local"}
    refute_received {:model_call, _third_attempt, _text, _profile}
  end

  test "failed repair retains the initial useful answer and fails closed to one turn" do
    invalid = %{
      "mode" => "fanout",
      "answer" => "I can still answer this as one bounded request.",
      "children_json" => Jason.encode!([%{title: "only one"}])
    }

    context =
      context(
        initial_response: {:ok, invalid},
        repair_response: {:error, :timeout}
      )

    assert {:ok,
            %{
              kind: :answer,
              message: "I can still answer this as one bounded request.",
              diagnostic: %{
                attempts: 2,
                outcome: :answered_after_invalid_plan,
                plan_error: _reason
              }
            }} = FanoutManager.respond(@request, context)

    assert_received {:model_call, :initial, @request, "local"}
    assert_received {:model_call, {:repair, _reason}, @request, "local"}
    refute_received {:model_call, _third_attempt, _text, _profile}
  end

  test "one monotonic deadline covers initial and repair instead of resetting per call" do
    context =
      context(
        model_client: SlowInvalidModel,
        timeout_ms: 5,
        initial_response: :unused
      )

    assert {:ok,
            %{
              kind: :answer,
              message: "I can answer this safely without parallel work.",
              diagnostic: %{outcome: :answered_after_invalid_plan, attempts: 1}
            }} = FanoutManager.respond(@request, context)

    assert_received {:timed_model_call, :initial, initial_timeout}
    assert initial_timeout in 1..5
    refute_received {:timed_model_call, {:repair, _reason}, _timeout}
    refute_received {:unexpected_repair, _text, _profile}
  end

  test "malformed answer without a repair answer fails closed" do
    context =
      context(
        initial_response: {:ok, %{"mode" => "answer", "answer" => "", "children_json" => "[]"}},
        repair_response: {:error, :offline}
      )

    assert {:error, {:fanout_manager_failed, _reason}} =
             FanoutManager.respond(@request, context)
  end

  test "model exceptions are bounded errors" do
    assert {:error, {:model_call_failed, _reason}} =
             FanoutManager.respond(
               @request,
               context(model_client: RaisingModel, initial_response: :unused)
             )
  end

  test "model is not called when model use is disabled" do
    assert {:error, :direct_answer_model_disabled} =
             FanoutManager.respond(@request, %{
               model_enabled?: false,
               model_profile: @profile,
               model_client: ScriptedModel,
               test_pid: self()
             })

    refute_received {:model_call, _attempt, _text, _profile}
  end

  test "oversized requests fall back before planning from an incomplete prompt" do
    assert {:error, :request_too_large_for_fanout} =
             FanoutManager.respond(
               String.duplicate("x", 4_001),
               context(initial_response: {:ok, fanout_response()})
             )

    refute_received {:model_call, _attempt, _text, _profile}
  end

  test "manager prompt derives direct-answer fidelity and fanout semantics from rules" do
    assert {:ok, prompt} = ReqLLMImplementation.prompt_context(@request, %{})

    rule_ids = hd(prompt.messages).metadata.allbert_prompt.rule_ids

    assert Enum.all?(DirectAnswerPolicy.rule_ids(), &(&1 in rule_ids))
    assert Enum.all?(FanoutPolicy.rule_ids(), &(&1 in rule_ids))
    assert List.last(prompt.messages).metadata.allbert_prompt.content_class == :operator_input
  end

  test "ReqLLM implementation uses the qualified profile and injectable structured client" do
    assert {:ok,
            %{
              "mode" => "answer",
              "answer" => "A useful structured answer.",
              "children_json" => "[]"
            }} =
             ReqLLMImplementation.respond(@request, %{@profile | max_tokens: 8_192}, %{
               req_llm_client: RecordingReqLLM,
               test_pid: self(),
               timeout_ms: 3_000
             })

    assert_received {:req_llm_call, %{provider: :openai, id: "fixture-model"}, prompt, schema,
                     opts}

    assert %ReqLLM.Context{} = prompt
    assert schema[:mode][:required]
    assert schema[:answer][:required]
    assert schema[:children_json][:required]
    assert opts[:temperature] == 0.0
    assert opts[:max_tokens] == 1_024
    assert opts[:receive_timeout] == 3_000
    assert opts[:openai_structured_output_mode] == :json_schema
    assert hd(prompt.messages).metadata.allbert_prompt.purpose == :conversation_management
  end

  defp context(overrides) do
    overrides
    |> Map.new()
    |> Map.merge(%{
      model_enabled?: true,
      model_profile: @profile,
      model_client: ScriptedModel,
      test_pid: self(),
      max_children_per_fanout: 8
    })
    |> Map.merge(Map.new(overrides))
  end

  defp fanout_response do
    %{
      "mode" => "fanout",
      "answer" => "I can research both options and compare the findings.",
      "children_json" =>
        Jason.encode!([
          %{
            title: "Research alpha",
            objective: "Research alpha independently.",
            expected_result: "A factual alpha summary."
          },
          %{
            title: "Research beta",
            objective: "Research beta independently.",
            expected_result: "A factual beta summary."
          }
        ])
    }
  end
end
