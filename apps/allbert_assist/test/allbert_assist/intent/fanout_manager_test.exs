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

      case Map.fetch!(context, :fanout_manager_phase) do
        :assess -> Map.fetch!(context, :initial_response)
        :adjudicate -> Map.fetch!(context, :adjudication_response)
        {:repair_assessment, _reason} -> Map.fetch!(context, :repair_response)
      end
    end
  end

  defmodule RaisingModel do
    def respond(_text, _profile, _context), do: raise("provider exploded")
  end

  defmodule PhasedModel do
    def respond(text, profile, context) do
      phase =
        Map.get(context, :fanout_manager_phase) ||
          case Map.fetch!(context, :fanout_manager_attempt) do
            :initial -> :assess
            {:repair, _reason} -> :adjudicate
          end

      send(context.test_pid, {:phased_model_call, phase, text, profile.name})

      case phase do
        :assess -> Map.fetch!(context, :assessment_response)
        :adjudicate -> Map.fetch!(context, :adjudication_response)
      end
    end
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
             "answer" => "I can answer this safely without parallel work.",
             "work_units" => :invalid
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
         finish_reason: :stop,
         object: %{
           "answer" => "A useful structured answer.",
           "work_units" => []
         }
       }}
    end
  end

  defmodule RecordingAdjudicationReqLLM do
    def generate_object(model_spec, prompt, schema, opts) do
      send(
        Keyword.fetch!(opts, :test_pid),
        {:adjudication_req_llm_call, model_spec, prompt, schema, opts}
      )

      {:ok,
       %{
         finish_reason: :stop,
         object: %{
           "work_shape" => "independent_advisory",
           "join_role" => "presentation_only",
           "children" => [
             %{
               "title" => "Research alpha",
               "objective" => "Research alpha independently.",
               "expected_result" => "A factual alpha summary."
             },
             %{
               "title" => "Research beta",
               "objective" => "Research beta independently.",
               "expected_result" => "A factual beta summary."
             }
           ]
         }
       }}
    end
  end

  defmodule TruncatedReqLLM do
    def generate_object(_model_spec, _prompt, _schema, _opts) do
      {:ok,
       %{
         finish_reason: :length,
         object: %{"answer" => "Partial answer", "work_units" => []}
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

  test "Allbert adjudicates multi-unit join guidance before deriving a fanout plan" do
    work_units = [
      %{
        "title" => "Analyze OTP supervision",
        "objective" => "Analyze OTP supervision failure isolation.",
        "expected_result" => "A factual supervision analysis."
      },
      %{
        "title" => "Analyze event-log recovery",
        "objective" => "Analyze append-only event-log and projection recovery.",
        "expected_result" => "A factual recovery analysis."
      }
    ]

    context =
      context(
        model_client: PhasedModel,
        assessment_response:
          {:ok,
           %{
             "answer" => "OTP isolation and event replay are complementary recovery layers.",
             "work_units" => work_units
           }},
        adjudication_response:
          {:ok,
           %{
             "work_shape" => "independent_advisory",
             "join_role" => "presentation_only",
             "children" => work_units
           }}
      )

    assert {:ok,
            %{
              kind: :fanout,
              fallback_answer:
                "OTP isolation and event replay are complementary recovery layers.",
              plan: %FanoutPlan{} = plan,
              diagnostic: %{
                attempts: 2,
                outcome: :planned,
                policy_outcome: :independent_advisory,
                join_role: :presentation_only,
                work_unit_count: 2
              }
            }} = FanoutManager.respond(@request, context)

    assert Enum.map(plan.children, & &1["title"]) == [
             "Analyze OTP supervision",
             "Analyze event-log recovery"
           ]

    assert_received {:phased_model_call, :assess, @request, "local"}
    assert_received {:phased_model_call, :adjudicate, @request, "local"}
  end

  test "contradictory adjudication fails closed to the assessment answer" do
    context =
      context(
        model_client: PhasedModel,
        assessment_response: {:ok, assessment_response()},
        adjudication_response:
          {:ok,
           %{
             "work_shape" => "dependent_or_sequential",
             "join_role" => "consumes_sibling_result",
             "children" => work_units()
           }}
      )

    assert {:ok,
            %{
              kind: :answer,
              message: "I can research both options and compare the findings.",
              diagnostic: %{
                attempts: 2,
                outcome: :answered_after_invalid_adjudication,
                policy_outcome: :adjudication_invalid,
                adjudication_error: :inconsistent_adjudication
              }
            }} = FanoutManager.respond(@request, context)
  end

  test "valid dependent work is reviewed and remains one useful turn" do
    context =
      context(
        model_client: PhasedModel,
        assessment_response: {:ok, assessment_response()},
        adjudication_response:
          {:ok,
           %{
             "work_shape" => "dependent_or_sequential",
             "join_role" => "consumes_sibling_result",
             "children" => []
           }}
      )

    assert {:ok,
            %{
              kind: :answer,
              diagnostic: %{
                attempts: 2,
                outcome: :answered,
                policy_outcome: :dependent_or_sequential,
                join_role: :consumes_sibling_result,
                reviewed?: true
              }
            }} = FanoutManager.respond(@request, context)
  end

  test "one qualified call returns a useful answer without inventing a plan" do
    context =
      context(
        initial_response:
          {:ok,
           %{
             "answer" => "Alpha and beta are names used in the supplied request.",
             "work_units" => []
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
    context =
      context(
        initial_response: {:ok, assessment_response()},
        adjudication_response: {:ok, fanout_response()}
      )

    assert {:ok,
            %{
              kind: :fanout,
              fallback_answer: "I can research both options and compare the findings.",
              plan: %FanoutPlan{} = plan,
              diagnostic: %{
                attempts: 2,
                outcome: :planned,
                model_profile: "local",
                model_profile_sha256: profile_digest
              }
            }} = FanoutManager.respond(@request, context)

    assert profile_digest =~ ~r/^[0-9a-f]{64}$/
    assert Enum.map(plan.children, & &1["title"]) == ["Research alpha", "Research beta"]
    assert plan.original_request == @request
    assert_received {:model_call, :initial, @request, "local"}
    assert_received {:model_call, :adjudicate, @request, "local"}
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
             "answer" => "I found three separate tasks.",
             "work_units" => children
           }},
        adjudication_response:
          {:ok,
           %{
             "work_shape" => "independent_advisory",
             "join_role" => "none",
             "children" => children
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
              diagnostic: %{attempts: 2, outcome: :overflow}
            }} = FanoutManager.respond(@request, context)

    assert_received {:model_call, :initial, @request, "local"}
    assert_received {:model_call, :adjudicate, @request, "local"}
  end

  test "invalid assessment receives one repair but repaired multi-unit work is not admitted unreviewed" do
    invalid = %{
      "answer" => "I can research both options and compare the findings.",
      "work_units" => [
        %{
          title: "Research alpha",
          objective: "Research alpha",
          expected_result: "Facts",
          permission: "allowed"
        }
      ]
    }

    context =
      context(
        initial_response: {:ok, invalid},
        repair_response: {:ok, assessment_response()}
      )

    assert {:ok,
            %{
              kind: :answer,
              diagnostic: %{
                attempts: 2,
                outcome: :answered_after_assessment_repair,
                policy_outcome: :adjudication_not_run,
                adjudication_error: :manager_call_budget_used_by_assessment_repair
              }
            }} =
             FanoutManager.respond(@request, context)

    assert_received {:model_call, :initial, @request, "local"}
    assert_received {:model_call, {:repair, {:invalid_child_keys, 0}}, @request, "local"}
    refute_received {:model_call, _third_attempt, _text, _profile}
  end

  test "failed repair retains the initial useful answer and fails closed to one turn" do
    invalid = %{
      "answer" => "I can still answer this as one bounded request.",
      "work_units" => [%{title: "only one"}]
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
                outcome: :answered_after_invalid_assessment,
                assessment_error: _reason
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
              diagnostic: %{outcome: :answered_after_invalid_assessment, attempts: 1}
            }} = FanoutManager.respond(@request, context)

    assert_received {:timed_model_call, :initial, initial_timeout}
    assert initial_timeout in 1..5
    refute_received {:timed_model_call, {:repair, _reason}, _timeout}
    refute_received {:unexpected_repair, _text, _profile}
  end

  test "malformed answer without a repair answer fails closed" do
    context =
      context(
        initial_response: {:ok, %{"answer" => "", "work_units" => []}},
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
    assert Enum.all?(FanoutPolicy.prompt_rule_ids(:assess), &(&1 in rule_ids))
    refute :closed_adjudication_output in rule_ids
    assert List.last(prompt.messages).metadata.allbert_prompt.content_class == :operator_input
  end

  test "ReqLLM implementation uses the qualified profile and injectable structured client" do
    assert {:ok,
            %{
              "answer" => "A useful structured answer.",
              "work_units" => []
            }} =
             ReqLLMImplementation.respond(@request, %{@profile | max_tokens: 8_192}, %{
               fanout_manager_phase: :assess,
               req_llm_client: RecordingReqLLM,
               test_pid: self(),
               timeout_ms: 3_000
             })

    assert_received {:req_llm_call, %{provider: :openai, id: "fixture-model"}, prompt, schema,
                     opts}

    assert %ReqLLM.Context{} = prompt
    assert schema[:answer][:required]
    assert schema[:work_units][:required]
    assert {:list, {:map, child_schema}} = schema[:work_units][:type]
    assert child_schema[:title][:required]
    assert child_schema[:objective][:required]
    assert child_schema[:expected_result][:required]
    assert opts[:temperature] == 0.0
    assert opts[:max_tokens] == 1_024
    assert opts[:receive_timeout] == 3_000
    assert opts[:openai_structured_output_mode] == :json_schema
    assert opts[:json_repair] == false
    assert hd(prompt.messages).metadata.allbert_prompt.purpose == :conversation_management
  end

  test "ReqLLM adjudication uses closed policy enums and typed children" do
    assert {:ok,
            %{
              "work_shape" => "independent_advisory",
              "join_role" => "presentation_only",
              "children" => children
            }} =
             ReqLLMImplementation.respond(@request, @profile, %{
               fanout_manager_phase: :adjudicate,
               fanout_candidate_units: work_units(),
               req_llm_client: RecordingAdjudicationReqLLM,
               test_pid: self(),
               timeout_ms: 3_000
             })

    assert length(children) == 2

    assert_received {:adjudication_req_llm_call, _model_spec, prompt, schema, opts}

    assert schema[:work_shape][:type] ==
             {:in,
              ~w[independent_advisory dependent_or_sequential effectful_or_mixed supplied_data single_or_indivisible no_material_leverage ambiguous]}

    assert schema[:join_role][:type] ==
             {:in, ~w[none presentation_only consumes_sibling_result]}

    assert {:list, {:map, child_schema}} = schema[:children][:type]
    assert child_schema[:title][:required]
    assert opts[:json_repair] == false
    assert :closed_adjudication_output in hd(prompt.messages).metadata.allbert_prompt.rule_ids
    refute :closed_assessment_output in hd(prompt.messages).metadata.allbert_prompt.rule_ids
  end

  test "ReqLLM rejects incomplete structured manager output" do
    assert {:error, {:incomplete_manager_response, :length}} =
             ReqLLMImplementation.respond(@request, @profile, %{
               fanout_manager_phase: :assess,
               req_llm_client: TruncatedReqLLM,
               timeout_ms: 3_000
             })
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
      "work_shape" => "independent_advisory",
      "join_role" => "presentation_only",
      "children" => work_units()
    }
  end

  defp assessment_response do
    %{
      "answer" => "I can research both options and compare the findings.",
      "work_units" => work_units()
    }
  end

  defp work_units do
    [
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
    ]
  end
end
