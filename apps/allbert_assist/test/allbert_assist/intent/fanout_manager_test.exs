defmodule AllbertAssist.Intent.FanoutManagerTest do
  use ExUnit.Case, async: false
  @moduletag :app_env_serial

  import ExUnit.CaptureLog, only: [with_log: 1]

  alias AllbertAssist.Actions.Intent.DirectAnswer.Policy, as: DirectAnswerPolicy
  alias AllbertAssist.Intent.FanoutManager.Agent, as: ManagerAgent
  alias AllbertAssist.Intent.FanoutManager.Commands.Adjudicate
  alias AllbertAssist.Intent.FanoutManager.Policy, as: FanoutPolicy
  alias AllbertAssist.Intent.FanoutManager.ReqLLMImplementation
  alias AllbertAssist.Intent.{FanoutManager, FanoutPlan}
  alias AllbertAssist.Models.ProviderAttempt
  alias AllbertAssist.Objectives.Fanout.RoleProfileConfiguration
  alias Jido.Agent.Directive.Error, as: JidoErrorDirective

  defmodule ScriptedModel do
    alias AllbertAssist.Models.ProviderAttempt

    def respond(text, profile, context) do
      :ok = ProviderAttempt.mark(context)
      attempt = Map.fetch!(context, :fanout_manager_attempt)
      send(context.test_pid, {:model_call, attempt, text, profile.name, context.timeout_ms})

      case attempt do
        :initial -> Map.fetch!(context, :initial_response)
        {:repair, _reason} -> Map.fetch!(context, :repair_response)
      end
    end
  end

  defmodule RaisingModel do
    alias AllbertAssist.Models.ProviderAttempt

    def respond(_text, _profile, context) do
      :ok = ProviderAttempt.mark(context)
      send(context.test_pid, {:raising_model_call, context.fanout_manager_attempt})
      raise "provider exploded"
    end
  end

  defmodule SlowModel do
    alias AllbertAssist.Models.ProviderAttempt

    def respond(_text, _profile, context) do
      :ok = ProviderAttempt.mark(context)

      send(
        context.test_pid,
        {:slow_model_call, context.fanout_manager_attempt, System.monotonic_time(:millisecond)}
      )

      Process.sleep(500)
      Map.fetch!(context, :initial_response)
    end
  end

  defmodule OvermarkingModel do
    alias AllbertAssist.Models.ProviderAttempt

    def respond(_text, _profile, context) do
      :ok = ProviderAttempt.mark(context)
      :ok = ProviderAttempt.mark(context)
      {:ok, Map.fetch!(context, :initial_response)}
    end
  end

  defmodule UnmarkedModel do
    def respond(_text, _profile, context),
      do: {:ok, Map.fetch!(context, :initial_response)}
  end

  defmodule RepairPreProviderFailureModel do
    alias AllbertAssist.Models.ProviderAttempt

    def respond(text, profile, %{fanout_manager_attempt: :initial} = context) do
      :ok = ProviderAttempt.mark(context)
      send(context.test_pid, {:model_call, :initial, text, profile.name, context.timeout_ms})
      Map.fetch!(context, :initial_response)
    end

    def respond(_text, _profile, %{fanout_manager_attempt: {:repair, _reason}}),
      do: {:error, :repair_pre_provider_failure}
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

  defmodule FailingReqLLM do
    def generate_object(_model_spec, _prompt, _schema, _opts), do: {:error, :offline}
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
                model_profile_sha256: nil,
                model_profile_configuration_evidence: :injected_client_fixture
              }
            }} = FanoutManager.respond(@request, context)

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
                join_role: :none,
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

  test "repair failure before the provider preserves the one observed attempt" do
    invalid = fanout_response(%{"outer_request_task_count" => 3})

    assert {:ok,
            %{
              kind: :answer,
              diagnostic: %{
                attempts: 1,
                repair_error: {:model_call_failed, :repair_pre_provider_failure}
              }
            }} =
             FanoutManager.respond(
               @request,
               context(
                 model_client: RepairPreProviderFailureModel,
                 initial_response: {:ok, invalid}
               )
             )

    assert_received {:model_call, :initial, @request, "local", _timeout}
    refute_received {:model_call, {:repair, _reason}, _text, _profile, _timeout}
  end

  test "provider overmark and missing marks fail closed without a plan" do
    for {model_client, observed} <- [{OvermarkingModel, 2}, {UnmarkedModel, 0}] do
      assert {:error,
              {:fanout_manager_provider_attempt_mismatch, %{expected: 1, observed: ^observed}}} =
               FanoutManager.respond(
                 @request,
                 context(
                   model_client: model_client,
                   initial_response: fanout_response()
                 )
               )
    end
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
                 timeout_ms: 100,
                 initial_response: {:ok, answer_response("Too late")}
               )
             )

    assert reason in [:fanout_manager_deadline_exhausted, :fanout_manager_command_failed]
    assert_received {:slow_model_call, :initial, model_started_ms}
    assert System.monotonic_time(:millisecond) - model_started_ms < 500
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

    assert_received {:raising_model_call, :initial}
    refute_received {:raising_model_call, _second_attempt}
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

  test "manager planning resolves only its own role" do
    assert {:ok, %{kind: :fanout}} =
             FanoutManager.respond(
               @request,
               context(initial_response: {:ok, fanout_response()})
             )

    assert_received {:model_call, :initial, @request, "local", _timeout}
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
    profile =
      Map.merge(@profile, %{
        provider_base_url: "https://localhost:11434/v1",
        provider_api_key_ref: "secret://providers/local_ollama/api_key",
        provider_api_key: "must-never-enter-provenance"
      })

    binding = FanoutManager.profile_binding(profile)
    synthesis_binding = FanoutManager.profile_binding(:fanout_synthesis, profile)

    assert binding == FanoutManager.profile_binding(Map.new(profile))
    assert binding["name"] == "local"
    assert binding["configuration_sha256"] =~ ~r/^[0-9a-f]{64}$/
    refute binding["configuration_sha256"] == synthesis_binding["configuration_sha256"]
    refute inspect(binding) =~ "fixture-model"
    refute inspect(binding) =~ "must-never-enter-provenance"
    assert FanoutManager.profile_matches?(profile, binding)
    refute FanoutManager.profile_matches?(%{profile | model: "different-model"}, binding)

    refute FanoutManager.profile_matches?(
             %{profile | provider_base_url: "https://localhost:12434/v1"},
             binding
           )

    refute FanoutManager.profile_matches?(
             %{profile | provider_api_key_ref: "secret://providers/other/api_key"},
             binding
           )

    assert FanoutManager.profile_matches?(
             %{profile | provider_api_key: "a-different-secret-value"},
             binding
           )
  end

  test "one closed role configuration binds role and rejects secret-bearing transport input" do
    profile =
      Map.merge(@profile, %{
        provider_base_url: "http://localhost:11434/v1",
        provider_api_key_ref: "secret://providers/local_ollama/api_key"
      })

    transport = %{
      base_url: "http://localhost:11434/v1",
      response_schema_sha256: String.duplicate("a", 64),
      temperature: 0.0,
      max_output_tokens: 1_024,
      receive_timeout_ms: 5_000,
      total_timeout_ms: nil,
      max_retries: 0,
      structured_output_mode: "json_schema",
      json_repair: false
    }

    assert {:ok, manager_digest} =
             RoleProfileConfiguration.digest(:fanout_manager, profile, transport, %{})

    assert {:ok, synthesis_digest} =
             RoleProfileConfiguration.digest(:fanout_synthesis, profile, transport, %{})

    refute manager_digest == synthesis_digest

    assert {:ok, projection} =
             RoleProfileConfiguration.projection(
               :fanout_manager,
               Map.put(profile, :provider_api_key, "resolved-secret-must-not-bind"),
               Map.put(
                 transport,
                 :base_url,
                 "http://operator:embedded-secret@localhost:11434/v1?token=also-secret"
               ),
               %{}
             )

    assert projection["profile"]["effective_endpoint"]["host"] == "localhost"
    refute inspect(projection) =~ "embedded-secret"
    refute inspect(projection) =~ "also-secret"
    refute inspect(projection) =~ "resolved-secret"
    refute inspect(projection) =~ profile.provider_api_key_ref

    secret = "sk-raw-secret-must-not-cross-digest-boundary"

    assert {:error, :invalid_fanout_role_transport} =
             RoleProfileConfiguration.digest(
               :fanout_manager,
               profile,
               Map.put(transport, :api_key, secret),
               %{}
             )

    refute inspect(RoleProfileConfiguration.digest(:fanout_manager, profile, transport, %{})) =~
             secret
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
    {context, counter} =
      ProviderAttempt.attach(%{
        req_llm_client: RecordingReqLLM,
        test_pid: self(),
        timeout_ms: 3_000
      })

    assert {:ok, %{"answer" => "A useful structured answer.", "children" => []}} =
             ReqLLMImplementation.respond(@request, %{@profile | max_tokens: 8_192}, context)

    assert ProviderAttempt.count(counter) == 1

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
    assert opts[:total_timeout] == 3_000
    assert opts[:openai_structured_output_mode] == :json_schema
    assert opts[:json_repair] == false
    assert opts[:max_retries] == 0
    assert hd(prompt.messages).metadata.allbert_prompt.purpose == :conversation_management
  end

  test "exact ReqLLM configuration binds endpoint, deadline, phase, and ordered repairs" do
    previous_base_url = System.get_env("OLLAMA_BASE_URL")

    on_exit(fn ->
      if previous_base_url,
        do: System.put_env("OLLAMA_BASE_URL", previous_base_url),
        else: System.delete_env("OLLAMA_BASE_URL")
    end)

    profile = Map.put(@profile, :provider_base_url, "http://127.0.0.1:11434/v1")

    System.put_env("OLLAMA_BASE_URL", "http://127.0.0.1:12434/v1")

    assert {:ok, initial} =
             ReqLLMImplementation.request_configuration(profile, %{
               timeout_ms: 3_000,
               fanout_manager_attempt: :initial
             })

    assert initial.evidence_source == :production_req_llm
    assert initial.transport.base_url == "http://127.0.0.1:12434/v1"
    assert initial.transport.receive_timeout_ms == 3_000
    assert initial.transport.total_timeout_ms == 3_000
    assert initial.transport.max_retries == 0
    assert initial.transport.structured_output_mode == :json_schema
    assert initial.transport.json_repair == false
    assert initial.protocol == %{"phase" => "initial"}

    assert {:ok, repair} =
             ReqLLMImplementation.request_configuration(profile, %{
               timeout_ms: 750,
               fanout_manager_attempt: {:repair, :invalid_manager_response_keys}
             })

    assert repair.transport.receive_timeout_ms == 750
    assert repair.transport.total_timeout_ms == 750
    assert repair.protocol == %{"phase" => "repair"}

    assert {:ok, initial_digest} =
             RoleProfileConfiguration.digest(
               :fanout_manager,
               profile,
               initial.transport,
               initial.protocol
             )

    assert {:ok, repair_digest} =
             RoleProfileConfiguration.digest(
               :fanout_manager,
               profile,
               repair.transport,
               repair.protocol
             )

    refute initial_digest == repair_digest

    assert {:ok, ordered_digest} =
             RoleProfileConfiguration.attempt_set_digest([initial_digest, repair_digest])

    assert {:ok, reversed_digest} =
             RoleProfileConfiguration.attempt_set_digest([repair_digest, initial_digest])

    refute ordered_digest == reversed_digest

    System.put_env("OLLAMA_BASE_URL", "http://127.0.0.1:13434/v1")

    assert {:ok, changed_endpoint} =
             ReqLLMImplementation.request_configuration(profile, %{
               timeout_ms: 3_000,
               fanout_manager_attempt: :initial
             })

    refute changed_endpoint.transport.base_url == initial.transport.base_url

    assert {:ok, changed_endpoint_digest} =
             RoleProfileConfiguration.digest(
               :fanout_manager,
               profile,
               changed_endpoint.transport,
               changed_endpoint.protocol
             )

    refute changed_endpoint_digest == initial_digest
  end

  test "an injected ReqLLM fixture cannot emit production-exact manager provenance" do
    context =
      context(initial_response: {:ok, answer_response("unused")})
      |> Map.put(:model_client, ReqLLMImplementation)
      |> Map.put(:req_llm_client, RecordingReqLLM)

    assert {:ok,
            %{
              kind: :answer,
              diagnostic: %{
                model_profile_sha256: nil,
                model_profile_configuration_evidence: :injected_client_fixture
              }
            }} = FanoutManager.respond(@request, context)
  end

  test "request configuration evidence never returns resolved credentials" do
    previous_key = System.get_env("OPENAI_API_KEY")
    secret = "sk-manager-provenance-sentinel"
    System.put_env("OPENAI_API_KEY", secret)

    on_exit(fn ->
      if previous_key,
        do: System.put_env("OPENAI_API_KEY", previous_key),
        else: System.delete_env("OPENAI_API_KEY")
    end)

    profile = %{
      name: "hosted-fixture",
      provider: "openai",
      provider_endpoint_kind: "credentialed_remote",
      provider_type: "openai",
      provider_base_url: "https://api.openai.test/v1",
      provider_api_key_ref: "secret://providers/openai/api_key",
      model: "fixture-model",
      max_tokens: 1_024,
      timeout_ms: 3_000
    }

    assert {:ok, configuration} =
             ReqLLMImplementation.request_configuration(profile, %{timeout_ms: 2_000})

    refute Map.has_key?(configuration, :request_opts)
    refute inspect(configuration) =~ secret
    refute inspect(configuration) =~ profile.provider_api_key_ref
    refute inspect(FanoutManager.profile_binding(profile)) =~ secret

    assert {:error, :offline, failed_configuration} =
             ReqLLMImplementation.respond_with_configuration(@request, profile, %{
               req_llm_client: FailingReqLLM,
               timeout_ms: 2_000
             })

    refute Map.has_key?(failed_configuration, :request_opts)
    refute inspect(failed_configuration) =~ secret
    refute inspect(failed_configuration) =~ profile.provider_api_key_ref
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
