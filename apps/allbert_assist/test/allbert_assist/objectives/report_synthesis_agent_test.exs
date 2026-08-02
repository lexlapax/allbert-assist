defmodule AllbertAssist.Objectives.Fanout.ReportSynthesisAgentTest do
  use ExUnit.Case, async: true
  @moduletag :pure_async

  alias AllbertAssist.Models.ProviderAttempt
  alias AllbertAssist.Objectives.CanonicalJSON
  alias AllbertAssist.Objectives.Fanout.Budget
  alias AllbertAssist.Objectives.Fanout.Report
  alias AllbertAssist.Objectives.Fanout.Report.SynthesisPolicy
  alias AllbertAssist.Objectives.Fanout.ReportComposer
  alias AllbertAssist.Objectives.Fanout.ReportComposer.ReqLLMImplementation
  alias AllbertAssist.Objectives.Fanout.ReportComposer.SynthesisAgent
  alias AllbertAssist.Objectives.Fanout.ReviewProtocol
  alias AllbertAssist.Objectives.Fanout.RoleProfileConfiguration
  alias AllbertAssist.Objectives.Objective
  alias ReqLLM.Response

  @reviewer_config_aggregate_domain "allbert:fanout-reviewer-config-aggregate:v1\0"

  defmodule AcceptedModel do
    alias AllbertAssist.Models.ProviderAttempt

    def compose(snapshot, _profile, context) do
      :ok = ProviderAttempt.mark(context)
      send(context.test_pid, {:synthesis_provider_call, snapshot})

      {:ok,
       %{
         "sections" => [
           %{"relationship" => "complementary", "ordered_queue_positions" => [0, 1]}
         ],
         "advisory_synthesis" =>
           "Failure isolation limits the process blast radius while durable replay restores the state needed after restart."
       }}
    end
  end

  defmodule SatisfiedCritic do
    alias AllbertAssist.Objectives.Fanout.ReviewRound

    def assess(request, context) do
      :ok = ReviewRound.note_provider_attempt(context)
      send(context.test_pid, {:synthesis_critic_call, request})

      assessments =
        Enum.map(request["group"]["rules"], fn rule ->
          %{
            "rule_id" => rule["id"],
            "status" => "satisfied",
            "source_handles" => ["task_contract", "candidate"]
          }
        end)

      {:ok,
       %{
         assessment: %{
           "group_id" => request["group"]["id"],
           "assessments" => assessments
         },
         reviewer_config_sha256: sha256("synthesis-critic:" <> request["group"]["id"])
       }}
    end

    defp sha256(value) do
      value
      |> then(&:crypto.hash(:sha256, &1))
      |> Base.encode16(case: :lower)
    end
  end

  defmodule RevisionModel do
    alias AllbertAssist.Models.ProviderAttempt

    def compose(snapshot, _profile, context) do
      :ok = ProviderAttempt.mark(context)
      send(context.test_pid, {:initial_synthesis_provider_call, snapshot})

      {:ok,
       %{
         "sections" => [
           %{"relationship" => "complementary", "ordered_queue_positions" => [0, 1]}
         ],
         "advisory_synthesis" => "The observations are related."
       }}
    end

    def revise(snapshot, candidate, rule_ids, _profile, context) do
      :ok = ProviderAttempt.mark(context)
      send(context.test_pid, {:synthesis_revision_call, snapshot, candidate, rule_ids})

      {:ok,
       %{
         "sections" => [
           %{"relationship" => "complementary", "ordered_queue_positions" => [0, 1]}
         ],
         "advisory_synthesis" =>
           "OTP supervision contains live-process failures while replay restores durable state, so together they bound interruption and recovery."
       }}
    end
  end

  defmodule DoubleGenerationAttemptModel do
    alias AllbertAssist.Models.ProviderAttempt

    def compose(snapshot, _profile, context) do
      :ok = ProviderAttempt.mark(context)
      :ok = ProviderAttempt.mark(context)
      send(context.test_pid, {:double_generation_provider_call, snapshot})

      {:ok,
       %{
         "sections" => [
           %{"relationship" => "complementary", "ordered_queue_positions" => [0, 1]}
         ],
         "advisory_synthesis" =>
           "Failure isolation and durable replay complement each other after restart."
       }}
    end
  end

  defmodule DoubleFailedGenerationAttemptModel do
    alias AllbertAssist.Models.ProviderAttempt

    def compose(snapshot, _profile, context) do
      :ok = ProviderAttempt.mark(context)
      :ok = ProviderAttempt.mark(context)
      send(context.test_pid, {:double_failed_generation_provider_call, snapshot})
      {:error, :provider_unavailable}
    end
  end

  defmodule DoubleRevisionAttemptModel do
    alias AllbertAssist.Models.ProviderAttempt

    def compose(snapshot, _profile, context) do
      :ok = ProviderAttempt.mark(context)
      send(context.test_pid, {:double_revision_initial_provider_call, snapshot})

      {:ok,
       %{
         "sections" => [
           %{"relationship" => "complementary", "ordered_queue_positions" => [0, 1]}
         ],
         "advisory_synthesis" => "The observations are related."
       }}
    end

    def revise(snapshot, candidate, rule_ids, _profile, context) do
      :ok = ProviderAttempt.mark(context)
      :ok = ProviderAttempt.mark(context)
      send(context.test_pid, {:double_revision_provider_call, snapshot, candidate, rule_ids})

      {:ok,
       %{
         "sections" => [
           %{"relationship" => "complementary", "ordered_queue_positions" => [0, 1]}
         ],
         "advisory_synthesis" =>
           "OTP supervision contains live failures while replay restores durable state."
       }}
    end
  end

  defmodule RevisionCritic do
    alias AllbertAssist.Objectives.Fanout.ReviewRound

    def assess(request, context) do
      :ok = ReviewRound.note_provider_attempt(context)
      phase = context.review_phase
      send(context.test_pid, {:revision_critic_call, phase, request})

      assessments =
        Enum.map(request["group"]["rules"], fn rule ->
          status =
            if phase == :initial and rule["id"] == "relationship_support",
              do: "violated",
              else: "satisfied"

          %{
            "rule_id" => rule["id"],
            "status" => status,
            "source_handles" => ["task_contract", "candidate"]
          }
        end)

      {:ok,
       %{
         assessment: %{
           "group_id" => request["group"]["id"],
           "assessments" => assessments
         },
         reviewer_config_sha256:
           sha256("synthesis-revision-critic:#{phase}:" <> request["group"]["id"])
       }}
    end

    defp sha256(value) do
      value
      |> then(&:crypto.hash(:sha256, &1))
      |> Base.encode16(case: :lower)
    end
  end

  defmodule PersistentlyViolatedCritic do
    alias AllbertAssist.Objectives.Fanout.ReviewRound

    def assess(request, context) do
      :ok = ReviewRound.note_provider_attempt(context)
      send(context.test_pid, {:persistently_violated_critic_call, context.review_phase})

      assessments =
        Enum.map(request["group"]["rules"], fn rule ->
          %{
            "rule_id" => rule["id"],
            "status" =>
              if(rule["id"] == "relationship_support", do: "violated", else: "satisfied"),
            "source_handles" => ["task_contract", "candidate"]
          }
        end)

      {:ok,
       %{
         assessment: %{
           "group_id" => request["group"]["id"],
           "assessments" => assessments
         },
         reviewer_config_sha256:
           sha256("persistent-critic:#{context.review_phase}:" <> request["group"]["id"])
       }}
    end

    defp sha256(value) do
      value
      |> then(&:crypto.hash(:sha256, &1))
      |> Base.encode16(case: :lower)
    end
  end

  defmodule MalformedCritic do
    alias AllbertAssist.Objectives.Fanout.ReviewRound

    def assess(request, context) do
      :ok = ReviewRound.note_provider_attempt(context)
      send(context.test_pid, {:malformed_critic_call, request["group"]["id"]})

      {:ok,
       %{
         assessment: %{
           "group_id" => request["group"]["id"],
           "assessments" => []
         },
         reviewer_config_sha256: sha256("malformed-critic:" <> request["group"]["id"])
       }}
    end

    defp sha256(value) do
      value
      |> then(&:crypto.hash(:sha256, &1))
      |> Base.encode16(case: :lower)
    end
  end

  defmodule MissingCritic do
  end

  defmodule OverAttemptCritic do
    alias AllbertAssist.Objectives.Fanout.ReviewRound

    def assess(request, context) do
      :ok = ReviewRound.note_provider_attempt(context)
      :ok = ReviewRound.note_provider_attempt(context)
      send(context.test_pid, {:over_attempt_critic_call, context.review_phase})

      {:ok,
       %{
         assessment: satisfied_assessment(request),
         reviewer_config_sha256: sha256("over-attempt:" <> request["group"]["id"])
       }}
    end

    defp satisfied_assessment(request) do
      %{
        "group_id" => request["group"]["id"],
        "assessments" =>
          Enum.map(request["group"]["rules"], fn rule ->
            %{
              "rule_id" => rule["id"],
              "status" => "satisfied",
              "source_handles" => ["task_contract", "candidate"]
            }
          end)
      }
    end

    defp sha256(value) do
      value
      |> then(&:crypto.hash(:sha256, &1))
      |> Base.encode16(case: :lower)
    end
  end

  defmodule FinalOverAttemptCritic do
    alias AllbertAssist.Objectives.Fanout.ReviewRound

    def assess(request, context) do
      attempt_count = if(context.review_phase == :final, do: 2, else: 1)

      Enum.each(1..attempt_count, fn _attempt ->
        :ok = ReviewRound.note_provider_attempt(context)
      end)

      send(context.test_pid, {:final_over_attempt_critic_call, context.review_phase})

      assessments =
        Enum.map(request["group"]["rules"], fn rule ->
          status =
            if context.review_phase == :initial and rule["id"] == "relationship_support",
              do: "violated",
              else: "satisfied"

          %{
            "rule_id" => rule["id"],
            "status" => status,
            "source_handles" => ["task_contract", "candidate"]
          }
        end)

      {:ok,
       %{
         assessment: %{
           "group_id" => request["group"]["id"],
           "assessments" => assessments
         },
         reviewer_config_sha256:
           sha256("final-over-attempt:#{context.review_phase}:" <> request["group"]["id"])
       }}
    end

    defp sha256(value) do
      value
      |> then(&:crypto.hash(:sha256, &1))
      |> Base.encode16(case: :lower)
    end
  end

  defmodule LocallyRejectedModel do
    alias AllbertAssist.Models.ProviderAttempt

    def compose(snapshot, _profile, context) do
      :ok = ProviderAttempt.mark(context)
      send(context.test_pid, {:locally_rejected_provider_call, snapshot})

      {:ok,
       %{
         "sections" => [
           %{"relationship" => "complementary", "ordered_queue_positions" => [0, 1]}
         ],
         "advisory_synthesis" =>
           "The provider returned this unredacted token: " <>
             "AIzaSyDUMMYSecretShapeForAudit59"
       }}
    end
  end

  defmodule SlowModel do
    alias AllbertAssist.Models.ProviderAttempt

    def compose(snapshot, _profile, context) do
      :ok = ProviderAttempt.mark(context)
      send(context.test_pid, {:slow_synthesis_provider_call, self(), snapshot})
      Process.sleep(1_000)

      {:ok,
       %{
         "sections" => [
           %{"relationship" => "complementary", "ordered_queue_positions" => [0, 1]}
         ],
         "advisory_synthesis" =>
           "Failure isolation and durable replay complement each other after restart."
       }}
    end
  end

  defmodule StructurallyRejectedModel do
    alias AllbertAssist.Models.ProviderAttempt

    def compose(snapshot, _profile, context) do
      :ok = ProviderAttempt.mark(context)

      send(
        context.test_pid,
        {:structurally_rejected_provider_call, context.rejection, snapshot}
      )

      {:ok,
       %{
         "sections" => sections(context.rejection),
         "advisory_synthesis" =>
           "Failure isolation and durable replay complement each other after restart."
       }}
    end

    defp sections(:duplicate_position) do
      [
        %{"relationship" => "independent", "ordered_queue_positions" => [0]},
        %{"relationship" => "independent", "ordered_queue_positions" => [0]}
      ]
    end

    defp sections(:missing_position),
      do: [%{"relationship" => "independent", "ordered_queue_positions" => [0]}]

    defp sections(:invalid_relationship_cardinality),
      do: [%{"relationship" => "supporting", "ordered_queue_positions" => [0]}]
  end

  defmodule CaptureReqLLM do
    def generate_object(spec, prompt, schema, opts) do
      send(Keyword.fetch!(opts, :test_pid), {:req_llm_synthesis, spec, prompt, schema, opts})

      {:ok,
       %Response{
         id: "fanout-synthesis",
         model: "fixture-model",
         context: prompt,
         object: %{
           "sections" => [
             %{"relationship" => "complementary", "ordered_queue_positions" => [0, 1]}
           ],
           "advisory_synthesis" =>
             "Failure isolation and durable replay complement each other at restart."
         },
         finish_reason: :stop
       }}
    end
  end

  defmodule CaptureRevisionReqLLM do
    def generate_object(spec, prompt, schema, opts) do
      send(
        Keyword.fetch!(opts, :test_pid),
        {:req_llm_synthesis_revision, spec, prompt, schema, opts}
      )

      {:ok,
       %Response{
         id: "fanout-synthesis-revision",
         model: "fixture-model",
         context: prompt,
         object: %{
           "sections" => [
             %{"relationship" => "complementary", "ordered_queue_positions" => [0, 1]}
           ],
           "advisory_synthesis" => "The revised synthesis explains the supported relationship."
         },
         finish_reason: :stop
       }}
    end
  end

  defmodule MissingFinishReqLLM do
    def generate_object(_spec, prompt, _schema, _opts) do
      {:ok,
       %Response{
         id: "missing-finish",
         model: "fixture-model",
         context: prompt,
         object: %{},
         finish_reason: nil
       }}
    end
  end

  defmodule TruncatedReqLLM do
    def generate_object(_spec, prompt, _schema, _opts) do
      {:ok,
       %Response{
         id: "truncated",
         model: "fixture-model",
         context: prompt,
         object: %{},
         finish_reason: :length
       }}
    end
  end

  defmodule RaisingReqLLM do
    def generate_object(_spec, _prompt, _schema, opts) do
      send(Keyword.fetch!(opts, :test_pid), {:provider_boundary_fault, :raise, self()})
      raise "fixture provider exception"
    end
  end

  defmodule ExitingReqLLM do
    def generate_object(_spec, _prompt, _schema, opts) do
      send(Keyword.fetch!(opts, :test_pid), {:provider_boundary_fault, :exit, self()})
      exit(:fixture_provider_exit)
    end
  end

  defmodule MissingReqLLMClient do
  end

  defmodule LocalFaultModel do
    def compose(snapshot, _profile, context) do
      send(context.test_pid, {:local_synthesis_fault_ready, self(), snapshot})

      receive do
        :trigger_local_synthesis_fault -> :ok
      end

      _missing = Map.fetch!(context, :missing_prepared_provider_option)
      {:error, :unreachable_local_synthesis_result}
    end
  end

  defmodule MustNotCallModel do
    def compose(_snapshot, _profile, context) do
      send(context.test_pid, :unexpected_synthesis_provider_call)
      {:error, :unexpected_synthesis_provider_call}
    end
  end

  defmodule ProcessStore do
    def recover_composition(agent), do: {:ok, Agent.get(agent, fn _state -> 0 end)}

    def claim_next_composition(agent) do
      Agent.get_and_update(agent, fn
        %{claims: [claim | rest]} = state -> {{:ok, claim}, %{state | claims: rest}}
        %{claims: []} = state -> {:none, state}
      end)
    end

    def select_composition(agent, claim, source, body, provenance) do
      Agent.update(
        agent,
        &Map.update!(&1, :selected, fn selected ->
          [{claim, source, body, provenance} | selected]
        end)
      )

      {:ok, claim.parent}
    end
  end

  defmodule RecoveringProcessStore do
    alias AllbertAssist.Objectives.Fanout.Report

    def recover_composition(agent) do
      Agent.get_and_update(agent, fn
        %{inflight: claim, selected: []} = state when is_map(claim) ->
          {:ok, provenance} =
            Report.fallback_provenance(claim.frozen.snapshot, "recovery_after_restart")

          selection =
            {claim, "deterministic_fallback", claim.frozen.fallback_body, provenance}

          {{:ok, 1}, %{state | inflight: nil, selected: [selection]}}

        state ->
          {{:ok, 0}, state}
      end)
    end

    def claim_next_composition(agent) do
      Agent.get_and_update(agent, fn
        %{claimed?: false, claim: claim} = state ->
          {{:ok, claim}, %{state | claimed?: true, inflight: claim}}

        state ->
          {:none, state}
      end)
    end

    def select_composition(agent, claim, source, body, provenance) do
      Agent.update(agent, fn state ->
        %{state | inflight: nil, selected: [{claim, source, body, provenance}]}
      end)

      {:ok, claim.parent}
    end
  end

  defmodule ProcessModels do
    def for(:fanout_synthesis, _context), do: {:ok, %{profile: profile()}}

    defp profile do
      %{
        name: "direct_answer_local",
        provider: "local_ollama",
        provider_type: "openai_compatible",
        model: "qwen2.5:7b",
        max_tokens: 1_024,
        timeout_ms: 60_000
      }
    end
  end

  defmodule AllowDisclosure do
    def authorize_transport(_profile, _context), do: :ok
  end

  test "one generated synthesis is accepted only after two disjoint critics approve exact bytes" do
    snapshot = snapshot()

    assert {:ok, prepared} =
             SynthesisAgent.run(
               snapshot,
               %{name: "direct_answer_local"},
               %{test_pid: self(), critic_implementation: SatisfiedCritic},
               AcceptedModel,
               5_000
             )

    assert prepared.layout.layout_version == 2
    assert prepared.synthesis_contract_version == 2
    assert prepared.review_verdict == "accepted"
    assert prepared.reviewed_queue_positions == [0, 1]
    assert prepared.review_protocol_version == 1
    assert prepared.critic_group_count == 2
    assert prepared.rule_group_catalog_version == 1
    assert prepared.generation_call_count == 1
    assert prepared.initial_critic_call_count == 2
    assert prepared.revision_call_count == 0
    assert prepared.final_critic_call_count == 0
    assert prepared.provider_call_count == 3
    assert prepared.final_assessment_sha256 == nil
    assert prepared.accepted_assessment_sha256 == prepared.initial_assessment_sha256
    assert prepared.generation_configuration_sha256 == nil
    assert prepared.revision_configuration_sha256 == nil
    assert prepared.body =~ "Model-authored advisory synthesis:"
    assert_receive {:synthesis_provider_call, ^snapshot}

    requests =
      for _index <- 1..2 do
        assert_receive {:synthesis_critic_call, request}
        request
      end

    assert Enum.sort(Enum.map(requests, & &1["group"]["id"])) ==
             ~w[coverage_relationship integrity_authority]

    initial_reviewer_config =
      review_round_config_sha256(fn group_id ->
        sha256("synthesis-critic:" <> group_id)
      end)

    assert {:ok, expected_reviewer_config} =
             SynthesisPolicy.reviewer_config_set_sha256(initial_reviewer_config)

    assert prepared.reviewer_config_sha256 == expected_reviewer_config

    {:ok, source_contract} = Report.composition_input(snapshot)

    expected_source = CanonicalJSON.encode(source_contract)

    expected_candidate =
      CanonicalJSON.encode(%{
        "sections" => [
          %{"relationship" => "complementary", "ordered_queue_positions" => [0, 1]}
        ],
        "advisory_synthesis" =>
          "Failure isolation limits the process blast radius while durable replay restores the state needed after restart."
      })

    assert Enum.all?(requests, fn request ->
             request["sources"]["task_contract"]["content"] == expected_source and
               request["sources"]["candidate"]["content"] == expected_candidate
           end)

    refute_receive {:synthesis_provider_call, _snapshot}
  end

  test "a double-marked generation is rejected with the exact physical count" do
    assert {:error,
            {:fanout_synthesis_provider_attempt_mismatch,
             %{
               expected: %{total: 1, generation: 1, revision: 0},
               observed: %{total: 2, generation: 2, revision: 0}
             }}} =
             SynthesisAgent.run(
               snapshot(),
               profile(),
               %{test_pid: self(), critic_implementation: SatisfiedCritic},
               DoubleGenerationAttemptModel,
               5_000
             )

    assert_receive {:double_generation_provider_call, _snapshot}
    assert_receive {:synthesis_critic_call, _request}
    assert_receive {:synthesis_critic_call, _request}
  end

  test "a double-marked failed generation cannot pass as an ordinary provider failure" do
    assert {:error,
            {:fanout_synthesis_provider_attempt_mismatch,
             %{
               expected: :ordered_single_attempt_per_phase,
               observed: %{total: 2, generation: 2, revision: 0}
             }}} =
             SynthesisAgent.run(
               snapshot(),
               profile(),
               %{test_pid: self(), critic_implementation: SatisfiedCritic},
               DoubleFailedGenerationAttemptModel,
               5_000
             )

    assert_receive {:double_failed_generation_provider_call, _snapshot}
    refute_receive {:synthesis_critic_call, _request}
  end

  test "an absolute synthesis deadline is exhausted at equality before awaiting" do
    base = System.monotonic_time(:millisecond)
    monotonic_now = sequence_clock([base, base + 5_000])

    assert {:error, :fanout_synthesis_timeout} =
             SynthesisAgent.run(
               snapshot(),
               profile(),
               %{
                 test_pid: self(),
                 critic_implementation: SatisfiedCritic,
                 synthesis_monotonic_now: monotonic_now
               },
               SlowModel,
               5_000
             )

    refute_receive {:synthesis_critic_call, _request}
  end

  test "a completed synthesis is accepted only when the post-result clock is before deadline" do
    base = System.monotonic_time(:millisecond)
    monotonic_now = sequence_clock([base, base, base + 4_999])

    assert {:ok, _prepared} =
             SynthesisAgent.run(
               snapshot(),
               profile(),
               %{
                 test_pid: self(),
                 critic_implementation: SatisfiedCritic,
                 synthesis_monotonic_now: monotonic_now
               },
               AcceptedModel,
               5_000
             )

    assert_receive {:synthesis_provider_call, _snapshot}
    assert_receive {:synthesis_critic_call, _request}
    assert_receive {:synthesis_critic_call, _request}
  end

  test "a completed synthesis is rejected when the post-result clock equals deadline" do
    base = System.monotonic_time(:millisecond)
    monotonic_now = sequence_clock([base, base, base + 5_000])

    assert {:error, :fanout_synthesis_timeout} =
             SynthesisAgent.run(
               snapshot(),
               profile(),
               %{
                 test_pid: self(),
                 critic_implementation: SatisfiedCritic,
                 synthesis_monotonic_now: monotonic_now
               },
               AcceptedModel,
               5_000
             )

    assert_receive {:synthesis_provider_call, _snapshot}
    assert_receive {:synthesis_critic_call, _request}
    assert_receive {:synthesis_critic_call, _request}
  end

  test "production adapter configuration evidence remains transient through synthesis" do
    assert {:ok, prepared} =
             SynthesisAgent.run(
               snapshot(),
               profile(),
               %{
                 test_pid: self(),
                 critic_implementation: SatisfiedCritic,
                 req_llm_client: CaptureReqLLM,
                 max_output_tokens: 1_024
               },
               ReqLLMImplementation,
               5_000
             )

    assert prepared.generation_configuration_sha256 =~ ~r/^[0-9a-f]{64}$/
    assert prepared.revision_configuration_sha256 == nil
    assert_receive {:req_llm_synthesis, _, _, _, _}
    assert_receive {:synthesis_critic_call, _request}
    assert_receive {:synthesis_critic_call, _request}
    refute_receive {:req_llm_synthesis, _, _, _, _}
  end

  test "one violated rule permits one revision followed by a fresh two-critic verification" do
    snapshot = snapshot()

    assert {:ok, prepared} =
             SynthesisAgent.run(
               snapshot,
               %{name: "direct_answer_local"},
               %{test_pid: self(), critic_implementation: RevisionCritic},
               RevisionModel,
               5_000
             )

    assert prepared.synthesis_contract_version == 2
    assert prepared.generation_call_count == 1
    assert prepared.initial_critic_call_count == 2
    assert prepared.revision_call_count == 1
    assert prepared.final_critic_call_count == 2
    assert prepared.provider_call_count == 6
    assert prepared.initial_assessment_sha256 != prepared.final_assessment_sha256
    assert prepared.accepted_assessment_sha256 == prepared.final_assessment_sha256

    assert prepared.body =~
             "OTP supervision contains live-process failures while replay restores durable state"

    assert_receive {:initial_synthesis_provider_call, ^snapshot}

    assert_receive {:synthesis_revision_call, ^snapshot, initial_candidate,
                    ["relationship_support"]}

    assert initial_candidate ==
             CanonicalJSON.encode(%{
               "sections" => [
                 %{
                   "relationship" => "complementary",
                   "ordered_queue_positions" => [0, 1]
                 }
               ],
               "advisory_synthesis" => "The observations are related."
             })

    calls =
      for _index <- 1..4 do
        assert_receive {:revision_critic_call, phase, request}
        {phase, request}
      end

    assert Enum.frequencies_by(calls, &elem(&1, 0)) == %{initial: 2, final: 2}

    initial_reviewer_config =
      review_round_config_sha256(fn group_id ->
        sha256("synthesis-revision-critic:initial:" <> group_id)
      end)

    final_reviewer_config =
      review_round_config_sha256(fn group_id ->
        sha256("synthesis-revision-critic:final:" <> group_id)
      end)

    assert initial_reviewer_config != final_reviewer_config

    assert {:ok, expected_reviewer_config} =
             SynthesisPolicy.reviewer_config_set_sha256(
               initial_reviewer_config,
               final_reviewer_config
             )

    assert prepared.reviewer_config_sha256 == expected_reviewer_config
    tampered_initial_config = sha256("tampered-initial-reviewer-config")

    assert {:ok, tampered_reviewer_config} =
             SynthesisPolicy.reviewer_config_set_sha256(
               tampered_initial_config,
               final_reviewer_config
             )

    refute tampered_reviewer_config == prepared.reviewer_config_sha256

    assert {:error, :invalid_synthesis_reviewer_config} =
             SynthesisPolicy.reviewer_config_set_sha256(
               String.upcase(initial_reviewer_config),
               final_reviewer_config
             )

    initial_candidates =
      calls
      |> Enum.filter(&(elem(&1, 0) == :initial))
      |> Enum.map(&elem(&1, 1)["sources"]["candidate"]["content"])
      |> Enum.uniq()

    final_candidates =
      calls
      |> Enum.filter(&(elem(&1, 0) == :final))
      |> Enum.map(&elem(&1, 1)["sources"]["candidate"]["content"])
      |> Enum.uniq()

    assert initial_candidates == [initial_candidate]
    assert length(final_candidates) == 1
    refute final_candidates == initial_candidates
  end

  test "a double-marked revision is rejected with the exact physical count" do
    assert {:error,
            {:fanout_synthesis_provider_attempt_mismatch,
             %{
               expected: %{total: 2, generation: 1, revision: 1},
               observed: %{total: 3, generation: 1, revision: 2}
             }}} =
             SynthesisAgent.run(
               snapshot(),
               profile(),
               %{test_pid: self(), critic_implementation: RevisionCritic},
               DoubleRevisionAttemptModel,
               5_000
             )

    assert_receive {:double_revision_initial_provider_call, _snapshot}

    assert_receive {:double_revision_provider_call, _snapshot, _candidate,
                    ["relationship_support"]}

    for _index <- 1..4 do
      assert_receive {:revision_critic_call, _phase, _request}
    end
  end

  test "ReqLLM generation requests candidate bytes without a self-review verdict" do
    assert {:ok,
            %{
              candidate: %{
                "sections" => [_section],
                "advisory_synthesis" => synthesis
              },
              configuration_sha256: configuration_sha256
            }} =
             ReqLLMImplementation.compose_with_provenance(snapshot(), profile(), %{
               req_llm_client: CaptureReqLLM,
               test_pid: self(),
               timeout_ms: 5_000,
               max_output_tokens: 1_024
             })

    assert synthesis =~ "Failure isolation"

    assert_receive {:req_llm_synthesis, %{provider: :openai, id: "qwen2.5:7b"}, prompt, schema,
                    opts}

    assert schema["type"] == "object"
    assert schema["required"] == ~w[sections advisory_synthesis]
    assert schema["additionalProperties"] == false
    assert {:ok, %{schema: ^schema, compiled: nil}} = ReqLLM.Schema.compile(schema)

    refute Map.has_key?(schema["properties"], "review")

    assert opts[:temperature] == 0.0
    assert opts[:json_repair] == false
    assert opts[:max_retries] == 0

    assert {:ok, expected_configuration_sha256} =
             RoleProfileConfiguration.digest(
               :fanout_synthesis,
               profile(),
               synthesis_transport(schema, opts),
               synthesis_extras(:generation)
             )

    assert configuration_sha256 == expected_configuration_sha256

    metadata = List.last(prompt.messages).metadata.allbert_prompt
    assert metadata.schema_version == 2
    assert metadata.purpose == :fanout_report_synthesis_generation
    assert metadata.rule_ids == SynthesisPolicy.prompt_rule_ids()
    refute_receive {:req_llm_synthesis, _, _, _, _}
  end

  test "ReqLLM revision receives only exact source, candidate, and typed rule feedback" do
    {:ok, projection} = Report.composition_input(snapshot())
    source_contract = CanonicalJSON.encode(projection)

    candidate =
      CanonicalJSON.encode(%{
        "sections" => [
          %{"relationship" => "complementary", "ordered_queue_positions" => [0, 1]}
        ],
        "advisory_synthesis" => "The observations are related."
      })

    assert {:ok,
            %{
              candidate: %{"advisory_synthesis" => revised},
              configuration_sha256: configuration_sha256
            }} =
             ReqLLMImplementation.revise_with_provenance(
               snapshot(),
               candidate,
               ["relationship_support"],
               profile(),
               %{
                 req_llm_client: CaptureRevisionReqLLM,
                 test_pid: self(),
                 timeout_ms: 5_000,
                 max_output_tokens: 1_024
               }
             )

    assert revised =~ "supported relationship"

    assert_receive {:req_llm_synthesis_revision, %{provider: :openai, id: "qwen2.5:7b"}, prompt,
                    schema, opts}

    assert schema["required"] == ~w[sections advisory_synthesis]
    assert opts[:max_retries] == 0
    assert opts[:total_timeout] == 5_000

    assert {:ok, expected_configuration_sha256} =
             RoleProfileConfiguration.digest(
               :fanout_synthesis,
               profile(),
               synthesis_transport(schema, opts),
               synthesis_extras(:revision, ["relationship_support"])
             )

    assert configuration_sha256 == expected_configuration_sha256

    assert List.last(prompt.messages).metadata.allbert_prompt.purpose ==
             :fanout_report_synthesis_revision

    assert List.last(prompt.messages).metadata.allbert_prompt.rule_ids == [
             :relationship_support
           ]

    assert Jason.decode!(message_text(List.last(prompt.messages))) == %{
             "task_contract" => source_contract,
             "candidate" => candidate,
             "revision_rule_ids" => ["relationship_support"]
           }

    refute_receive {:req_llm_synthesis_revision, _, _, _, _}
  end

  test "a still-violated revised candidate closes as phase-review fallback, never model success" do
    assert {:error, {:phase_review_unresolved, :final_verification_failed}} =
             SynthesisAgent.run(
               snapshot(),
               profile(),
               %{
                 test_pid: self(),
                 critic_implementation: PersistentlyViolatedCritic
               },
               RevisionModel,
               5_000
             )

    assert_receive {:initial_synthesis_provider_call, _snapshot}
    assert_receive {:synthesis_revision_call, _snapshot, _candidate, ["relationship_support"]}

    phases =
      for _index <- 1..4 do
        assert_receive {:persistently_violated_critic_call, phase}
        phase
      end

    assert Enum.frequencies(phases) == %{initial: 2, final: 2}

    assert {:ok, provenance} =
             Report.fallback_provenance(snapshot(), :phase_review_unresolved)

    assert provenance.fallback_reason == "phase_review_unresolved"
    assert provenance.synthesis_outcome == "unresolved"
  end

  test "malformed critic evidence closes with only content-free attempted-call detail" do
    assert {:error,
            {:phase_review_unresolved,
             %{reason: :phase_review_failed, provider_call_count: provider_call_count}}} =
             SynthesisAgent.run(
               snapshot(),
               profile(),
               %{test_pid: self(), critic_implementation: MalformedCritic},
               AcceptedModel,
               5_000
             )

    assert provider_call_count in 2..3
    assert_receive {:synthesis_provider_call, _snapshot}
    assert_receive {:malformed_critic_call, _group_id}
    refute_receive {:synthesis_revision_call, _, _, _}
  end

  test "critic failure before egress includes the completed generation call" do
    assert {:error,
            {:phase_review_unresolved, %{reason: :phase_review_failed, provider_call_count: 1}}} =
             SynthesisAgent.run(
               snapshot(),
               profile(),
               %{test_pid: self(), critic_implementation: MissingCritic},
               AcceptedModel,
               5_000
             )

    assert_receive {:synthesis_provider_call, _snapshot}
    refute_receive {:synthesis_critic_call, _request}
  end

  test "initial review over-attempt closes with its exact physical provider call count" do
    assert {:error,
            {:phase_review_unresolved,
             %{
               phase: :initial,
               reason: :quality_provider_attempt_bound_exceeded,
               provider_call_count: 5
             }}} =
             SynthesisAgent.run(
               snapshot(),
               profile(),
               %{test_pid: self(), critic_implementation: OverAttemptCritic},
               AcceptedModel,
               5_000
             )

    assert_receive {:synthesis_provider_call, _snapshot}
    assert_receive {:over_attempt_critic_call, :initial}
    assert_receive {:over_attempt_critic_call, :initial}
    refute_receive {:synthesis_revision_call, _, _, _}
  end

  test "final review over-attempt includes generation, initial review, and revision calls" do
    assert {:error,
            {:phase_review_unresolved,
             %{
               phase: :final,
               reason: :quality_provider_attempt_bound_exceeded,
               provider_call_count: 8
             }}} =
             SynthesisAgent.run(
               snapshot(),
               profile(),
               %{test_pid: self(), critic_implementation: FinalOverAttemptCritic},
               RevisionModel,
               5_000
             )

    assert_receive {:initial_synthesis_provider_call, _snapshot}
    assert_receive {:synthesis_revision_call, _snapshot, _candidate, ["relationship_support"]}

    assert_receive {:final_over_attempt_critic_call, :initial}
    assert_receive {:final_over_attempt_critic_call, :initial}
    assert_receive {:final_over_attempt_critic_call, :final}
    assert_receive {:final_over_attempt_critic_call, :final}
  end

  test "oversized full Unicode join request closes before the provider boundary" do
    trailing_guidance = "FINAL-JOIN-GUIDANCE"

    oversized_snapshot = %{
      snapshot()
      | original_request:
          String.duplicate("👩‍💻", 4_000 - String.length(trailing_guidance)) <>
            trailing_guidance,
        children:
          Enum.map(snapshot().children, fn child ->
            %{child | objective: String.duplicate("界", 4_000)}
          end)
    }

    assert {:error, :fanout_composition_input_too_large} =
             SynthesisAgent.run(
               oversized_snapshot,
               %{name: "direct_answer_local"},
               %{test_pid: self()},
               MustNotCallModel,
               5_000
             )

    refute_receive :unexpected_synthesis_provider_call
  end

  test "ReqLLM synthesis requires an explicit complete finish reason" do
    context = %{timeout_ms: 5_000, max_output_tokens: 1_024}

    assert {:error, {:invalid_model_output, :missing_composition_finish_reason}} =
             ReqLLMImplementation.compose(
               snapshot(),
               profile(),
               Map.put(context, :req_llm_client, MissingFinishReqLLM)
             )

    assert {:error, {:invalid_model_output, {:incomplete_composition_response, :length}}} =
             ReqLLMImplementation.compose(
               snapshot(),
               profile(),
               Map.put(context, :req_llm_client, TruncatedReqLLM)
             )
  end

  test "ReqLLM catches only provider-boundary raises and exits" do
    Enum.each([raise: RaisingReqLLM, exit: ExitingReqLLM], fn {kind, req_llm_client} ->
      claim = claim()

      store =
        start_supervised!(
          Supervisor.child_spec(
            {Agent, fn -> %{claims: [claim], selected: []} end},
            id: {:provider_boundary_store, kind}
          )
        )

      name = :"report-synthesis-provider-#{kind}-#{System.unique_integer([:positive])}"

      start_supervised!(
        Supervisor.child_spec(
          {ReportComposer,
           name: name,
           store: {ProcessStore, store},
           models: ProcessModels,
           disclosure: AllowDisclosure,
           model_client: ReqLLMImplementation,
           model_enabled?: true,
           model_context: %{test_pid: self(), req_llm_client: req_llm_client},
           reconcile_interval_ms: 5_000},
          id: {:provider_boundary_composer, kind}
        )
      )

      assert_receive {:provider_boundary_fault, ^kind, lifecycle_pid}
      assert lifecycle_pid != Process.whereis(name)
      assert eventually(fn -> Agent.get(store, &match?([_selection], &1.selected)) end)

      [{^claim, "deterministic_fallback", body, provenance}] =
        Agent.get(store, & &1.selected)

      assert body == claim.frozen.fallback_body

      assert provenance == %{
               fallback_reason: "provider_failed",
               layout_version: 2,
               synthesis_contract_version: SynthesisPolicy.version(),
               synthesis_outcome: "unresolved"
             }

      assert Process.alive?(Process.whereis(name))
      refute_receive {:provider_boundary_fault, ^kind, _pid}
    end)

    assert_raise KeyError, fn ->
      ReqLLMImplementation.compose(snapshot(), profile(), %{req_llm_client: CaptureReqLLM})
    end

    refute_receive {:req_llm_synthesis, _, _, _, _}
  end

  test "unavailable ReqLLM boundary records profile unavailable without a provider call" do
    claim = claim()
    store = start_supervised!({Agent, fn -> %{claims: [claim], selected: []} end})
    name = :"report-synthesis-profile-unavailable-#{System.unique_integer([:positive])}"

    start_supervised!(
      {ReportComposer,
       name: name,
       store: {ProcessStore, store},
       models: ProcessModels,
       disclosure: AllowDisclosure,
       model_client: ReqLLMImplementation,
       model_enabled?: true,
       model_context: %{test_pid: self(), req_llm_client: MissingReqLLMClient},
       reconcile_interval_ms: 5_000}
    )

    assert eventually(fn -> Agent.get(store, &match?([_selection], &1.selected)) end)

    [{^claim, "deterministic_fallback", body, provenance}] =
      Agent.get(store, & &1.selected)

    assert body == claim.frozen.fallback_body

    assert provenance == %{
             fallback_reason: "profile_unavailable",
             layout_version: 2,
             synthesis_contract_version: SynthesisPolicy.version(),
             synthesis_outcome: "not_run"
           }

    refute_receive {:req_llm_synthesis, _, _, _, _}
    refute_receive {:provider_boundary_fault, _, _}
  end

  test "local synthesis programming fault crashes visibly and restart recovery selects fallback" do
    claim = claim()

    store =
      start_supervised!(
        {Agent,
         fn ->
           %{claim: claim, claimed?: false, inflight: nil, selected: []}
         end}
      )

    name = :"report-synthesis-local-fault-#{System.unique_integer([:positive])}"

    composer_pid =
      start_supervised!(
        {ReportComposer,
         name: name,
         store: {RecoveringProcessStore, store},
         models: ProcessModels,
         disclosure: AllowDisclosure,
         model_client: LocalFaultModel,
         model_enabled?: true,
         model_context: %{test_pid: self()},
         reconcile_interval_ms: 5_000}
      )

    assert_receive {:local_synthesis_fault_ready, lifecycle_pid, snapshot}
    assert snapshot == claim.frozen.snapshot
    composer_monitor = Process.monitor(composer_pid)

    ExUnit.CaptureLog.capture_log(fn ->
      send(lifecycle_pid, :trigger_local_synthesis_fault)
      assert_receive {:DOWN, ^composer_monitor, :process, ^composer_pid, _reason}, 1_000

      assert eventually(fn ->
               case Process.whereis(name) do
                 pid when is_pid(pid) -> pid != composer_pid and Process.alive?(pid)
                 _missing -> false
               end
             end)

      assert eventually(fn -> Agent.get(store, &match?([_selection], &1.selected)) end)
    end)

    [{^claim, "deterministic_fallback", body, provenance}] =
      Agent.get(store, & &1.selected)

    assert body == claim.frozen.fallback_body

    assert provenance == %{
             fallback_reason: "recovery_after_restart",
             layout_version: 2,
             synthesis_contract_version: SynthesisPolicy.version(),
             synthesis_outcome: "unresolved"
           }

    refute_receive {:local_synthesis_fault_ready, _pid, _snapshot}
  end

  test "durable composer persists one layout-v2 synthesis selected by its Jido lifecycle" do
    claim = claim()

    store =
      start_supervised!({Agent, fn -> %{claims: [claim], selected: []} end})

    name = :"report-synthesis-agent-#{System.unique_integer([:positive])}"

    start_supervised!(
      {ReportComposer,
       name: name,
       store: {ProcessStore, store},
       models: ProcessModels,
       disclosure: AllowDisclosure,
       model_client: AcceptedModel,
       model_enabled?: true,
       model_context: %{test_pid: self(), critic_implementation: SatisfiedCritic},
       reconcile_interval_ms: 5_000}
    )

    assert_receive {:synthesis_provider_call, snapshot}
    assert snapshot == claim.frozen.snapshot

    assert eventually(fn -> Agent.get(store, &match?([_selection], &1.selected)) end)

    [{^claim, "model", body, provenance}] = Agent.get(store, & &1.selected)
    assert provenance.layout_version == 2
    assert provenance.synthesis_contract_version == 2
    assert provenance.review_verdict == "accepted"
    assert provenance.reviewed_queue_positions == [0, 1]
    assert provenance.synthesis_sha256 =~ ~r/^[0-9a-f]{64}$/
    assert body =~ "Model-authored advisory synthesis:"
    refute_receive {:synthesis_provider_call, _snapshot}
  end

  test "durable composer persists complete-child fallback after final critic rejection" do
    claim = claim()
    store = start_supervised!({Agent, fn -> %{claims: [claim], selected: []} end})
    name = :"report-synthesis-phase-fallback-#{System.unique_integer([:positive])}"

    start_supervised!(
      {ReportComposer,
       name: name,
       store: {ProcessStore, store},
       models: ProcessModels,
       disclosure: AllowDisclosure,
       model_client: RevisionModel,
       model_enabled?: true,
       model_context: %{
         test_pid: self(),
         critic_implementation: PersistentlyViolatedCritic
       },
       reconcile_interval_ms: 5_000}
    )

    assert eventually(fn -> Agent.get(store, &match?([_selection], &1.selected)) end)

    [{^claim, "deterministic_fallback", body, provenance}] =
      Agent.get(store, & &1.selected)

    assert body == claim.frozen.fallback_body
    assert provenance.fallback_reason == "phase_review_unresolved"
    assert provenance.synthesis_outcome == "unresolved"
    refute body =~ "OTP supervision contains live-process failures"
  end

  test "durable composer classifies locally rejected provider output as invalid model output" do
    claim = claim()

    store =
      start_supervised!({Agent, fn -> %{claims: [claim], selected: []} end})

    name = :"report-synthesis-local-rejection-#{System.unique_integer([:positive])}"

    start_supervised!(
      {ReportComposer,
       name: name,
       store: {ProcessStore, store},
       models: ProcessModels,
       disclosure: AllowDisclosure,
       model_client: LocallyRejectedModel,
       model_enabled?: true,
       model_context: %{test_pid: self()},
       reconcile_interval_ms: 5_000}
    )

    assert_receive {:locally_rejected_provider_call, snapshot}
    assert snapshot == claim.frozen.snapshot
    assert eventually(fn -> Agent.get(store, &match?([_selection], &1.selected)) end)

    [{^claim, "deterministic_fallback", body, provenance}] =
      Agent.get(store, & &1.selected)

    assert body == claim.frozen.fallback_body

    assert provenance == %{
             fallback_reason: "invalid_model_output",
             layout_version: 2,
             synthesis_contract_version: SynthesisPolicy.version(),
             synthesis_outcome: "unresolved"
           }

    refute_receive {:locally_rejected_provider_call, _snapshot}
  end

  test "durable composer classifies every structural validator rejection at the local boundary" do
    Enum.each(
      [:duplicate_position, :missing_position, :invalid_relationship_cardinality],
      fn rejection ->
        claim = claim()

        store =
          start_supervised!(
            Supervisor.child_spec(
              {Agent, fn -> %{claims: [claim], selected: []} end},
              id: {:structural_rejection_store, rejection}
            )
          )

        name = :"report-synthesis-#{rejection}-#{System.unique_integer([:positive])}"

        start_supervised!(
          Supervisor.child_spec(
            {ReportComposer,
             name: name,
             store: {ProcessStore, store},
             models: ProcessModels,
             disclosure: AllowDisclosure,
             model_client: StructurallyRejectedModel,
             model_enabled?: true,
             model_context: %{test_pid: self(), rejection: rejection},
             reconcile_interval_ms: 5_000},
            id: {:structural_rejection_composer, rejection}
          )
        )

        assert_receive {:structurally_rejected_provider_call, ^rejection, snapshot}
        assert snapshot == claim.frozen.snapshot
        assert eventually(fn -> Agent.get(store, &match?([_selection], &1.selected)) end)

        [{^claim, "deterministic_fallback", body, provenance}] =
          Agent.get(store, & &1.selected)

        assert body == claim.frozen.fallback_body

        assert provenance == %{
                 fallback_reason: "invalid_model_output",
                 layout_version: 2,
                 synthesis_contract_version: SynthesisPolicy.version(),
                 synthesis_outcome: "unresolved"
               }

        refute_receive {:structurally_rejected_provider_call, ^rejection, _snapshot}
      end
    )
  end

  test "durable composer terminates the whole synthesis lifecycle at its authorized timeout" do
    claim = %{claim() | deadline_unix_ms: System.system_time(:millisecond) + 300}

    store =
      start_supervised!({Agent, fn -> %{claims: [claim], selected: []} end})

    name = :"report-synthesis-timeout-#{System.unique_integer([:positive])}"

    start_supervised!(
      {ReportComposer,
       name: name,
       store: {ProcessStore, store},
       models: ProcessModels,
       disclosure: AllowDisclosure,
       model_client: SlowModel,
       model_enabled?: true,
       model_context: %{test_pid: self()},
       reconcile_interval_ms: 5_000}
    )

    assert_receive {:slow_synthesis_provider_call, lifecycle_pid, snapshot}
    assert snapshot == claim.frozen.snapshot
    assert lifecycle_pid != Process.whereis(name)
    lifecycle_monitor = Process.monitor(lifecycle_pid)

    assert eventually(fn -> Agent.get(store, &match?([_selection], &1.selected)) end, 100)

    [{^claim, "deterministic_fallback", body, provenance}] =
      Agent.get(store, & &1.selected)

    assert body == claim.frozen.fallback_body

    assert provenance == %{
             fallback_reason: "synthesis_timeout",
             layout_version: 2,
             synthesis_contract_version: SynthesisPolicy.version(),
             synthesis_outcome: "unresolved"
           }

    assert_receive {:DOWN, ^lifecycle_monitor, :process, ^lifecycle_pid, :killed}
    assert Process.alive?(Process.whereis(name))
    refute_receive {:slow_synthesis_provider_call, _pid, _snapshot}
  end

  test "legacy unreviewed completed children bypass synthesis and remain deliverable" do
    claim = claim("legacy_unreviewed_advisory")
    store = start_supervised!({Agent, fn -> %{claims: [claim], selected: []} end})
    name = :"report-synthesis-legacy-#{System.unique_integer([:positive])}"

    start_supervised!(
      {ReportComposer,
       name: name,
       store: {ProcessStore, store},
       models: ProcessModels,
       disclosure: AllowDisclosure,
       model_client: AcceptedModel,
       model_enabled?: true,
       model_context: %{test_pid: self()},
       reconcile_interval_ms: 5_000}
    )

    assert eventually(fn -> Agent.get(store, &match?([_selection], &1.selected)) end)

    [{^claim, "deterministic_fallback", body, provenance}] =
      Agent.get(store, & &1.selected)

    assert body == claim.frozen.fallback_body

    assert provenance == %{
             fallback_reason: "legacy_unreviewed_children",
             layout_version: 2,
             synthesis_contract_version: SynthesisPolicy.version(),
             synthesis_outcome: "not_run"
           }

    refute_receive {:synthesis_provider_call, _snapshot}
  end

  test "zero completed children bypass synthesis with a truthful deterministic report" do
    claim = claim()

    failed_children =
      Enum.map(claim.frozen.snapshot.children, fn child ->
        %{child | status: "failed", result_authority: "registered_action"}
      end)

    failed_snapshot = %{claim.frozen.snapshot | children: failed_children, join_outcome: "failed"}

    claim = %{
      claim
      | frozen: %{
          snapshot: failed_snapshot,
          input_digest: Report.digest(failed_snapshot),
          fallback_body: Report.fallback(failed_snapshot)
        }
    }

    store = start_supervised!({Agent, fn -> %{claims: [claim], selected: []} end})
    name = :"report-synthesis-zero-completed-#{System.unique_integer([:positive])}"

    start_supervised!(
      {ReportComposer,
       name: name,
       store: {ProcessStore, store},
       models: ProcessModels,
       disclosure: AllowDisclosure,
       model_client: AcceptedModel,
       model_enabled?: true,
       model_context: %{test_pid: self()},
       reconcile_interval_ms: 5_000}
    )

    assert eventually(fn -> Agent.get(store, &match?([_selection], &1.selected)) end)

    [{^claim, "deterministic_fallback", body, provenance}] =
      Agent.get(store, & &1.selected)

    assert provenance.fallback_reason == "no_completed_children"
    assert provenance.synthesis_outcome == "not_run"
    assert body =~ "Child status totals: completed=0; failed=2"
    assert body =~ "Attention required (not model-arranged):"
    assert body =~ "No model-authored advisory synthesis was selected."
    refute_receive {:synthesis_provider_call, _snapshot}
  end

  defp snapshot do
    %{
      version: 2,
      parent_id: "synthesis-parent",
      title: "Join two mechanisms",
      original_request: "Explain how the two mechanisms complement each other.",
      status: "completed",
      join_outcome: "success",
      plan: %{},
      children: [
        child(0, "Failure isolation", "Supervision isolates a crashed process."),
        child(1, "Durable recovery", "Replay rebuilds state after restart.")
      ]
    }
  end

  defp claim(authority \\ "reviewed_advisory") do
    parent = %Objective{
      id: "synthesis-durable-parent",
      title: "Join two mechanisms",
      objective: "Explain how the two mechanisms complement each other.",
      fanout_role: "parent",
      status: "completed",
      join_outcome: "success",
      proposer_hint: Jason.encode!(%{})
    }

    children = [
      objective_child(0, "Failure isolation", "Supervision isolates a crashed process."),
      objective_child(1, "Durable recovery", "Replay rebuilds state after restart.")
    ]

    authorities =
      Map.new(children, fn child ->
        {child.id,
         %{
           result_authority: authority,
           quality_receipt_sha256:
             if(authority == "reviewed_advisory",
               do: String.duplicate(Integer.to_string(child.queue_position + 1), 64),
               else: nil
             )
         }}
      end)

    {:ok, frozen} = Report.freeze_v2(parent, children, %{}, authorities)

    {:ok, budget} =
      Budget.resolve(2, 0, %{
        version: 2,
        max_model_calls: 40,
        max_output_tokens: 24_000,
        max_elapsed_ms: 300_000,
        max_worker_attempts_per_child: 2
      })

    %{
      parent: parent,
      frozen: frozen,
      budget: budget,
      deadline_unix_ms: System.system_time(:millisecond) + 10_000,
      context: %{request: %{channel: :cli}}
    }
  end

  defp objective_child(position, title, detail) do
    %Objective{
      id: "synthesis-durable-child-#{position}",
      queue_position: position,
      title: title,
      objective: "Analyze #{String.downcase(title)}.",
      fanout_role: "child",
      status: "completed",
      last_observation_summary: detail
    }
  end

  defp child(position, title, detail) do
    %{
      id: "synthesis-child-#{position}",
      queue_position: position,
      title: title,
      objective: "Analyze #{String.downcase(title)}.",
      expected_result: nil,
      status: "completed",
      detail: detail,
      effect_receipt_ref: nil,
      result_authority: "reviewed_advisory",
      quality_receipt_sha256: String.duplicate(Integer.to_string(position + 1), 64)
    }
  end

  defp profile do
    %{
      name: "direct_answer_local",
      provider_type: "openai_compatible",
      provider: "local_ollama",
      model: "qwen2.5:7b",
      temperature: 0.9,
      max_tokens: 8_192,
      timeout_ms: 60_000,
      provider_base_url: "http://localhost:11434/v1",
      provider_api_key_ref: nil
    }
  end

  defp synthesis_transport(schema, opts) do
    %{
      base_url: opts[:base_url],
      response_schema_sha256: sha256(CanonicalJSON.encode(schema)),
      temperature: opts[:temperature],
      max_output_tokens: opts[:max_tokens],
      receive_timeout_ms: opts[:receive_timeout],
      total_timeout_ms: opts[:total_timeout],
      max_retries: opts[:max_retries],
      structured_output_mode: opts[:openai_structured_output_mode],
      json_repair: opts[:json_repair]
    }
  end

  defp synthesis_extras(phase, revision_rule_ids \\ []) do
    {:ok, protocol} = SynthesisPolicy.review_protocol()

    {:ok, catalog_sha256} =
      SynthesisPolicy.rule_group_catalog_sha256(SynthesisPolicy.rule_group_catalog_version())

    %{
      phase: phase,
      policy_version: SynthesisPolicy.version(),
      review_protocol_version: protocol.review_protocol_version,
      rule_group_catalog_version: SynthesisPolicy.rule_group_catalog_version(),
      rule_group_catalog_sha256: catalog_sha256
    }
    |> then(fn extras ->
      if revision_rule_ids == [],
        do: extras,
        else:
          Map.put(
            extras,
            :revision_rule_ids_sha256,
            sha256(CanonicalJSON.encode(revision_rule_ids))
          )
    end)
  end

  defp review_round_config_sha256(reviewer_config_for_group) do
    {:ok, protocol} = SynthesisPolicy.review_protocol()

    aggregate_input = %{
      "review_protocol_version" => protocol.review_protocol_version,
      "rule_group_catalog_version" => protocol.rule_group_catalog_version,
      "rule_group_catalog_sha256" => protocol.rule_group_catalog_sha256,
      "critics" =>
        Enum.map(ReviewProtocol.group_ids(protocol), fn group_id ->
          %{
            "group_id" => group_id,
            "reviewer_config_sha256" => reviewer_config_for_group.(group_id)
          }
        end)
    }

    sha256(@reviewer_config_aggregate_domain <> CanonicalJSON.encode(aggregate_input))
  end

  defp sequence_clock(values) do
    clock = start_supervised!({Agent, fn -> values end})

    fn ->
      Agent.get_and_update(clock, fn
        [value | remaining] -> {value, remaining}
        [] -> raise "synthesis monotonic clock exhausted"
      end)
    end
  end

  defp sha256(value) do
    value
    |> then(&:crypto.hash(:sha256, &1))
    |> Base.encode16(case: :lower)
  end

  defp message_text(message) do
    message.content
    |> Enum.filter(&(&1.type == :text))
    |> Enum.map_join("", & &1.text)
  end

  defp eventually(fun, attempts \\ 50)
  defp eventually(fun, 0), do: fun.()

  defp eventually(fun, attempts) do
    if fun.() do
      true
    else
      Process.sleep(10)
      eventually(fun, attempts - 1)
    end
  end
end
