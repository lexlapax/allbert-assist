defmodule AllbertAssist.Objectives.Fanout.ReportSynthesisAgentTest do
  use ExUnit.Case, async: true
  @moduletag :pure_async

  alias AllbertAssist.Objectives.Fanout.Budget
  alias AllbertAssist.Objectives.Fanout.Report
  alias AllbertAssist.Objectives.Fanout.Report.SynthesisPolicy
  alias AllbertAssist.Objectives.Fanout.ReportComposer
  alias AllbertAssist.Objectives.Fanout.ReportComposer.ReqLLMImplementation
  alias AllbertAssist.Objectives.Fanout.ReportComposer.SynthesisAgent
  alias AllbertAssist.Objectives.Objective
  alias ReqLLM.Response

  defmodule AcceptedModel do
    alias AllbertAssist.Objectives.Fanout.Report.SynthesisPolicy

    def compose(snapshot, _profile, context) do
      send(context.test_pid, {:synthesis_provider_call, snapshot})

      {:ok,
       %{
         "sections" => [
           %{"relationship" => "complementary", "ordered_queue_positions" => [0, 1]}
         ],
         "advisory_synthesis" =>
           "Failure isolation limits the process blast radius while durable replay restores the state needed after restart.",
         "review" => %{
           "verdict" => "accepted",
           "rule_results" =>
             Enum.map(SynthesisPolicy.rule_ids(), fn rule_id ->
               %{"rule_id" => rule_id, "verdict" => "satisfied"}
             end),
           "covered_queue_positions" => [0, 1]
         }
       }}
    end
  end

  defmodule LocallyRejectedModel do
    alias AllbertAssist.Objectives.Fanout.Report.SynthesisPolicy

    def compose(snapshot, _profile, context) do
      send(context.test_pid, {:locally_rejected_provider_call, snapshot})

      {:ok,
       %{
         "sections" => [
           %{"relationship" => "complementary", "ordered_queue_positions" => [0, 1]}
         ],
         "advisory_synthesis" =>
           "The provider returned this unredacted token: " <>
             "AIzaSyDUMMYSecretShapeForAudit59",
         "review" => %{
           "verdict" => "accepted",
           "rule_results" =>
             Enum.map(SynthesisPolicy.rule_ids(), fn rule_id ->
               %{"rule_id" => rule_id, "verdict" => "satisfied"}
             end),
           "covered_queue_positions" => [0, 1]
         }
       }}
    end
  end

  defmodule SlowModel do
    alias AllbertAssist.Objectives.Fanout.Report.SynthesisPolicy

    def compose(snapshot, _profile, context) do
      send(context.test_pid, {:slow_synthesis_provider_call, self(), snapshot})
      Process.sleep(1_000)

      {:ok,
       %{
         "sections" => [
           %{"relationship" => "complementary", "ordered_queue_positions" => [0, 1]}
         ],
         "advisory_synthesis" =>
           "Failure isolation and durable replay complement each other after restart.",
         "review" => %{
           "verdict" => "accepted",
           "rule_results" =>
             Enum.map(SynthesisPolicy.rule_ids(), fn rule_id ->
               %{"rule_id" => rule_id, "verdict" => "satisfied"}
             end),
           "covered_queue_positions" => [0, 1]
         }
       }}
    end
  end

  defmodule StructurallyRejectedModel do
    alias AllbertAssist.Objectives.Fanout.Report.SynthesisPolicy

    def compose(snapshot, _profile, context) do
      send(
        context.test_pid,
        {:structurally_rejected_provider_call, context.rejection, snapshot}
      )

      {:ok,
       %{
         "sections" => sections(context.rejection),
         "advisory_synthesis" =>
           "Failure isolation and durable replay complement each other after restart.",
         "review" => %{
           "verdict" => "accepted",
           "rule_results" =>
             Enum.map(SynthesisPolicy.rule_ids(), fn rule_id ->
               %{"rule_id" => rule_id, "verdict" => "satisfied"}
             end),
           "covered_queue_positions" => [0, 1]
         }
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
    alias AllbertAssist.Objectives.Fanout.Report.SynthesisPolicy

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
             "Failure isolation and durable replay complement each other at restart.",
           "review" => %{
             "verdict" => "accepted",
             "rule_results" =>
               Enum.map(SynthesisPolicy.rule_ids(), fn rule_id ->
                 %{"rule_id" => rule_id, "verdict" => "satisfied"}
               end),
             "covered_queue_positions" => [0, 1]
           }
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

  test "one ephemeral Jido lifecycle accepts one reviewed synthesis call" do
    snapshot = snapshot()

    assert {:ok, prepared} =
             SynthesisAgent.run(
               snapshot,
               %{name: "direct_answer_local"},
               %{test_pid: self()},
               AcceptedModel,
               5_000
             )

    assert prepared.layout.layout_version == 2
    assert prepared.review_verdict == "accepted"
    assert prepared.reviewed_queue_positions == [0, 1]
    assert prepared.body =~ "Model-authored advisory synthesis:"
    assert_receive {:synthesis_provider_call, ^snapshot}
    refute_receive {:synthesis_provider_call, _snapshot}
  end

  test "ReqLLM adapter requests one exact synthesis and closed review object" do
    assert {:ok, %{"review" => %{"verdict" => "accepted"}}} =
             ReqLLMImplementation.compose(snapshot(), profile(), %{
               req_llm_client: CaptureReqLLM,
               test_pid: self(),
               timeout_ms: 5_000,
               max_output_tokens: 1_024
             })

    assert_receive {:req_llm_synthesis, %{provider: :openai, id: "qwen2.5:7b"}, prompt, schema,
                    opts}

    assert schema |> Keyword.keys() |> Enum.sort() ==
             ~w[advisory_synthesis review sections]a

    assert schema[:advisory_synthesis][:required]
    assert {:map, review_schema} = schema[:review][:type]
    assert review_schema[:verdict][:type] == {:in, ["accepted", "unresolved"]}
    assert review_schema[:rule_results][:required]
    {:list, {:map, rule_result_schema}} = review_schema[:rule_results][:type]
    assert rule_result_schema[:rule_id][:type] == {:in, SynthesisPolicy.rule_ids()}
    assert review_schema[:covered_queue_positions][:type] == {:list, :integer}
    assert opts[:temperature] == 0.0
    assert opts[:json_repair] == false

    metadata = List.last(prompt.messages).metadata.allbert_prompt
    assert metadata.schema_version == 1
    assert metadata.purpose == :fanout_report_synthesis
    assert metadata.rule_ids == SynthesisPolicy.prompt_rule_ids()
    refute_receive {:req_llm_synthesis, _, _, _, _}
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
       model_context: %{test_pid: self()},
       reconcile_interval_ms: 5_000}
    )

    assert_receive {:synthesis_provider_call, snapshot}
    assert snapshot == claim.frozen.snapshot

    assert eventually(fn -> Agent.get(store, &match?([_selection], &1.selected)) end)

    [{^claim, "model", body, provenance}] = Agent.get(store, & &1.selected)
    assert provenance.layout_version == 2
    assert provenance.synthesis_contract_version == SynthesisPolicy.version()
    assert provenance.review_verdict == "accepted"
    assert provenance.reviewed_queue_positions == [0, 1]
    assert provenance.synthesis_sha256 =~ ~r/^[0-9a-f]{64}$/
    assert body =~ "Model-authored advisory synthesis:"
    refute_receive {:synthesis_provider_call, _snapshot}
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
        version: 1,
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
