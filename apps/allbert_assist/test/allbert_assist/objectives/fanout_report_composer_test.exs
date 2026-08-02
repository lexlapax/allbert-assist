defmodule AllbertAssist.Objectives.Fanout.ReportComposerTest do
  use AllbertAssist.DataCase, async: false
  @moduletag :db_serial

  alias AllbertAssist.Models.ClosedRuleEvidence
  alias AllbertAssist.Objectives
  alias AllbertAssist.Objectives.Fanout
  alias AllbertAssist.Objectives.Fanout.Budget
  alias AllbertAssist.Objectives.Fanout.PlanProvenance
  alias AllbertAssist.Objectives.Fanout.Report
  alias AllbertAssist.Objectives.Fanout.Report.SynthesisPolicy
  alias AllbertAssist.Objectives.Fanout.ReportComposer
  alias AllbertAssist.Objectives.Fanout.ReportComposer.ReqLLMImplementation
  alias AllbertAssist.Objectives.Fanout.TerminalTransitions
  alias AllbertAssist.Objectives.Objective
  alias ReqLLM.Response

  defmodule SynthesisFixture do
    alias AllbertAssist.Objectives.Fanout.Report.SynthesisPolicy

    def accepted(relationship, ordered_queue_positions, synthesis) do
      base(relationship, ordered_queue_positions, synthesis)
      |> put_in(
        ["review"],
        %{
          "verdict" => "accepted",
          "rule_results" =>
            Enum.map(SynthesisPolicy.rule_ids(), fn rule_id ->
              %{"rule_id" => rule_id, "verdict" => "satisfied"}
            end),
          "covered_queue_positions" => ordered_queue_positions
        }
      )
    end

    def provider(relationship, ordered_queue_positions, synthesis) do
      base(relationship, ordered_queue_positions, synthesis)
      |> put_in(
        ["review"],
        %{
          "rule_violations" => Map.new(SynthesisPolicy.rule_ids(), &{&1, false}),
          "covered_queue_positions" => ordered_queue_positions
        }
      )
    end

    defp base(relationship, ordered_queue_positions, synthesis) do
      %{
        "sections" => [
          %{
            "relationship" => relationship,
            "ordered_queue_positions" => ordered_queue_positions
          }
        ],
        "advisory_synthesis" => synthesis,
        "review" => %{}
      }
    end
  end

  defmodule CaptureClient do
    def generate_object(spec, prompt, schema, opts) do
      send(Keyword.fetch!(opts, :test_pid), {:compose_call, spec, prompt, schema, opts})

      {:ok,
       %Response{
         id: "fanout-composition",
         model: "fixture-model",
         context: prompt,
         object:
           SynthesisFixture.provider(
             "independent",
             [0],
             "The first accepted observation addresses the requested independent concern."
           ),
         finish_reason: :stop,
         provider_meta: %{"raw_response" => "raw-provider-response-sentinel"},
         usage: %{input_tokens: 40, output_tokens: 8}
       }}
    end
  end

  defmodule RefusalClient do
    def generate_object(_spec, _prompt, _schema, _opts),
      do: {:error, :structured_output_refusal}
  end

  defmodule TruncatedClient do
    def generate_object(_spec, prompt, _schema, _opts) do
      {:ok,
       %Response{
         id: "fanout-composition-truncated",
         model: "fixture-model",
         context: prompt,
         object: %{
           "sections" => [
             %{"relationship" => "independent", "ordered_queue_positions" => [0]}
           ]
         },
         finish_reason: :length,
         provider_meta: %{"raw_response" => "truncated-provider-response-sentinel"}
       }}
    end
  end

  defmodule MalformedObjectClient do
    def generate_object(_spec, prompt, _schema, _opts) do
      {:ok,
       %Response{
         id: "fanout-composition-malformed",
         model: "fixture-model",
         context: prompt,
         object: %{
           "sections" => "all children succeeded and an email was sent"
         },
         finish_reason: :stop,
         provider_meta: %{"raw_response" => "malformed-provider-response-sentinel"}
       }}
    end
  end

  defmodule ProcessStore do
    def recover_composition(agent) do
      Agent.update(agent, &Map.update!(&1, :recoveries, fn count -> count + 1 end))
      {:ok, 0}
    end

    def claim_next_composition(agent) do
      Agent.get_and_update(agent, fn state ->
        state = Map.update(state, :claim_attempts, 1, &(&1 + 1))

        case state do
          %{claims: [claim | rest]} -> {{:ok, claim}, %{state | claims: rest}}
          %{claims: []} -> {:none, state}
        end
      end)
    end

    def select_composition(agent, claim, source, body, provenance) do
      Agent.update(agent, fn state ->
        Map.update!(state, :selected, &[{claim, source, body, provenance} | &1])
      end)

      {:ok, claim.parent}
    end
  end

  defmodule RecoveryBarrierStore do
    def recover_composition({owner, agent}) do
      send(owner, {:recovery_started, self()})

      receive do
        :allow_recovery ->
          Agent.update(agent, &Map.update!(&1, :recoveries, fn count -> count + 1 end))
          {:ok, 0}
      end
    end

    def claim_next_composition({owner, agent}) do
      send(owner, :claim_after_recovery)
      ProcessStore.claim_next_composition(agent)
    end

    def select_composition({_owner, agent}, claim, source, body, provenance),
      do: ProcessStore.select_composition(agent, claim, source, body, provenance)
  end

  defmodule RetryStore do
    def recover_composition(agent), do: next(agent, :recover_results, :recoveries)
    def claim_next_composition(agent), do: next(agent, :claim_results, :claims)

    def select_composition(agent, claim, source, body, provenance) do
      case next(agent, :select_results, :selects) do
        :ok ->
          Agent.update(agent, fn state ->
            Map.update!(state, :selected, &[{claim, source, body, provenance} | &1])
          end)

          {:ok, claim.parent}

        {:error, _reason} = error ->
          error
      end
    end

    defp next(agent, results_key, count_key) do
      Agent.get_and_update(agent, fn state ->
        [result | rest] = Map.fetch!(state, results_key)
        {result, state |> Map.put(results_key, rest) |> Map.update!(count_key, &(&1 + 1))}
      end)
    end
  end

  defmodule RaisedExitStore do
    def recover_composition(agent) do
      case increment(agent, :recoveries) do
        1 ->
          raise DBConnection.ConnectionError,
            message: "temporary connection loss",
            reason: :error,
            severity: :error

        _retried ->
          {:ok, 0}
      end
    end

    def claim_next_composition(agent) do
      case increment(agent, :claims) do
        1 ->
          exit(
            {:shutdown,
             %DBConnection.ConnectionError{
               message: "temporary connection exit",
               reason: :error,
               severity: :error
             }}
          )

        2 ->
          {:ok, Agent.get(agent, & &1.claim)}

        _drained ->
          :none
      end
    end

    def select_composition(agent, claim, source, body, provenance),
      do: ProcessStore.select_composition(agent, claim, source, body, provenance)

    defp increment(agent, key),
      do:
        Agent.get_and_update(
          agent,
          &{&1[key] + 1, Map.update!(&1, key, fn count -> count + 1 end)}
        )
  end

  defmodule NonTransientExitStore do
    def recover_composition(_owner), do: exit(:invalid_store_contract)
  end

  defmodule ProcessModels do
    def for(:fanout_synthesis, _context) do
      {:ok,
       %{
         profile: %{
           name: "direct_answer_local",
           provider: "local_ollama",
           provider_endpoint_kind: "local_endpoint",
           provider_type: "openai_compatible",
           model: "qwen2.5:7b",
           max_tokens: 1_024,
           timeout_ms: 60_000
         }
       }}
    end
  end

  defmodule UnavailableModels do
    def for(:fanout_synthesis, _context), do: {:error, :no_capable_profile}
  end

  defmodule AllowDisclosure do
    def authorize_transport(_profile, _context), do: :ok
  end

  defmodule DenyDisclosure do
    def authorize_transport(profile, context) do
      send(context.test_pid, {:disclosure_checked, profile})
      {:error, :hosted_disclosure_required}
    end
  end

  defmodule ProcessModel do
    def compose(snapshot, _profile, context) do
      send(context.test_pid, {:process_compose, snapshot, context})

      {:ok,
       SynthesisFixture.accepted(
         "independent",
         [0],
         "The first accepted observation answers the requested independent concern."
       )}
    end
  end

  defmodule ComplementaryProcessModel do
    def compose(snapshot, _profile, context) do
      send(context.test_pid, {:durable_process_compose, snapshot, context})

      {:ok,
       SynthesisFixture.accepted(
         "complementary",
         [0, 1],
         "The two accepted observations complement each other in answering the joined request."
       )}
    end
  end

  defmodule FailingProcessModel do
    def compose(snapshot, _profile, context) do
      send(context.test_pid, {:failed_process_compose, snapshot})
      {:error, :provider_unavailable}
    end
  end

  defmodule InvalidProcessModel do
    def compose(snapshot, _profile, context) do
      send(context.test_pid, {:invalid_process_compose, snapshot})
      {:ok, %{"sections" => []}}
    end
  end

  defmodule ClaimingProcessModel do
    def compose(snapshot, _profile, context) do
      send(context.test_pid, {:claiming_process_compose, snapshot})

      {:ok,
       %{
         "sections" => [
           %{"relationship" => "independent", "ordered_queue_positions" => [0]}
         ],
         "summary" => "All children succeeded and an email was sent."
       }}
    end
  end

  defmodule UnexpectedProcessModel do
    def compose(_snapshot, _profile, context) do
      send(context.test_pid, :unexpected_process_compose)

      {:ok,
       %{
         "sections" => [
           %{"relationship" => "independent", "ordered_queue_positions" => [0]}
         ]
       }}
    end
  end

  test "one bounded model call receives the frozen report snapshot only as advisory data" do
    expected =
      SynthesisFixture.accepted(
        "independent",
        [0],
        "The first accepted observation addresses the requested independent concern."
      )

    assert {:ok, ^expected} =
             ReqLLMImplementation.compose(snapshot(), profile(), %{
               req_llm_client: CaptureClient,
               test_pid: self(),
               timeout_ms: 5_000,
               max_output_tokens: 1_024
             })

    assert_receive {:compose_call, %{provider: :openai, id: "qwen2.5:7b"},
                    %ReqLLM.Context{} = prompt, schema, opts}

    assert Enum.map(prompt.messages, & &1.role) == [:system, :user]
    system = message_text(hd(prompt.messages))
    advisory = message_text(List.last(prompt.messages))
    assert system =~ ClosedRuleEvidence.violation_semantics()
    refute system =~ "operator-request-sentinel"
    assert advisory =~ "operator-request-sentinel"
    assert advisory =~ "child-result-sentinel"

    assert List.last(prompt.messages).metadata.allbert_prompt == %{
             schema_version: 1,
             purpose: :fanout_report_synthesis,
             content_class: :advisory_data,
             rule_ids: SynthesisPolicy.prompt_rule_ids()
           }

    assert schema["type"] == "object"
    assert schema["required"] == ~w[sections advisory_synthesis review]
    assert schema["additionalProperties"] == false

    section_schema = schema["properties"]["sections"]["items"]

    assert section_schema["properties"]["relationship"]["enum"] ==
             ~w[complementary contrasting sequential supporting independent]

    assert section_schema["required"] == ~w[relationship ordered_queue_positions]
    assert section_schema["additionalProperties"] == false

    assert section_schema["properties"]["ordered_queue_positions"] == %{
             "type" => "array",
             "items" => %{"type" => "integer", "minimum" => 0}
           }

    assert schema["properties"]["advisory_synthesis"]["type"] == "string"

    review_schema = schema["properties"]["review"]
    assert review_schema["required"] == ~w[rule_violations covered_queue_positions]
    assert review_schema["additionalProperties"] == false

    assert review_schema["properties"]["rule_violations"] == %{
             "type" => "object",
             "properties" => Map.new(SynthesisPolicy.rule_ids(), &{&1, %{"type" => "boolean"}}),
             "required" => SynthesisPolicy.rule_ids(),
             "additionalProperties" => false
           }

    assert review_schema["properties"]["covered_queue_positions"] == %{
             "type" => "array",
             "items" => %{"type" => "integer", "minimum" => 0}
           }

    assert opts[:temperature] == 0.0
    assert opts[:max_tokens] == 1_024
    assert opts[:receive_timeout] == 5_000
    assert opts[:openai_structured_output_mode] == :json_schema
    assert opts[:json_repair] == false
    refute_received {:compose_call, _, _, _, _}
  end

  test "maximum-child composition prompt is a bounded excerpt projection of the full snapshot" do
    parent = %Objective{
      id: "fanout_provider_input_parent",
      title: "Relate the complete architecture review",
      objective: "Synthesize the sixteen independent architecture findings.",
      fanout_role: "parent",
      status: "completed",
      join_outcome: "success",
      proposer_hint: Jason.encode!(%{})
    }

    details =
      Map.new(0..15, fn queue_position ->
        tail = "authoritative-tail-child-#{queue_position}"

        detail =
          String.duplicate("child-#{queue_position}-authoritative-observation ", 48) <> tail

        {queue_position, %{detail: detail, tail: tail}}
      end)

    children =
      Enum.map(0..15, fn queue_position ->
        %Objective{
          id: "fanout_provider_input_child_#{queue_position}",
          queue_position: queue_position,
          title: "Architecture finding #{queue_position + 1}",
          objective: "Explain bounded architecture concern #{queue_position + 1}.",
          fanout_role: "child",
          status: "completed",
          last_observation_summary: details[queue_position].detail
        }
      end)

    assert {:ok, frozen} = Report.freeze(parent, children)
    assert {:ok, projection} = Report.composition_input(frozen.snapshot)

    encoded_projection = Jason.encode!(projection)
    assert byte_size(encoded_projection) <= 16_384

    assert projection |> Map.keys() |> Enum.map(&to_string/1) |> Enum.sort() ==
             ~w[children join_outcome original_request status title]

    assert Enum.map(projection.children, & &1.queue_position) == Enum.to_list(0..15)

    Enum.each(projection.children, fn child ->
      authoritative = Enum.at(frozen.snapshot.children, child.queue_position)
      expected = Map.fetch!(details, child.queue_position)

      assert child |> Map.keys() |> Enum.map(&to_string/1) |> Enum.sort() ==
               ~w[detail_excerpt detail_excerpt_truncated objective queue_position status title]

      assert child.detail_excerpt_truncated
      assert byte_size(child.detail_excerpt) < byte_size(authoritative.detail)
      refute child.detail_excerpt =~ expected.tail
      assert String.ends_with?(authoritative.detail, expected.tail)
    end)

    assert {:ok, prompt} = ReqLLMImplementation.prompt(frozen.snapshot)
    advisory = prompt.messages |> List.last() |> message_text()

    assert byte_size(advisory) <= 16_384
    assert Jason.decode!(advisory) == Jason.decode!(encoded_projection)

    control_heavy = String.duplicate("\"\\" <> <<1>>, 1_000)

    stressed_snapshot = %{
      frozen.snapshot
      | title: control_heavy,
        original_request: control_heavy,
        children:
          Enum.map(frozen.snapshot.children, fn child ->
            %{
              child
              | title: control_heavy,
                objective: control_heavy,
                detail: control_heavy
            }
          end)
    }

    assert {:ok, stressed_projection} = Report.composition_input(stressed_snapshot)
    assert byte_size(Jason.encode!(stressed_projection)) <= 16_384
  end

  test "adapter refusal and truncated structured output fail closed without repair" do
    context = %{timeout_ms: 5_000, max_output_tokens: 1_024}

    assert {:error, {:provider_failed, :structured_output_refusal}} =
             ReqLLMImplementation.compose(
               snapshot(),
               profile(),
               Map.put(context, :req_llm_client, RefusalClient)
             )

    assert {:error, {:invalid_model_output, {:incomplete_composition_response, :length}}} =
             ReqLLMImplementation.compose(
               snapshot(),
               profile(),
               Map.put(context, :req_llm_client, TruncatedClient)
             )
  end

  test "malformed adapter object selects fallback and raw provider response is never persisted" do
    claim = claim_with_test_pid()
    store = process_store([claim])

    start_process_composer(
      store: {ProcessStore, store},
      disclosure: AllowDisclosure,
      model_client: ReqLLMImplementation,
      model_context: %{
        req_llm_client: MalformedObjectClient,
        test_pid: self()
      },
      model_enabled?: true
    )

    assert_selected_fallback(store, claim, :invalid_model_output)

    selected = Agent.get(store, & &1.selected)
    refute inspect(selected) =~ "malformed-provider-response-sentinel"
    refute inspect(selected) =~ "all children succeeded and an email was sent"
  end

  test "valid adapter response persists only normalized layout, never raw provider metadata" do
    claim = claim_with_test_pid()
    store = process_store([claim])

    start_process_composer(
      store: {ProcessStore, store},
      disclosure: AllowDisclosure,
      model_client: ReqLLMImplementation,
      model_context: %{req_llm_client: CaptureClient, test_pid: self()},
      model_enabled?: true
    )

    assert_receive {:compose_call, _spec, _prompt, _schema, _opts}, 1_000

    assert eventually(fn -> Agent.get(store, &match?([_selected], &1.selected)) end)

    [{^claim, "model", body, provenance}] = Agent.get(store, & &1.selected)
    refute body =~ "raw-provider-response-sentinel"
    refute inspect(provenance) =~ "raw-provider-response-sentinel"
  end

  test "supervised composer selects a typed layout and stores one deterministic factual report" do
    claim = claim()

    expected_result =
      SynthesisFixture.accepted(
        "independent",
        [0],
        "The first accepted observation answers the requested independent concern."
      )

    assert {:ok, expected_prepared} =
             Report.prepare_synthesis(claim.frozen.snapshot, expected_result)

    store =
      start_supervised!({Agent, fn -> %{claims: [claim], selected: [], recoveries: 0} end})

    name = :"fanout-report-composer-#{System.unique_integer([:positive])}"

    start_supervised!(
      {ReportComposer,
       name: name,
       store: {ProcessStore, store},
       models: ProcessModels,
       disclosure: AllowDisclosure,
       model_client: ProcessModel,
       model_enabled?: true,
       model_context: %{test_pid: self()}}
    )

    assert_receive {:process_compose, snapshot, call_context}, 1_000
    assert snapshot == claim.frozen.snapshot
    assert call_context.max_output_tokens == 1_024
    assert call_context.timeout_ms > 0

    assert eventually(fn ->
             Agent.get(store, fn state ->
               match?(
                 %{recoveries: 1, selected: [{^claim, "model", body, _provenance}]}
                 when is_binary(body),
                 state
               )
             end)
           end)

    [{^claim, "model", body, provenance}] = Agent.get(store, & &1.selected)
    assert body == expected_prepared.body
    assert body =~ "Independent finding:"
    assert body =~ "Selected relationship: independent."
    assert body =~ ~s|"First child" (objective: "First objective")|
    assert body =~ "Model-authored advisory synthesis:"
    assert body =~ "The first accepted observation answers the requested independent concern."
    assert body =~ ~s|Registered-action result: observation="child-result-sentinel"|

    assert body =~
             ~s|Registered-action terminal detail (no completed result): observation="provider failed"|

    assert body =~ "Authoritative child results (ordered):"
    assert body =~ ~s|✓ title="First child" [completed] — Registered-action result|
    assert body =~ ~s|✗ title="Second child" [failed] — Registered-action terminal detail|

    assert provenance == %{
             model_profile: "direct_answer_local",
             provider: "local_ollama",
             model: "qwen2.5:7b",
             layout_version: 2,
             sections: [%{relationship: "independent", ordered_queue_positions: [0]}],
             synthesis_contract_version: SynthesisPolicy.version(),
             review_verdict: "accepted",
             reviewed_queue_positions: [0],
             synthesis_sha256: expected_prepared.synthesis_sha256
           }

    refute_received {:process_compose, _, _}
  end

  test "SQLite-backed frame reload authorizes exactly one model composition and delivery" do
    plan = durable_plan()

    assert {:ok, %{parent: parent, children: children}} =
             frame_durable_fanout("durable-composer", "durable-composer-thread", plan)

    assert {:ok, persisted_plan} = Fanout.verified_plan(parent)
    assert persisted_plan == plan
    assert is_integer(persisted_plan["budget"]["configured_output_tokens"])
    assert is_integer(persisted_plan["budget"]["required_output_tokens"])

    assert [%{payload: proposal_payload}] =
             parent.id
             |> Objectives.list_events()
             |> Enum.filter(&(&1.kind == "fanout_proposed"))

    assert {:ok, proposal} = PlanProvenance.decode_proposal_event(proposal_payload)
    assert proposal["budget"] == persisted_plan["budget"]

    durable_details =
      Map.new(children, fn child ->
        detail =
          String.duplicate("durable-child-#{child.queue_position}-result ", 48) <>
            "durable-tail-#{child.queue_position}"

        {child.queue_position, detail}
      end)

    Enum.each(children, fn child ->
      complete_registered_action_child!(
        child,
        Map.fetch!(durable_details, child.queue_position),
        "durable-composer-#{child.queue_position}"
      )
    end)

    start_process_composer(
      store: Fanout,
      disclosure: AllowDisclosure,
      model_client: ComplementaryProcessModel,
      model_enabled?: true
    )

    assert_receive {:durable_process_compose, snapshot, call_context}, 1_000
    assert Enum.map(snapshot.children, & &1.queue_position) == [0, 1]
    assert call_context.max_output_tokens == 1_024

    assert eventually(fn ->
             case Objectives.get_objective(parent.id) do
               {:ok, selected} ->
                 selected.report_composition_state == "ready" and
                   selected.report_source == "model" and
                   selected.report_delivery_state == "pending"

               _missing ->
                 false
             end
           end)

    assert [pending] =
             Fanout.pending_reports("durable-composer", "durable-composer-thread", %{
               channel: :test
             })

    assert :ok =
             Fanout.acknowledge_report(
               pending.report_delivery_receipt,
               Map.merge(pending.delivery_context, %{
                 user_id: "durable-composer",
                 source_channel: "test",
                 source_thread_id: "durable-composer-thread"
               })
             )

    assert {:ok, delivered} = Objectives.get_objective(parent.id)
    assert delivered.report_delivery_state == "delivered"
    assert delivered.report_body =~ "Complementary findings:"

    Enum.each(durable_details, fn {queue_position, detail} ->
      assert occurrence_count(delivered.report_body, detail) == 1
      assert delivered.report_body =~ "durable-tail-#{queue_position}"
    end)

    assert [selected_event] =
             parent.id
             |> Objectives.list_events()
             |> Enum.filter(&(&1.kind == "fanout_report_selected"))

    assert %{"source" => "model"} = Jason.decode!(selected_event.payload)
    refute_receive {:durable_process_compose, _, _}, 100
  end

  test "SQLite-backed corrupt plan budget selects explicit fallback without a model call" do
    plan = durable_plan()

    assert {:ok, %{parent: parent, children: children}} =
             frame_durable_fanout("corrupt-budget", "corrupt-budget-thread", plan)

    tampered_hint =
      parent.proposer_hint
      |> Jason.decode!()
      |> put_in(["fanout_plan", "budget", "configured_output_tokens"], "[REDACTED]")

    assert {1, _rows} =
             Objective
             |> where([objective], objective.id == ^parent.id)
             |> Repo.update_all(
               set: [
                 proposer_hint: Jason.encode!(tampered_hint),
                 updated_at: DateTime.utc_now()
               ]
             )

    assert {:ok, tampered_parent} = Objectives.get_objective(parent.id)

    assert {:error, :invalid_fanout_plan_provenance} =
             Fanout.verified_plan(tampered_parent)

    durable_details =
      Map.new(children, fn child ->
        detail =
          String.duplicate("fallback-child-#{child.queue_position}-result ", 48) <>
            "fallback-tail-#{child.queue_position}"

        {child.queue_position, detail}
      end)

    Enum.each(children, fn child ->
      complete_registered_action_child!(
        child,
        Map.fetch!(durable_details, child.queue_position),
        "corrupt-budget-#{child.queue_position}"
      )
    end)

    start_process_composer(
      store: Fanout,
      disclosure: AllowDisclosure,
      model_client: UnexpectedProcessModel,
      model_enabled?: true
    )

    assert eventually(fn ->
             case Objectives.get_objective(parent.id) do
               {:ok, selected} ->
                 selected.report_composition_state == "fallback" and
                   selected.report_source == "deterministic_fallback"

               _missing ->
                 false
             end
           end)

    refute_received :unexpected_process_compose

    assert [selected_event] =
             parent.id
             |> Objectives.list_events()
             |> Enum.filter(&(&1.kind == "fanout_report_selected"))

    assert %{
             "source" => "deterministic_fallback",
             "fallback_reason" => "invalid_budget_snapshot"
           } = Jason.decode!(selected_event.payload)

    assert {:ok, fallback_parent} = Objectives.get_objective(parent.id)

    Enum.each(durable_details, fn {queue_position, detail} ->
      assert occurrence_count(fallback_parent.report_body, detail) == 1
      assert fallback_parent.report_body =~ "fallback-tail-#{queue_position}"
    end)
  end

  test "application supervises an idle composer in test so unrelated DataCase rows are not consumed" do
    assert pid = Process.whereis(ReportComposer)
    assert Process.alive?(pid)
    assert %{enabled?: false} = :sys.get_state(pid)
  end

  test "start_link returns before recovery and enqueue during recovery is not lost" do
    name = :"fanout-report-composer-#{System.unique_integer([:positive])}"
    claim = claim()
    store = process_store([claim])

    assert {:ok, composer_pid} =
             ReportComposer.start_link(
               name: name,
               store: {RecoveryBarrierStore, {self(), store}},
               models: ProcessModels,
               disclosure: AllowDisclosure,
               model_client: ProcessModel,
               model_enabled?: false,
               retry_base_ms: 1,
               retry_max_ms: 2
             )

    on_exit(fn -> if Process.alive?(composer_pid), do: GenServer.stop(composer_pid) end)
    assert_receive {:recovery_started, composer_pid}, 1_000
    assert :ok = ReportComposer.enqueue(claim.parent.id, composer_pid)
    send(composer_pid, :allow_recovery)
    assert_receive :claim_after_recovery, 1_000
    assert_selected_fallback(store, claim, :model_disabled)
    assert Process.alive?(composer_pid)
  end

  test "transient recover, claim, and select failures retry without restart or a second model call" do
    claim = claim_with_test_pid()

    store =
      start_supervised!(
        {Agent,
         fn ->
           %{
             recover_results: [{:error, transient_connection_error()}, {:ok, 0}],
             claim_results: [
               {:error, %Exqlite.Error{message: "database is locked"}},
               {:ok, claim},
               :none
             ],
             select_results: [
               {:error, %DBConnection.OwnershipError{message: "temporary ownership loss"}},
               :ok
             ],
             recoveries: 0,
             claims: 0,
             selects: 0,
             selected: []
           }
         end}
      )

    composer_pid =
      start_process_composer(
        store: {RetryStore, store},
        disclosure: AllowDisclosure,
        model_client: ProcessModel,
        model_enabled?: true,
        retry_base_ms: 1,
        retry_max_ms: 2,
        max_retry_attempts: 3
      )

    assert_receive {:process_compose, _, _}, 1_000

    assert eventually(fn ->
             Agent.get(store, &match?(%{selected: [_], recoveries: 2, claims: 3, selects: 2}, &1))
           end)

    assert Process.alive?(composer_pid)
    refute_receive {:process_compose, _, _}, 100
  end

  test "bounded recovery retry exhaustion leaves one live degraded process without a restart loop" do
    store =
      start_supervised!(
        {Agent,
         fn ->
           %{
             recover_results: List.duplicate({:error, transient_connection_error()}, 4),
             recoveries: 0
           }
         end}
      )

    composer_pid =
      start_process_composer(
        store: {RetryStore, store},
        model_enabled?: false,
        retry_base_ms: 1,
        retry_max_ms: 2,
        max_retry_attempts: 2
      )

    assert eventually(fn -> :sys.get_state(composer_pid).phase == :degraded end)
    assert Agent.get(store, & &1.recoveries) == 3
    Process.sleep(20)
    assert Agent.get(store, & &1.recoveries) == 3
    assert Process.alive?(composer_pid)
  end

  test "raised and exited transient store failures normalize into bounded in-process retries" do
    claim = claim_with_test_pid()

    store =
      start_supervised!(
        {Agent,
         fn ->
           %{claim: claim, claims: 0, recoveries: 0, selected: []}
         end}
      )

    composer_pid =
      start_process_composer(
        store: {RaisedExitStore, store},
        disclosure: AllowDisclosure,
        model_client: ProcessModel,
        model_enabled?: true,
        retry_base_ms: 1,
        retry_max_ms: 2,
        max_retry_attempts: 3
      )

    assert_receive {:process_compose, _, _}, 1_000

    assert eventually(fn ->
             Agent.get(store, &match?(%{selected: [_], recoveries: 2, claims: 3}, &1))
           end)

    assert Process.alive?(composer_pid)
    refute_receive {:process_compose, _, _}, 100
  end

  test "a nontransient store exit remains crash-visible instead of entering retry" do
    previous = Process.flag(:trap_exit, true)
    on_exit(fn -> Process.flag(:trap_exit, previous) end)
    name = :"fanout-report-composer-#{System.unique_integer([:positive])}"

    assert {:ok, composer_pid} =
             ReportComposer.start_link(
               name: name,
               store: {NonTransientExitStore, self()},
               model_enabled?: false
             )

    assert_receive {:EXIT, ^composer_pid, :invalid_store_contract}, 1_000
  end

  test "successful reconciliation resets stale retry counters for every operation" do
    store = process_store([])

    composer_pid =
      start_process_composer(
        store: {ProcessStore, store},
        model_enabled?: false,
        reconcile_interval_ms: 5_000
      )

    assert eventually(fn -> :sys.get_state(composer_pid).phase == :ready end)

    :sys.replace_state(composer_pid, fn state ->
      %{state | retry_attempts: %{recover: 2, claim: 3, select: 4}}
    end)

    assert :ok = ReportComposer.reconcile("retry-reset-parent", composer_pid)

    assert eventually(fn ->
             state = :sys.get_state(composer_pid)
             state.phase == :ready and state.retry_attempts == %{recover: 0, claim: 0, select: 0}
           end)
  end

  test "periodic durable reconciliation repairs a queued row whose enqueue wake was lost" do
    claim = claim_with_test_pid()
    store = process_store([])

    composer_pid =
      start_process_composer(
        store: {ProcessStore, store},
        disclosure: AllowDisclosure,
        model_client: ProcessModel,
        model_enabled?: true,
        reconcile_interval_ms: 20
      )

    assert eventually(fn ->
             Agent.get(store, &(&1.recoveries == 1 and &1.claim_attempts >= 1))
           end)

    Agent.update(store, &Map.put(&1, :claims, [claim]))

    assert_receive {:process_compose, _, _}, 1_000
    assert eventually(fn -> Agent.get(store, &match?(%{selected: [_]}, &1)) end)
    assert Agent.get(store, & &1.recoveries) >= 2
    assert Process.alive?(composer_pid)
    refute_receive {:process_compose, _, _}, 100
  end

  test "periodic cooldown rearms a degraded composer after bounded transient retries" do
    claim = claim_with_test_pid()

    store =
      start_supervised!(
        {Agent,
         fn ->
           %{
             recover_results: [
               {:error, transient_connection_error()},
               {:error, transient_connection_error()},
               {:ok, 0},
               {:ok, 0},
               {:ok, 0}
             ],
             claim_results: [{:ok, claim}, :none, :none],
             select_results: [:ok],
             recoveries: 0,
             claims: 0,
             selects: 0,
             selected: []
           }
         end}
      )

    composer_pid =
      start_process_composer(
        store: {RetryStore, store},
        disclosure: AllowDisclosure,
        model_client: ProcessModel,
        model_enabled?: true,
        retry_base_ms: 1,
        retry_max_ms: 1,
        max_retry_attempts: 1,
        reconcile_interval_ms: 100
      )

    assert eventually(fn ->
             Agent.get(store, & &1.recoveries) == 2 and
               :sys.get_state(composer_pid).phase == :degraded
           end)

    Process.sleep(30)
    assert Agent.get(store, & &1.recoveries) == 2

    assert_receive {:process_compose, _, _}, 1_000
    assert eventually(fn -> Agent.get(store, &match?(%{selected: [_], recoveries: 3}, &1)) end)
    assert Process.alive?(composer_pid)
    refute_receive {:process_compose, _, _}, 100
  end

  test "disclosure denial selects the frozen fallback without making a provider call" do
    claim = claim_with_test_pid()
    store = process_store([claim])

    start_process_composer(
      store: {ProcessStore, store},
      disclosure: DenyDisclosure,
      model_client: UnexpectedProcessModel,
      model_enabled?: true
    )

    assert_receive {:disclosure_checked, %{name: "direct_answer_local"}}, 1_000
    assert_selected_fallback(store, claim, :transport_denied)
    refute_received :unexpected_process_compose
  end

  test "one failed provider call selects the frozen fallback without uncertain retry" do
    claim = claim_with_test_pid()
    store = process_store([claim])

    start_process_composer(
      store: {ProcessStore, store},
      disclosure: AllowDisclosure,
      model_client: FailingProcessModel,
      model_enabled?: true
    )

    assert_receive {:failed_process_compose, snapshot}, 1_000
    assert snapshot == claim.frozen.snapshot
    assert_selected_fallback(store, claim, :provider_failed)
    refute_receive {:failed_process_compose, _}, 100
  end

  test "an exhausted composition deadline records its distinct closed fallback category" do
    claim = %{claim_with_test_pid() | deadline_unix_ms: System.system_time(:millisecond) - 1}
    store = process_store([claim])

    start_process_composer(
      store: {ProcessStore, store},
      disclosure: AllowDisclosure,
      model_client: UnexpectedProcessModel,
      model_enabled?: true
    )

    assert_selected_fallback(store, claim, :deadline_exhausted)
    refute_received :unexpected_process_compose
  end

  test "a corrupt durable budget records invalid snapshot without making a provider call" do
    claim =
      claim_with_test_pid()
      |> put_in([:budget, "configured_output_tokens"], "[REDACTED]")

    store = process_store([claim])

    start_process_composer(
      store: {ProcessStore, store},
      disclosure: AllowDisclosure,
      model_client: UnexpectedProcessModel,
      model_enabled?: true
    )

    assert_selected_fallback(store, claim, :invalid_budget_snapshot)
    refute_received :unexpected_process_compose
  end

  test "an unavailable synthesis profile records the closed resolution fallback category" do
    claim = claim_with_test_pid()
    store = process_store([claim])

    start_process_composer(
      store: {ProcessStore, store},
      models: UnavailableModels,
      disclosure: AllowDisclosure,
      model_client: UnexpectedProcessModel,
      model_enabled?: true
    )

    assert_selected_fallback(store, claim, :profile_unavailable)
    refute_received :unexpected_process_compose
  end

  test "incomplete model selection records invalid output after exactly one call" do
    claim = claim_with_test_pid()
    store = process_store([claim])

    start_process_composer(
      store: {ProcessStore, store},
      disclosure: AllowDisclosure,
      model_client: InvalidProcessModel,
      model_enabled?: true
    )

    assert_receive {:invalid_process_compose, snapshot}, 1_000
    assert snapshot == claim.frozen.snapshot
    assert_selected_fallback(store, claim, :invalid_model_output)
    refute_receive {:invalid_process_compose, _}, 100
  end

  test "model output that adds prose and false effect claims falls back after exactly one call" do
    claim = claim_with_test_pid()
    store = process_store([claim])

    start_process_composer(
      store: {ProcessStore, store},
      disclosure: AllowDisclosure,
      model_client: ClaimingProcessModel,
      model_enabled?: true
    )

    assert_receive {:claiming_process_compose, snapshot}, 1_000
    assert snapshot == claim.frozen.snapshot
    assert_selected_fallback(store, claim, :invalid_model_output)
    refute_receive {:claiming_process_compose, _}, 100
  end

  test "report rejects prose, unknown fields, invalid sections, and incomplete partitions" do
    snapshot = completed_snapshot(3)

    invalid_selections = [
      "All children succeeded and an email was sent.",
      %{
        "sections" => [
          %{"relationship" => "complementary", "ordered_queue_positions" => [0, 1, 2]}
        ],
        "summary" => "All children succeeded and an email was sent."
      },
      %{
        "sections" => [
          %{
            "relationship" => "complementary",
            "ordered_queue_positions" => [0, 1, 2],
            "summary" => "All succeeded and an email was sent."
          }
        ]
      },
      %{
        "sections" => [
          %{"relationship" => "complementary", "ordered_queue_positions" => [0, 1]},
          %{"relationship" => "independent", "ordered_queue_positions" => [1]}
        ]
      },
      %{
        "sections" => [
          %{"relationship" => "complementary", "ordered_queue_positions" => [0, 9]},
          %{"relationship" => "independent", "ordered_queue_positions" => [2]}
        ]
      },
      %{
        "sections" => [
          %{"relationship" => "complementary", "ordered_queue_positions" => [0, 1]}
        ]
      },
      %{
        "sections" => [
          %{"relationship" => "complementary", "ordered_queue_positions" => [0]},
          %{"relationship" => "supporting", "ordered_queue_positions" => [1, 2]}
        ]
      },
      %{
        "sections" => [
          %{"relationship" => "independent", "ordered_queue_positions" => [0, 1]},
          %{"relationship" => "independent", "ordered_queue_positions" => [2]}
        ]
      },
      %{
        "sections" => [
          %{"relationship" => "independent", "ordered_queue_positions" => [0]},
          %{"relationship" => "independent", "ordered_queue_positions" => [1]},
          %{"relationship" => "independent", "ordered_queue_positions" => [2]}
        ]
      },
      %{
        "sections" => [
          %{"relationship" => "invented", "ordered_queue_positions" => [0, 1]},
          %{"relationship" => "independent", "ordered_queue_positions" => [2]}
        ]
      }
    ]

    Enum.each(invalid_selections, fn selection ->
      assert {:error, _reason} = Report.compose(snapshot, selection)
    end)
  end

  test "partial report renders non-completed children first outside model-controlled sections" do
    snapshot = legacy_claim_snapshot()

    assert {:ok, body} =
             Report.compose(snapshot, %{
               "sections" => [
                 %{"relationship" => "independent", "ordered_queue_positions" => [0]}
               ]
             })

    assert body =~ "Child status totals: completed=1; failed=1; cancelled=0; abandoned=0."
    assert body =~ "Attention required (not model-arranged):"
    assert body =~ "Independent finding:"
    assert body =~ "Child-reported observation (not effect evidence): provider failed"
    assert body =~ "Child-reported observation (not effect evidence): child-result-sentinel"
    assert position(body, "Attention required") < position(body, "Independent finding:")
    assert position(body, "Second child [failed]") < position(body, "First child [completed]")
    refute body =~ "email was sent"

    provenance = %{
      model_profile: "direct_answer_local",
      provider: "local_ollama",
      model: "qwen2.5:7b",
      layout_version: 1,
      sections: [%{relationship: "independent", ordered_queue_positions: [0]}]
    }

    assert :ok = Report.validate_selected_body(snapshot, "model", body, provenance)

    assert {:error, _reason} =
             Report.validate_selected_body(
               snapshot,
               "model",
               body,
               %{provenance | layout_version: 2}
             )
  end

  test "valid N-child grouping renders bounded relationships from exact titles and objectives" do
    snapshot = completed_snapshot(3)

    selection = %{
      "sections" => [
        %{"relationship" => "complementary", "ordered_queue_positions" => [0, 1]},
        %{"relationship" => "independent", "ordered_queue_positions" => [2]}
      ]
    }

    assert {:ok, prepared} = Report.prepare_composition(snapshot, selection)
    assert prepared.layout.layout_version == 1

    assert prepared.layout.sections == [
             %{relationship: "complementary", ordered_queue_positions: [0, 1]},
             %{relationship: "independent", ordered_queue_positions: [2]}
           ]

    body = prepared.body
    assert body =~ "Complementary findings:"
    assert body =~ "Selected relationship: complementary."
    assert body =~ ~s|"OTP supervision isolation" (objective: "Explain process isolation.")|
    assert body =~ ~s|"Event-log recovery" (objective: "Explain durable event recovery.")|
    assert body =~ "as complementary parts of the request."
    assert body =~ "Independent finding:"
    assert body =~ "Operator recovery guidance"
    assert body =~ "✓ OTP supervision isolation [completed]"
    assert body =~ "✓ Event-log recovery [completed]"
    assert body =~ "✓ Operator recovery guidance [completed]"
    assert body =~ "Effect verification comes only from the authoritative"
  end

  defp snapshot do
    %{
      title: "Compose one child",
      original_request: "operator-request-sentinel",
      status: "completed",
      join_outcome: "success",
      children: [
        %{
          queue_position: 0,
          title: "First child",
          objective: "Analyze one independent concern",
          status: "completed",
          detail: "child-result-sentinel"
        }
      ]
    }
  end

  defp profile do
    %{
      name: "direct_answer_local",
      provider_type: "openai_compatible",
      model: "qwen2.5:7b",
      temperature: 0.9,
      max_tokens: 8_192,
      timeout_ms: 60_000,
      provider_base_url: "http://localhost:11434/v1",
      provider_api_key_ref: nil
    }
  end

  defp claim do
    {parent, children} = claim_objectives()

    child_authorities =
      Map.new(children, fn child ->
        {child.id,
         %{
           result_authority: "registered_action",
           quality_receipt_sha256: nil
         }}
      end)

    assert {:ok, frozen} = Report.freeze_v2(parent, children, %{}, child_authorities)

    assert {:ok, budget} =
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

  defp claim_objectives do
    parent = %Objective{
      id: "fanout_process_parent",
      title: "Compose both children",
      objective: "operator-request-sentinel",
      fanout_role: "parent",
      status: "completed",
      join_outcome: "partial",
      proposer_hint: Jason.encode!(%{"fanout_plan" => %{"version" => 1}})
    }

    children = [
      %Objective{
        id: "fanout_process_child_1",
        queue_position: 0,
        title: "First child",
        objective: "First objective",
        fanout_role: "child",
        status: "completed",
        last_observation_summary: "child-result-sentinel"
      },
      %Objective{
        id: "fanout_process_child_2",
        queue_position: 1,
        title: "Second child",
        objective: "Second objective",
        fanout_role: "child",
        status: "failed",
        review_reason: "provider failed"
      }
    ]

    {parent, children}
  end

  defp legacy_claim_snapshot do
    {parent, children} = claim_objectives()
    assert {:ok, frozen} = Report.freeze(parent, children)
    frozen.snapshot
  end

  defp claim_with_test_pid do
    claim = claim()
    %{claim | context: Map.put(claim.context, :test_pid, self())}
  end

  defp durable_plan do
    assert {:ok, budget} =
             Budget.resolve(2, 1, %{
               version: 1,
               max_model_calls: 40,
               max_output_tokens: 24_000,
               max_elapsed_ms: 300_000,
               max_worker_attempts_per_child: 2
             })

    %{
      "version" => 1,
      "source" => "conversation_manager",
      "original_request_sha256" => String.duplicate("a", 64),
      "plan_sha256" => String.duplicate("b", 64),
      "manager_profile" => "direct_answer_local",
      "manager_profile_sha256" => String.duplicate("c", 64),
      "manager_attempts" => 1,
      "budget" => budget,
      "deadline_unix_ms" => System.system_time(:millisecond) + 300_000
    }
  end

  defp frame_durable_fanout(user_id, thread_id, plan) do
    Fanout.frame(
      %{
        user_id: user_id,
        title: "Compose durable children",
        objective: "Analyze two independent mechanisms.",
        source_channel: "test",
        source_thread_id: thread_id,
        proposer_hint: %{"fanout_plan" => plan}
      },
      [
        %{title: "First", objective: "Analyze first", expected_result: "First result"},
        %{title: "Second", objective: "Analyze second", expected_result: "Second result"}
      ]
    )
  end

  defp complete_registered_action_child!(child, summary, trace_id) do
    assert {:ok, step} =
             Objectives.create_step(%{
               objective_id: child.id,
               kind: "action",
               status: "completed",
               stage: "execute_step",
               candidate_action: "append_memory",
               result_summary: summary,
               trace_id: trace_id
             })

    assert {:ok, transition} =
             TerminalTransitions.terminalize_child(
               child,
               %{
                 status: "completed",
                 current_step_id: step.id,
                 last_observation_summary: summary,
                 completed_at: DateTime.utc_now()
               },
               "run_completed",
               %{
                 summary: String.slice(summary, 0, 500),
                 step_id: step.id,
                 step_status: "completed"
               }
             )

    transition
  end

  defp completed_snapshot(count) when count in 2..3 do
    base = legacy_claim_snapshot()

    fixtures = [
      {"fanout_process_child_1", "OTP supervision isolation", "Explain process isolation.",
       "Each child runs under isolated OTP supervision."},
      {"fanout_process_child_2", "Event-log recovery", "Explain durable event recovery.",
       "Committed events allow recovery after interruption."},
      {"fanout_process_child_3", "Operator recovery guidance", "Explain operator recovery.",
       "The operator can inspect and resume durable work."}
    ]

    children =
      fixtures
      |> Enum.take(count)
      |> Enum.with_index()
      |> Enum.map(fn {{id, title, objective, detail}, queue_position} ->
        %{
          id: id,
          queue_position: queue_position,
          title: title,
          objective: objective,
          expected_result: nil,
          status: "completed",
          detail: detail,
          effect_receipt_ref: nil
        }
      end)

    %{base | status: "completed", join_outcome: "success", children: children}
  end

  defp process_store(claims) do
    start_supervised!({Agent, fn -> %{claims: claims, selected: [], recoveries: 0} end})
  end

  defp start_process_composer(opts) do
    name = :"fanout-report-composer-#{System.unique_integer([:positive])}"

    defaults = [
      name: name,
      models: ProcessModels,
      model_context: %{test_pid: self()}
    ]

    start_supervised!({ReportComposer, Keyword.merge(defaults, opts)})
  end

  defp assert_selected_fallback(store, claim, reason) do
    assert {:ok, expected_provenance} =
             Report.fallback_provenance(claim.frozen.snapshot, reason)

    assert eventually(fn ->
             store
             |> Agent.get(& &1)
             |> selected_fallback?(claim, expected_provenance)
           end)
  end

  defp selected_fallback?(
         %{
           selected: [
             {claim, "deterministic_fallback", body, provenance}
           ]
         },
         claim,
         expected_provenance
       ),
       do: body == claim.frozen.fallback_body and provenance == expected_provenance

  defp selected_fallback?(_state, _claim, _expected_provenance), do: false

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

  defp position(text, pattern) do
    {position, _length} = :binary.match(text, pattern)
    position
  end

  defp occurrence_count(body, text), do: body |> :binary.matches(text) |> length()

  defp message_text(message) do
    message.content
    |> Enum.filter(&(&1.type == :text))
    |> Enum.map_join("", & &1.text)
  end

  defp transient_connection_error do
    %DBConnection.ConnectionError{
      message: "temporary database connection loss",
      reason: :error,
      severity: :error
    }
  end
end
