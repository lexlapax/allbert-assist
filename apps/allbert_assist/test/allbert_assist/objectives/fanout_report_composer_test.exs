defmodule AllbertAssist.Objectives.Fanout.ReportComposerTest do
  use AllbertAssist.DataCase, async: false
  @moduletag :db_serial

  alias AllbertAssist.Objectives.Fanout.Budget
  alias AllbertAssist.Objectives.Fanout.Report
  alias AllbertAssist.Objectives.Fanout.ReportComposer
  alias AllbertAssist.Objectives.Fanout.ReportComposer.ReqLLMImplementation
  alias AllbertAssist.Objectives.Objective
  alias ReqLLM.Response

  defmodule CaptureClient do
    def generate_object(spec, prompt, schema, opts) do
      send(Keyword.fetch!(opts, :test_pid), {:compose_call, spec, prompt, schema, opts})

      {:ok,
       %Response{
         id: "fanout-composition",
         model: "fixture-model",
         context: prompt,
         object: %{
           "sections" => [
             %{"relationship" => "independent", "ordered_queue_positions" => [0]}
           ]
         },
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
       %{
         "sections" => [
           %{"relationship" => "independent", "ordered_queue_positions" => [0]}
         ]
       }}
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
    assert {:ok,
            %{
              "sections" => [
                %{"relationship" => "independent", "ordered_queue_positions" => [0]}
              ]
            }} =
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
    refute system =~ "operator-request-sentinel"
    assert advisory =~ "operator-request-sentinel"
    assert advisory =~ "child-result-sentinel"

    assert List.last(prompt.messages).metadata.allbert_prompt == %{
             schema_version: 1,
             purpose: :fanout_report_composition,
             content_class: :advisory_data,
             rule_ids: [
               :typed_selection_only,
               :exact_completed_child_partition,
               :meaningful_relationship,
               :relationship_cardinality,
               :layout_only,
               :no_fact_or_effect_claims,
               :no_nested_fanout
             ]
           }

    assert schema[:sections][:required]
    assert {:list, {:map, section_schema}} = schema[:sections][:type]

    assert section_schema[:relationship][:type] ==
             {:in, ~w[complementary contrasting sequential supporting independent]}

    assert section_schema[:relationship][:required]
    assert section_schema[:ordered_queue_positions][:type] == {:list, :integer}
    assert section_schema[:ordered_queue_positions][:required]
    assert opts[:temperature] == 0.0
    assert opts[:max_tokens] == 1_024
    assert opts[:receive_timeout] == 5_000
    assert opts[:openai_structured_output_mode] == :json_schema
    assert opts[:json_repair] == false
    refute_received {:compose_call, _, _, _, _}
  end

  test "adapter refusal and truncated structured output fail closed without repair" do
    context = %{timeout_ms: 5_000, max_output_tokens: 1_024}

    assert {:error, :structured_output_refusal} =
             ReqLLMImplementation.compose(
               snapshot(),
               profile(),
               Map.put(context, :req_llm_client, RefusalClient)
             )

    assert {:error, {:incomplete_composition_response, :length}} =
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
    assert body =~ "Independent finding:"
    assert body =~ "Selected relationship: independent."
    assert body =~ ~s|"First child" (objective: "First objective")|
    assert body =~ "Child-reported observation (not effect evidence): child-result-sentinel"
    assert body =~ "Child-reported observation (not effect evidence): provider failed"
    assert body =~ "Authoritative child results (ordered):"
    assert body =~ "✓ First child [completed] — Child-reported observation"
    assert body =~ "✗ Second child [failed] — Child-reported observation"

    assert provenance == %{
             model_profile: "direct_answer_local",
             provider: "local_ollama",
             model: "qwen2.5:7b",
             layout_version: 1,
             sections: [%{relationship: "independent", ordered_queue_positions: [0]}]
           }

    refute_received {:process_compose, _, _}
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

  test "an exhausted composition deadline records the closed budget fallback category" do
    claim = %{claim_with_test_pid() | deadline_unix_ms: System.system_time(:millisecond) - 1}
    store = process_store([claim])

    start_process_composer(
      store: {ProcessStore, store},
      disclosure: AllowDisclosure,
      model_client: UnexpectedProcessModel,
      model_enabled?: true
    )

    assert_selected_fallback(store, claim, :budget_denied)
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
    snapshot = claim().frozen.snapshot

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
    assert body =~ "Child 1: OTP supervision isolation [completed]"
    assert body =~ "Child 2: Event-log recovery [completed]"
    assert body =~ "Child 3: Operator recovery guidance [completed]"
    assert body =~ "Effect verification comes only from the authoritative"
  end

  defp snapshot do
    %{
      "parent_id" => "parent-1",
      "original_request" => "operator-request-sentinel",
      "plan" => [
        %{
          "position" => 1,
          "title" => "First child",
          "objective" => "Analyze one independent concern",
          "expected_result" => "A bounded finding"
        }
      ],
      "children" => [
        %{
          "position" => 1,
          "title" => "First child",
          "status" => "completed",
          "result" => "child-result-sentinel",
          "effect_receipt" => nil
        }
      ],
      "join_outcome" => "success",
      "input_digest" => String.duplicate("a", 64)
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

    assert {:ok, frozen} = Report.freeze(parent, children)

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

  defp claim_with_test_pid do
    claim = claim()
    %{claim | context: Map.put(claim.context, :test_pid, self())}
  end

  defp completed_snapshot(count) when count in 2..3 do
    base = claim().frozen.snapshot

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
    assert eventually(fn ->
             Agent.get(store, fn state ->
               match?(
                 %{
                   selected: [
                     {^claim, "deterministic_fallback", body, %{fallback_reason: ^reason}}
                   ]
                 }
                 when body == claim.frozen.fallback_body,
                 state
               )
             end)
           end)
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

  defp position(text, pattern) do
    {position, _length} = :binary.match(text, pattern)
    position
  end

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
