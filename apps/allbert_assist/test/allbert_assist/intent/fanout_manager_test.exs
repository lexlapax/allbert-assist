defmodule AllbertAssist.Intent.FanoutManagerTest do
  use ExUnit.Case, async: true
  @moduletag :pure_async

  import ExUnit.CaptureLog, only: [with_log: 1]

  alias AllbertAssist.Actions.Intent.DirectAnswer.Policy, as: DirectAnswerPolicy
  alias AllbertAssist.Intent.{FanoutManager, FanoutPlan}
  alias AllbertAssist.Intent.FanoutManager.Agent, as: ManagerAgent
  alias AllbertAssist.Intent.FanoutManager.Commands.Adjudicate
  alias AllbertAssist.Intent.FanoutManager.Policy, as: FanoutPolicy
  alias AllbertAssist.Intent.FanoutManager.ReqLLMImplementation
  alias Jido.Agent.Directive.Error, as: JidoErrorDirective

  defmodule ScriptedModel do
    def respond(text, profile, context) do
      attempt = Map.fetch!(context, :fanout_manager_attempt)
      send(context.test_pid, {:model_call, attempt, text, profile.name, context.timeout_ms})

      case attempt do
        :initial -> Map.fetch!(context, :initial_response)
        {:repair, _reason} -> Map.fetch!(context, :repair_response)
      end
    end
  end

  defmodule RaisingModel do
    def respond(_text, _profile, _context), do: raise("provider exploded")
  end

  defmodule SlowModel do
    def respond(_text, _profile, context) do
      send(
        context.test_pid,
        {:slow_model_call, context.fanout_manager_attempt, System.monotonic_time(:millisecond)}
      )

      Process.sleep(50)
      Map.fetch!(context, :initial_response)
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
           "outer_request_task_count" => 1,
           "request_ownership" => "no_embedded_content",
           "all_advisory_or_read_only" => true,
           "children_self_contained" => true,
           "can_progress_concurrently" => false,
           "child_result_dependency" => false,
           "full_coverage_exactly_once" => true,
           "material_parallel_leverage" => false,
           "join_role" => "none",
           "children" => []
         }
       }}
    end
  end

  defmodule TruncatedReqLLM do
    def generate_object(_model_spec, _prompt, _schema, _opts) do
      {:ok, %{finish_reason: :length, object: %{}}}
    end
  end

  defmodule MissingFinishReqLLM do
    def generate_object(_model_spec, _prompt, _schema, _opts) do
      {:ok, %{object: %{}}}
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

  test "one qualified call returns an inert ordered plan after local Jido adjudication" do
    context = context(initial_response: {:ok, fanout_response()})

    assert {:ok,
            %{
              kind: :fanout,
              fallback_answer: "I can research both options and compare the findings.",
              plan: %FanoutPlan{} = plan,
              diagnostic: %{
                attempts: 1,
                outcome: :planned,
                policy_outcome: :independent_advisory,
                join_role: :parent_presentation_only,
                work_unit_count: 2,
                failed_criteria: [],
                reviewed?: true,
                phases: [:assessed, :adjudicated],
                semantic_validation: :allbert_policy_decision,
                model_profile: "local",
                model_profile_sha256: profile_digest
              }
            }} = FanoutManager.respond(@request, context)

    assert profile_digest =~ ~r/^[0-9a-f]{64}$/
    assert Enum.map(plan.children, & &1["title"]) == ["Research alpha", "Research beta"]
    assert plan.original_request == @request
    assert_received {:model_call, :initial, @request, "local", _timeout}
    refute_received {:model_call, {:repair, _reason}, _text, _profile, _timeout}
  end

  test "supplied data ownership safely overrides contradictory candidate children" do
    supplied =
      answer_response("The YAML requests archiving logs and restarting the service.")
      |> Map.put("request_ownership", "transform_supplied_content")

    assert {:ok,
            %{
              kind: :answer,
              message: "The YAML requests archiving logs and restarting the service.",
              diagnostic: %{
                attempts: 1,
                outcome: :answered,
                policy_outcome: :supplied_data,
                failed_criteria: [:supplied_text_ownership],
                reviewed?: true
              }
            }} = FanoutManager.respond(@request, context(initial_response: {:ok, supplied}))

    refute_received {:model_call, {:repair, _reason}, _text, _profile, _timeout}
  end

  test "contradictory supplied-data evidence is repaired instead of trusted" do
    contradictory = fanout_response(%{"request_ownership" => "transform_supplied_content"})

    assert {:ok, %{kind: :fanout, diagnostic: %{attempts: 2}}} =
             FanoutManager.respond(
               @request,
               context(
                 initial_response: {:ok, contradictory},
                 repair_response: {:ok, fanout_response()}
               )
             )

    assert_received {:model_call, {:repair, :supplied_data_evidence_conflict}, @request, "local",
                     _timeout}
  end

  test "dependency evidence remains one useful turn" do
    dependent =
      fanout_response(%{
        "can_progress_concurrently" => false,
        "child_result_dependency" => true,
        "join_role" => "child_consumes_sibling_result"
      })

    assert {:ok,
            %{
              kind: :answer,
              diagnostic: %{
                attempts: 1,
                policy_outcome: :dependent_or_sequential,
                join_role: :child_consumes_sibling_result,
                failed_criteria: failures
              }
            }} = FanoutManager.respond(@request, context(initial_response: {:ok, dependent}))

    assert :concurrent_progress in failures
    assert :no_child_result_dependency in failures
    assert :dependency_requires_child_result_consumption in failures
  end

  test "effectful, incomplete, and low-leverage evidence each reject fanout" do
    cases = [
      {"effectful", %{"all_advisory_or_read_only" => false}, :effectful_or_mixed},
      {"incomplete", %{"full_coverage_exactly_once" => false}, :ambiguous},
      {"low leverage", %{"material_parallel_leverage" => false}, :no_material_leverage}
    ]

    Enum.each(cases, fn {_label, overrides, outcome} ->
      response = fanout_response(overrides)

      assert {:ok, %{kind: :answer, diagnostic: %{policy_outcome: ^outcome, attempts: 1}}} =
               FanoutManager.respond(@request, context(initial_response: {:ok, response}))
    end)
  end

  test "ordinary single-task response returns a useful answer without a repair" do
    response = answer_response("Alpha and beta are names used in the supplied request.")

    assert {:ok,
            %{
              kind: :answer,
              message: "Alpha and beta are names used in the supplied request.",
              diagnostic: %{
                attempts: 1,
                outcome: :answered,
                policy_outcome: :single_or_indivisible,
                phases: [:assessed, :adjudicated]
              }
            }} = FanoutManager.respond(@request, context(initial_response: {:ok, response}))

    refute_received {:model_call, {:repair, _reason}, _text, _profile, _timeout}
  end

  test "task-count inconsistency gets one bounded repair and may then admit" do
    invalid = fanout_response(%{"outer_request_task_count" => 3})

    assert {:ok,
            %{
              kind: :fanout,
              diagnostic: %{
                attempts: 2,
                outcome: :planned,
                policy_outcome: :independent_advisory,
                initial_plan_error: :adjudication_task_count_mismatch,
                phases: [:assessed, :adjudicated, :assessed, :adjudicated]
              }
            }} =
             FanoutManager.respond(
               @request,
               context(
                 initial_response: {:ok, invalid},
                 repair_response: {:ok, fanout_response()}
               )
             )

    assert_received {:model_call, :initial, @request, "local", _timeout}

    assert_received {:model_call, {:repair, :adjudication_task_count_mismatch}, @request, "local",
                     _timeout}

    refute_received {:model_call, _third_attempt, _text, _profile, _timeout}
  end

  test "forbidden child fields get one repair through the same closed schema" do
    [first | rest] = work_units()
    invalid_child = Map.put(first, :permission, "allowed")
    invalid = fanout_response(%{"children" => [invalid_child | rest]})

    assert {:ok, %{kind: :fanout, diagnostic: %{attempts: 2}}} =
             FanoutManager.respond(
               @request,
               context(
                 initial_response: {:ok, invalid},
                 repair_response: {:ok, fanout_response()}
               )
             )

    assert_received {:model_call, {:repair, {:invalid_child_keys, 0}}, @request, "local",
                     _timeout}
  end

  test "failed repair retains the initial useful answer and frames nothing" do
    invalid = fanout_response(%{"outer_request_task_count" => 3})

    assert {:ok,
            %{
              kind: :answer,
              message: "I can research both options and compare the findings.",
              diagnostic: %{
                attempts: 2,
                outcome: :answered_after_invalid_plan,
                policy_outcome: :manager_output_invalid,
                plan_error: :adjudication_task_count_mismatch,
                repair_error: {:model_call_failed, :timeout}
              }
            }} =
             FanoutManager.respond(
               @request,
               context(initial_response: {:ok, invalid}, repair_response: {:error, :timeout})
             )
  end

  test "validated overflow returns the complete-list clarification without repair" do
    children =
      for index <- 1..3 do
        %{
          title: "Task #{index}",
          objective: "Research task #{index}.",
          expected_result: "A factual result for task #{index}."
        }
      end

    response =
      fanout_response(%{
        "outer_request_task_count" => 3,
        "children" => children,
        "join_role" => "none"
      })

    assert {:ok,
            %{
              kind: :clarify,
              fallback_answer: "I can research both options and compare the findings.",
              clarification: %{
                task_count: 3,
                max_children: 2,
                tasks: ["Research task 1.", "Research task 2.", "Research task 3."]
              },
              diagnostic: %{attempts: 1, outcome: :overflow}
            }} =
             FanoutManager.respond(
               @request,
               context(max_children_per_fanout: 2, initial_response: {:ok, response})
             )

    refute_received {:model_call, {:repair, _reason}, _text, _profile, _timeout}
  end

  test "one monotonic deadline hard-stops a non-cooperative model" do
    assert {:error, reason} =
             FanoutManager.respond(
               @request,
               context(
                 model_client: SlowModel,
                 timeout_ms: 5,
                 initial_response: {:ok, answer_response("Too late")}
               )
             )

    assert reason in [:fanout_manager_deadline_exhausted, :fanout_manager_command_failed]
    assert_received {:slow_model_call, :initial, model_started_ms}
    assert System.monotonic_time(:millisecond) - model_started_ms < 50
    refute_received {:model_call, {:repair, _reason}, _text, _profile, _timeout}
  end

  test "Jido lifecycle rejects local adjudication before assessment" do
    agent = ManagerAgent.new(id: "invalid-transition")

    {{next_agent, directives}, _log} =
      with_log(fn ->
        ManagerAgent.cmd(
          agent,
          {Adjudicate, %{invoke: fn -> {:ok, :should_not_run} end}},
          __jido_instance__: AllbertAssist.Jido
        )
      end)

    assert next_agent.state.phase == :ready
    assert Enum.any?(directives, &match?(%JidoErrorDirective{}, &1))
  end

  test "malformed answer without a repair answer fails closed" do
    malformed = Map.put(answer_response("valid"), "answer", "")

    assert {:error, {:fanout_manager_failed, _reason}} =
             FanoutManager.respond(
               @request,
               context(initial_response: {:ok, malformed}, repair_response: {:error, :offline})
             )
  end

  test "model exceptions are bounded errors" do
    assert {:error, {:model_call_failed, RuntimeError}} =
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

    refute_received {:model_call, _attempt, _text, _profile, _timeout}
  end

  test "oversized requests fail before an incomplete planning prompt" do
    assert {:error, :request_too_large_for_fanout} =
             FanoutManager.respond(
               String.duplicate("x", 4_001),
               context(initial_response: {:ok, fanout_response()})
             )

    refute_received {:model_call, _attempt, _text, _profile, _timeout}
  end

  test "qualified profile binding is content-free and detects drift" do
    binding = FanoutManager.profile_binding(@profile)

    assert binding == FanoutManager.profile_binding(Map.new(@profile))
    assert binding["name"] == "local"
    assert binding["configuration_sha256"] =~ ~r/^[0-9a-f]{64}$/
    refute inspect(binding) =~ "fixture-model"
    assert FanoutManager.profile_matches?(@profile, binding)
    refute FanoutManager.profile_matches?(%{@profile | model: "different-model"}, binding)
  end

  test "manager prompt derives direct-answer fidelity and one closed fanout rule catalog" do
    assert {:ok, prompt} = ReqLLMImplementation.prompt_context(@request, %{})
    rule_ids = hd(prompt.messages).metadata.allbert_prompt.rule_ids

    assert rule_ids == DirectAnswerPolicy.rule_ids() ++ FanoutPolicy.rule_ids()
    assert :closed_manager_output in rule_ids
    assert List.last(prompt.messages).metadata.allbert_prompt.content_class == :operator_input
  end

  test "repair prompt carries the violated policy invariant rather than an opaque error" do
    assert {:ok, prompt} =
             ReqLLMImplementation.prompt_context(@request, %{
               fanout_manager_attempt: {:repair, :supplied_data_evidence_conflict}
             })

    instruction = Enum.map_join(hd(prompt.messages).content, & &1.text)
    assert instruction =~ "transform_supplied_content"
    assert instruction =~ "perform_requested_operations"
    assert instruction =~ "no children"
  end

  test "ReqLLM uses the qualified profile and explicit typed rule evidence" do
    assert {:ok, %{"answer" => "A useful structured answer.", "children" => []}} =
             ReqLLMImplementation.respond(@request, %{@profile | max_tokens: 8_192}, %{
               req_llm_client: RecordingReqLLM,
               test_pid: self(),
               timeout_ms: 3_000
             })

    assert_received {:req_llm_call, %{provider: :openai, id: "fixture-model"}, prompt, schema,
                     opts}

    assert %ReqLLM.Context{} = prompt
    assert schema[:answer][:required]
    assert schema[:outer_request_task_count][:type] == :integer

    assert schema[:request_ownership][:type] ==
             {:in,
              ~w[no_embedded_content transform_supplied_content perform_requested_operations]}

    assert schema[:all_advisory_or_read_only][:type] == :boolean
    assert schema[:child_result_dependency][:type] == :boolean

    assert schema[:join_role][:type] ==
             {:in, ~w[none parent_presentation_only child_consumes_sibling_result]}

    assert {:list, {:map, child_schema}} = schema[:children][:type]
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

  test "ReqLLM fails closed on incomplete or missing finish reasons" do
    assert {:error, {:incomplete_manager_response, :length}} =
             ReqLLMImplementation.respond(@request, @profile, %{
               req_llm_client: TruncatedReqLLM,
               timeout_ms: 3_000
             })

    assert {:error, :missing_manager_finish_reason} =
             ReqLLMImplementation.respond(@request, @profile, %{
               req_llm_client: MissingFinishReqLLM,
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
      max_children_per_fanout: 8,
      repair_response: {:error, :unexpected_repair}
    })
    |> Map.merge(Map.new(overrides))
  end

  defp answer_response(answer) do
    %{
      "answer" => answer,
      "outer_request_task_count" => 1,
      "request_ownership" => "no_embedded_content",
      "all_advisory_or_read_only" => true,
      "children_self_contained" => true,
      "can_progress_concurrently" => false,
      "child_result_dependency" => false,
      "full_coverage_exactly_once" => true,
      "material_parallel_leverage" => false,
      "join_role" => "none",
      "children" => []
    }
  end

  defp fanout_response(overrides \\ %{}) do
    Map.merge(
      %{
        "answer" => "I can research both options and compare the findings.",
        "outer_request_task_count" => 2,
        "request_ownership" => "no_embedded_content",
        "all_advisory_or_read_only" => true,
        "children_self_contained" => true,
        "can_progress_concurrently" => true,
        "child_result_dependency" => false,
        "full_coverage_exactly_once" => true,
        "material_parallel_leverage" => true,
        "join_role" => "parent_presentation_only",
        "children" => work_units()
      },
      overrides
    )
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
