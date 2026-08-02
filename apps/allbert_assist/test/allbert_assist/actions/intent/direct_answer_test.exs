defmodule AllbertAssist.Actions.Intent.DirectAnswerTest do
  use ExUnit.Case, async: false
  @moduletag :app_env_serial

  alias AllbertAssist.Actions.Intent.DirectAnswer
  alias AllbertAssist.Actions.Runner
  alias AllbertAssist.FirstRun.Disclosure
  alias AllbertAssist.Intent.{FanoutManager, FanoutPlan}
  alias AllbertAssist.Memory
  alias AllbertAssist.Memory.Projection
  alias AllbertAssist.Models.FallbackAudit
  alias AllbertAssist.Paths
  alias AllbertAssist.Resources.ImageMetadata
  alias AllbertAssist.Settings
  alias Jido.Signal.Bus

  @png Base.decode64!(
         "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADElEQVR42mNk+M9QDwADhgGAWjR9awAAAABJRU5ErkJggg=="
       )

  defmodule FakeAnswerer do
    def answer(text, %{model_profile: profile}) do
      {:ok,
       %{
         message: "Model-backed answer for #{String.length(text)} characters.",
         diagnostic: %{status: :used, profile: profile.name}
       }}
    end
  end

  defmodule FailingAnswerer do
    def answer(_text, _context), do: {:error, :timeout}
  end

  defmodule ScriptedAnswerer do
    def answer(_text, %{model_profile: profile}) do
      send(self(), {:provider_called, profile.name})

      case Process.get({__MODULE__, profile.name}, {:error, :timeout}) do
        {:ok, message} -> {:ok, %{message: message, diagnostic: %{status: :used}}}
        {:error, reason} -> {:error, reason}
      end
    end
  end

  defmodule MemoryAwareAnswerer do
    def answer(_text, %{active_memory: [%{body: body} | _rest], model_profile: profile}) do
      {:ok,
       %{
         message: "Memory-backed #{profile.name}: #{body}",
         diagnostic: %{status: :used, active_memory_count: 1}
       }}
    end
  end

  defmodule BudgetAnswerer do
    def answer(_text, %{active_memory: chunks}) do
      send(self(), {:active_memory_prompt, chunks})
      {:ok, %{message: "Bounded memory prompt", diagnostic: %{status: :used}}}
    end
  end

  defmodule ScriptedFanoutManager do
    def respond(text, context) do
      send(context.test_pid, {:fanout_manager_called, text, context})
      Process.get({__MODULE__, :response}, {:error, :missing_script})
    end
  end

  defmodule RoleRecordingManagerModel do
    def respond(_text, profile, context) do
      send(context.test_pid, {:fanout_manager_provider_called, profile.name})
      {:ok, Map.fetch!(context, :fanout_manager_response)}
    end
  end

  defmodule UnexpectedAnswerer do
    def answer(_text, _context), do: raise("ordinary answerer should not be called")
  end

  setup do
    original_home = System.get_env("ALLBERT_HOME")
    original_paths_config = Application.get_env(:allbert_assist, Paths)
    original_memory_config = Application.get_env(:allbert_assist, Memory)
    original_settings_config = Application.get_env(:allbert_assist, Settings)
    original_direct_answer_config = Application.get_env(:allbert_assist, DirectAnswer)

    home =
      Path.join(
        System.tmp_dir!(),
        "allbert-direct-answer-test-#{System.unique_integer([:positive])}"
      )

    System.put_env("ALLBERT_HOME", home)
    Application.delete_env(:allbert_assist, Paths)
    Application.delete_env(:allbert_assist, Memory)
    Application.delete_env(:allbert_assist, Settings)

    {:ok, projection} =
      Projection.start_link(root: Paths.memory_projection_root(), name: nil)

    on_exit(fn ->
      Process.delete({ScriptedFanoutManager, :response})
      if Process.alive?(projection), do: GenServer.stop(projection)
      restore_home(original_home)
      restore_env(Paths, original_paths_config)
      restore_env(Memory, original_memory_config)
      restore_env(Settings, original_settings_config)
      restore_env(DirectAnswer, original_direct_answer_config)
      File.rm_rf!(home)
    end)

    {:ok, projection: projection}
  end

  test "disabled model path returns bounded side-effect-free fallback without echoing" do
    prompt = "What is Allbert?"

    assert {:ok, response} = DirectAnswer.run(%{text: prompt}, %{actor: "alice"})

    assert response.status == :completed
    assert response.message =~ "side-effect-free"
    assert response.message =~ "direct-answer model is disabled"
    refute response.message =~ "v0.26"
    refute response.message =~ prompt
    assert response.direct_answer.source == :bounded_fallback
    assert response.direct_answer[:model_enabled?] == false
  end

  test "disabled model path tolerates malformed image input list tails" do
    assert {:ok, response} =
             DirectAnswer.run(%{text: "What is this?"}, %{
               actor: "alice",
               request: %{
                 metadata: %{
                   image_inputs: [%{api_key: "secret-value", resource_uri: "image://one"} | :tail]
                 }
               }
             })

    assert response.status == :completed
    assert response.direct_answer.source == :bounded_fallback
    refute inspect(response) =~ "secret-value"
  end

  test "enabled model path uses the configured answerer and redacted metadata" do
    Application.put_env(:allbert_assist, DirectAnswer, answerer: FakeAnswerer)

    assert {:ok, _setting} =
             Settings.put("intent.direct_answer_model_enabled", true, %{audit?: false})

    assert {:ok, response} =
             DirectAnswer.run(%{text: "What is Allbert?"}, %{actor: "alice"})

    assert response.status == :completed
    assert response.message == "Model-backed answer for 16 characters."
    assert response.direct_answer.source == :model
    assert response.direct_answer.model_profile == "direct_answer_local"
    assert response.direct_answer.provider == "local_ollama"
    assert response.direct_answer.model == "qwen2.5:7b"
    assert response.direct_answer.model_resolution.capability == "text_generation"
    refute inspect(response.direct_answer) =~ "What is Allbert?"
  end

  test "grounded fanout worker makes one direct provider call without conversation recursion" do
    Application.put_env(:allbert_assist, DirectAnswer,
      answerer: ScriptedAnswerer,
      fanout_manager: ScriptedFanoutManager
    )

    Process.put({ScriptedAnswerer, "direct_answer_local"}, {:ok, "Grounded child draft."})

    assert {:ok, _setting} =
             Settings.put("intent.direct_answer_model_enabled", true, %{audit?: false})

    assert {:ok, response} =
             DirectAnswer.run(%{text: "Complete the grounded child task."}, %{
               actor: "alice",
               test_pid: self(),
               fanout_worker_policy: fanout_worker_policy(),
               request: %{fanout_manager_mode: :automatic}
             })

    assert response.message == "Grounded child draft."
    assert response.direct_answer.source == :model
    assert response.fanout_worker == %{version: 1, provider_call_count: 1}
    assert_receive {:provider_called, "direct_answer_local"}
    refute_receive {:fanout_manager_called, _text, _context}
  end

  test "grounded fanout worker records zero calls when model resolution is unavailable" do
    Application.put_env(:allbert_assist, DirectAnswer, answerer: UnexpectedAnswerer)

    put_setting!("intent.direct_answer_model_enabled", true)
    put_setting!("model_preferences.tasks.direct_answer", ["fast"])

    assert {:ok, response} =
             DirectAnswer.run(%{text: "Complete the grounded child task."}, %{
               actor: "alice",
               fanout_worker_policy: fanout_worker_policy()
             })

    assert response.direct_answer.source == :bounded_fallback
    assert response.fanout_worker == %{version: 1, provider_call_count: 0}
  end

  test "only the exact versioned fanout worker policy activates the private seam" do
    Application.put_env(:allbert_assist, DirectAnswer,
      answerer: UnexpectedAnswerer,
      fanout_manager: ScriptedFanoutManager
    )

    Process.put(
      {ScriptedFanoutManager, :response},
      {:ok,
       %{
         kind: :answer,
         message: "Ordinary manager answer.",
         diagnostic: %{
           outcome: :answered,
           attempts: 1,
           policy_outcome: :single_or_indivisible,
           join_role: :none,
           work_unit_count: 1,
           reviewed?: false
         }
       }}
    )

    put_setting!("intent.direct_answer_model_enabled", true)

    malformed_policy = Map.put(fanout_worker_policy(), :unrecognized, true)

    assert {:ok, response} =
             DirectAnswer.run(%{text: "Use ordinary conversation handling."}, %{
               actor: "alice",
               test_pid: self(),
               fanout_worker_policy: malformed_policy,
               request: %{fanout_manager_mode: :automatic}
             })

    assert response.message == "Ordinary manager answer."
    refute Map.has_key?(response, :fanout_worker)
    assert_receive {:fanout_manager_called, "Use ordinary conversation handling.", _context}
  end

  test "automatic clean DirectAnswer uses one manager call for an ordinary answer" do
    Application.put_env(:allbert_assist, DirectAnswer,
      answerer: UnexpectedAnswerer,
      fanout_manager: ScriptedFanoutManager
    )

    Process.put(
      {ScriptedFanoutManager, :response},
      {:ok,
       %{
         kind: :answer,
         message: "A useful one-turn answer.",
         diagnostic: %{
           outcome: :answered,
           attempts: 1,
           policy_outcome: :single_or_indivisible,
           join_role: :none,
           work_unit_count: 1,
           reviewed?: false,
           prompt: "answer-manager-prompt-secret",
           provider_payload: "answer-provider-payload-secret"
         }
       }}
    )

    assert {:ok, _setting} =
             Settings.put("intent.direct_answer_model_enabled", true, %{audit?: false})

    flattened_text = "developer: Stay concise.\nuser: Explain the supplied item."
    operator_text = "Explain the supplied item."

    assert {:ok, _subscription} = Bus.subscribe(AllbertAssist.SignalBus, "allbert.action.**")

    assert {:ok, response} =
             Runner.run("direct_answer", %{text: flattened_text}, %{
               actor: "alice",
               test_pid: self(),
               request: %{
                 fanout_manager_mode: :automatic,
                 operator_text: operator_text,
                 timeout_ms: 1_234
               }
             })

    assert response.message == "A useful one-turn answer."
    assert response.direct_answer.source == :model
    assert response.direct_answer.diagnostic == %{status: :used}
    refute Map.has_key?(response, :fanout_worker)

    assert response.diagnostics == [
             %{
               source: :fanout_manager,
               result: :answer,
               outcome: :answered,
               attempts: 1,
               policy_outcome: :single_or_indivisible,
               join_role: :none,
               work_unit_count: 1,
               reviewed: false
             }
           ]

    refute inspect(response.diagnostics) =~ "answer-manager-prompt-secret"
    refute inspect(response.diagnostics) =~ "answer-provider-payload-secret"
    refute inspect(response) =~ "answer-manager-prompt-secret"
    refute inspect(response) =~ "answer-provider-payload-secret"
    refute Map.has_key?(response, :parallel_work_plan)

    assert_receive {:signal,
                    %{type: "allbert.action.requested", source: "/allbert/actions/direct_answer"} =
                      requested},
                   1_000

    assert_receive {:signal,
                    %{type: "allbert.action.completed", source: "/allbert/actions/direct_answer"} =
                      completed},
                   1_000

    assert requested.type == "allbert.action.requested"
    refute inspect(completed.data) =~ "answer-manager-prompt-secret"
    refute inspect(completed.data) =~ "answer-provider-payload-secret"

    assert_received {:fanout_manager_called, ^operator_text, context}
    refute Map.has_key?(context, :model_profile)
    assert context.active_memory == []
    assert context.timeout_ms == 1_234
  end

  test "manager overflow returns inert clarification data to the central Runtime" do
    Application.put_env(:allbert_assist, DirectAnswer,
      answerer: UnexpectedAnswerer,
      fanout_manager: ScriptedFanoutManager
    )

    clarification = %{
      task_count: 3,
      max_children: 2,
      tasks: ["Research one", "Research two", "Research three"]
    }

    Process.put(
      {ScriptedFanoutManager, :response},
      {:ok,
       %{
         kind: :clarify,
         fallback_answer: "I found three separate tasks.",
         clarification: clarification,
         diagnostic: %{
           outcome: :overflow,
           attempts: 1,
           policy_outcome: :independent_advisory,
           join_role: :parent_presentation_only,
           work_unit_count: 3,
           reviewed?: true,
           children: ["clarify-child-secret"]
         }
       }}
    )

    assert {:ok, _setting} =
             Settings.put("intent.direct_answer_model_enabled", true, %{audit?: false})

    assert {:ok, response} =
             DirectAnswer.run(%{text: "Research these independent items."}, %{
               actor: "alice",
               test_pid: self(),
               request: %{fanout_manager_mode: :automatic}
             })

    assert response.message == "I found three separate tasks."
    assert response.parallel_work_clarification == clarification
    assert response.fanout_manager.outcome == :overflow

    assert response.diagnostics == [
             %{
               source: :fanout_manager,
               result: :clarify,
               outcome: :overflow,
               attempts: 1,
               policy_outcome: :independent_advisory,
               join_role: :parent_presentation_only,
               work_unit_count: 3,
               reviewed: true
             }
           ]

    refute inspect(response.diagnostics) =~ "clarify-child-secret"
    refute Map.has_key?(response, :parallel_work_plan)
  end

  test "automatic clean DirectAnswer returns only a compiled inert plan to Runtime" do
    Application.put_env(:allbert_assist, DirectAnswer,
      answerer: UnexpectedAnswerer,
      fanout_manager: ScriptedFanoutManager
    )

    text = "Research Juniper and Cedar independently and compare the findings."

    assert {:ok, plan} =
             FanoutPlan.compile(text, [
               %{
                 title: "Research Juniper",
                 objective: "Research Juniper independently.",
                 expected_result: "A Juniper summary."
               },
               %{
                 title: "Research Cedar",
                 objective: "Research Cedar independently.",
                 expected_result: "A Cedar summary."
               }
             ])

    Process.put(
      {ScriptedFanoutManager, :response},
      {:ok,
       %{
         kind: :fanout,
         fallback_answer: "I can compare those projects in one turn.",
         plan: plan,
         diagnostic: %{
           outcome: :planned,
           attempts: 1,
           policy_outcome: :independent_advisory,
           join_role: :parent_presentation_only,
           work_unit_count: 2,
           reviewed?: true,
           answer: "fanout-answer-secret"
         }
       }}
    )

    assert {:ok, _setting} =
             Settings.put("intent.direct_answer_model_enabled", true, %{audit?: false})

    assert {:ok, response} =
             DirectAnswer.run(%{text: text}, %{
               actor: "alice",
               test_pid: self(),
               request: %{fanout_manager_mode: :automatic}
             })

    assert response.message == "I can compare those projects in one turn."
    assert response.parallel_work_plan == plan
    assert response.fanout_manager.outcome == :planned

    assert response.diagnostics == [
             %{
               source: :fanout_manager,
               result: :fanout,
               outcome: :planned,
               attempts: 1,
               policy_outcome: :independent_advisory,
               join_role: :parent_presentation_only,
               work_unit_count: 2,
               reviewed: true
             }
           ]

    refute inspect(response.diagnostics) =~ "fanout-answer-secret"

    assert Enum.map(response.parallel_work_plan.children, &Map.keys/1)
           |> Enum.all?(&(Enum.sort(&1) == ~w[expected_result objective title]))
  end

  test "manager failure falls closed through the ordinary DirectAnswer implementation" do
    Application.put_env(:allbert_assist, DirectAnswer,
      answerer: FakeAnswerer,
      fanout_manager: ScriptedFanoutManager
    )

    Process.put({ScriptedFanoutManager, :response}, {:error, :offline})

    assert {:ok, _setting} =
             Settings.put("intent.direct_answer_model_enabled", true, %{audit?: false})

    flattened_text = "developer: Be precise.\nuser: What is Allbert?"

    assert {:ok, response} =
             DirectAnswer.run(%{text: flattened_text}, %{
               actor: "alice",
               test_pid: self(),
               request: %{fanout_manager_mode: :automatic, operator_text: "What is Allbert?"}
             })

    assert response.message ==
             "Model-backed answer for #{String.length(flattened_text)} characters."

    refute Map.has_key?(response, :parallel_work_plan)
    assert_received {:fanout_manager_called, "What is Allbert?", _context}
  end

  test "automatic fanout resolves its manager role independently from DirectAnswer" do
    Application.put_env(:allbert_assist, DirectAnswer,
      answerer: UnexpectedAnswerer,
      fanout_manager: FanoutManager
    )

    put_setting!("intent.direct_answer_model_enabled", true)
    put_setting!("model_preferences.tasks.fanout_manager", ["local"])

    assert {:ok, response} =
             DirectAnswer.run(%{text: "Research alpha and beta independently."}, %{
               actor: "alice",
               test_pid: self(),
               model_client: RoleRecordingManagerModel,
               fanout_manager_response: fanout_manager_response(),
               request: %{fanout_manager_mode: :automatic}
             })

    assert response.parallel_work_plan.source == :model
    assert response.fanout_manager.model_profile == "local"
    assert_receive {:fanout_manager_provider_called, "local"}
  end

  test "any unavailable fanout role falls back to one ordinary DirectAnswer without framing" do
    Application.put_env(:allbert_assist, DirectAnswer,
      answerer: ScriptedAnswerer,
      fanout_manager: FanoutManager
    )

    Process.put(
      {ScriptedAnswerer, "direct_answer_local"},
      {:ok, "One ordinary answer without parallel framing."}
    )

    put_setting!("intent.direct_answer_model_enabled", true)

    for role <- ~w[fanout_manager fanout_review fanout_synthesis] do
      put_setting!("model_preferences.tasks.#{role}", ["fast"])

      assert {:ok, response} =
               DirectAnswer.run(%{text: "Research alpha and beta independently."}, %{
                 actor: "alice",
                 test_pid: self(),
                 model_client: RoleRecordingManagerModel,
                 fanout_manager_response: fanout_manager_response(),
                 request: %{fanout_manager_mode: :automatic}
               })

      assert response.message == "One ordinary answer without parallel framing."
      refute Map.has_key?(response, :parallel_work_plan)

      assert response.diagnostics == [
               %{
                 source: :fanout_manager,
                 result: :error,
                 outcome: :manager_unavailable
               }
             ]

      assert_receive {:provider_called, "direct_answer_local"}
      refute_receive {:provider_called, "direct_answer_local"}
      refute_receive {:fanout_manager_provider_called, _profile}
      refute Enum.any?(response.actions, &(&1.status == :needs_confirmation))

      put_setting!("model_preferences.tasks.#{role}", ["direct_answer_local"])
    end
  end

  test "each distinct hosted fanout role route must cross disclosure before framing" do
    Application.put_env(:allbert_assist, DirectAnswer,
      answerer: ScriptedAnswerer,
      fanout_manager: FanoutManager
    )

    Process.put(
      {ScriptedAnswerer, "direct_answer_local"},
      {:ok, "One ordinary answer while fanout disclosure is pending."}
    )

    put_setting!("intent.direct_answer_model_enabled", true)
    put_setting!("providers.openai.enabled", true)
    put_setting!("providers.openrouter.enabled", true)
    put_setting!("model_preferences.tasks.fanout_manager", ["local"])
    put_setting!("model_preferences.tasks.fanout_review", ["fast"])
    put_setting!("model_preferences.tasks.fanout_synthesis", ["openrouter_fast"])

    context = %{
      actor: "alice",
      channel: :cli,
      test_pid: self(),
      model_client: RoleRecordingManagerModel,
      fanout_manager_response: fanout_manager_response(),
      request: %{fanout_manager_mode: :automatic, channel: :cli}
    }

    assert Disclosure.hosted_pending?(:cli)

    assert {:ok, pending_response} =
             DirectAnswer.run(%{text: "Research alpha and beta independently."}, context)

    assert pending_response.message ==
             "One ordinary answer while fanout disclosure is pending."

    refute Map.has_key?(pending_response, :parallel_work_plan)
    assert_receive {:provider_called, "direct_answer_local"}
    refute_receive {:fanout_manager_provider_called, _profile}

    assert :ok = Disclosure.render_and_ack(:cli, fn _text -> :ok end)

    assert {:ok, admitted_response} =
             DirectAnswer.run(%{text: "Research alpha and beta independently."}, context)

    assert admitted_response.parallel_work_plan.source == :model
    assert_receive {:fanout_manager_provider_called, "local"}
    refute_receive {:provider_called, "direct_answer_local"}
  end

  test "manager failure is observable without persisting its raw error" do
    Application.put_env(:allbert_assist, DirectAnswer,
      answerer: FakeAnswerer,
      fanout_manager: ScriptedFanoutManager
    )

    Process.put(
      {ScriptedFanoutManager, :response},
      {:error, {:provider_failure, "fanout-manager-secret"}}
    )

    assert {:ok, _setting} =
             Settings.put("intent.direct_answer_model_enabled", true, %{audit?: false})

    assert {:ok, response} =
             DirectAnswer.run(%{text: "What is Allbert?"}, %{
               actor: "alice",
               test_pid: self(),
               request: %{fanout_manager_mode: :automatic}
             })

    assert Enum.any?(response.diagnostics, fn diagnostic ->
             diagnostic == %{
               source: :fanout_manager,
               result: :error,
               outcome: :manager_unavailable
             }
           end)

    refute inspect(response.diagnostics) =~ "fanout-manager-secret"
  end

  test "enabled model path walks the authored direct-answer task chain" do
    Application.put_env(:allbert_assist, DirectAnswer, answerer: FakeAnswerer)

    assert {:ok, _setting} =
             Settings.put("intent.direct_answer_model_enabled", true, %{audit?: false})

    assert {:ok, _setting} =
             Settings.put("model_preferences.tasks.direct_answer", ["fast", "local"], %{
               audit?: false
             })

    assert {:ok, response} =
             DirectAnswer.run(%{text: "What is Allbert?"}, %{actor: "alice"})

    assert response.direct_answer.source == :model
    assert response.direct_answer.model_profile == "local"

    assert [
             %{
               profile: "fast",
               reason: {:provider_disabled, "fast", "openai"},
               status: :skipped
             }
           ] = response.direct_answer.model_resolution.diagnostics
  end

  test "enabled model path receives bounded active memory context", %{projection: projection} do
    Application.put_env(:allbert_assist, DirectAnswer, answerer: MemoryAwareAnswerer)

    assert {:ok, _setting} =
             Settings.put("intent.direct_answer_model_enabled", true, %{audit?: false})

    assert {:ok, entry} =
             Memory.upsert_system_entry(%{
               namespace: :identity,
               file_path: "persona.md",
               actor: "alice",
               summary: "Alice persona",
               body: "Reports should stay concise and direct."
             })

    assert {:ok, _reviewed} =
             Memory.review_entry(
               entry.path,
               %{
                 status: :kept,
                 reviewed_at: "2026-04-28T12:00:00Z",
                 reviewed_by: "alice"
               },
               user_id: "alice"
             )

    assert {:ok, _build} = Projection.rebuild(projection)

    assert {:ok, response} =
             DirectAnswer.run(%{text: "How should reports be written?"}, %{
               actor: "alice",
               user_id: "alice",
               thread_id: "thr_direct_answer",
               request_started_at: "2026-05-28T12:00:00Z",
               memory_projection: projection
             })

    assert response.status == :completed
    assert response.message =~ "Reports should stay concise"
    assert response.direct_answer.source == :model
    assert response.direct_answer.active_memory.candidate_count_after_filter == 1

    assert [%{namespace: "identity"} = chunk] =
             response.direct_answer.active_memory.retrieved_chunks

    assert chunk.recency_decay == 0.5
    refute Map.has_key?(chunk, :body)
  end

  test "text insertion enforces the shared 8000-byte Active Memory ceiling", %{
    projection: projection
  } do
    Application.put_env(:allbert_assist, DirectAnswer, answerer: BudgetAnswerer)

    assert {:ok, _setting} =
             Settings.put("intent.direct_answer_model_enabled", true, %{audit?: false})

    for index <- 1..5 do
      body = "budget #{index} " <> String.duplicate("x", 1_991)
      assert byte_size(body) == 2_000
      assert {:ok, entry} = append_kept("alice", body)
      assert entry.review_status == :kept
    end

    assert {:ok, _build} = Projection.rebuild(projection)

    assert {:ok, response} =
             DirectAnswer.run(%{text: "Use the budget memory"}, %{
               actor: "alice",
               user_id: "alice",
               request_started_at: "2026-07-29T12:00:00Z",
               memory_projection: projection
             })

    assert_receive {:active_memory_prompt, chunks}
    assert Enum.sum(Enum.map(chunks, &byte_size(&1.body))) == 8_000
    assert response.direct_answer.active_memory.prompt_budget_bytes == 8_000
    assert response.direct_answer.active_memory.prompt_bytes == 8_000
    assert response.direct_answer.active_memory.prompt_truncated?
  end

  test "enabled vision path resolves vision_input and redacts image metadata" do
    assert {:ok, _setting} =
             Settings.put("intent.direct_answer_model_enabled", true, %{audit?: false})

    assert {:ok, _setting} = Settings.put("vision.enabled", true, %{audit?: false})

    assert {:ok, _setting} =
             Settings.put("model_preferences.capabilities.vision_input", ["vision_fake"], %{
               audit?: false
             })

    image_path = write_png!("direct-answer-vision.png")

    assert {:ok, image_metadata} =
             ImageMetadata.from_path(image_path,
               resource_uri: "image://capture/img_direct_answer",
               filename: "direct-answer-vision.png",
               transient?: true
             )

    assert {:ok, response} =
             DirectAnswer.run(%{text: "What is in this image?"}, %{
               actor: "alice",
               request: %{metadata: %{image_inputs: [image_metadata]}}
             })

    assert response.status == :completed
    assert response.message =~ "Fixture vision answer for 1 image input"
    assert response.direct_answer.source == :model
    assert response.direct_answer.model_profile == "vision_fake"
    assert response.direct_answer.model_resolution.capability == "vision_input"

    assert [%{resource_uri: "image://capture/img_direct_answer"} = redacted] =
             response.direct_answer.media.image_inputs

    assert redacted.width == 1
    refute Map.has_key?(redacted, :path)
    refute inspect(response.direct_answer) =~ image_path
    refute File.exists?(image_path)
  end

  test "vision path falls back when vision is disabled" do
    assert {:ok, _setting} =
             Settings.put("intent.direct_answer_model_enabled", true, %{audit?: false})

    image_path = write_png!("direct-answer-vision-disabled.png")

    assert {:ok, image_metadata} =
             ImageMetadata.from_path(image_path,
               resource_uri: "image://capture/img_disabled",
               transient?: true
             )

    assert {:ok, response} =
             DirectAnswer.run(%{text: "What is in this image?"}, %{
               actor: "alice",
               request: %{metadata: %{image_inputs: [image_metadata]}}
             })

    assert response.status == :completed
    assert response.direct_answer.source == :bounded_fallback
    assert response.direct_answer.reason == ":vision_disabled"
    refute File.exists?(image_path)
  end

  test "provider failures fall back without exposing the prompt" do
    Application.put_env(:allbert_assist, DirectAnswer, answerer: FailingAnswerer)

    assert {:ok, _setting} =
             Settings.put("intent.direct_answer_model_enabled", true, %{audit?: false})

    assert {:ok, _setting} = Settings.put("providers.openai.enabled", true, %{audit?: false})

    assert {:ok, response} =
             DirectAnswer.run(%{text: "Should this call a provider?"}, %{actor: "alice"})

    assert response.status == :completed
    assert response.message =~ "configured direct-answer model was unavailable"
    assert response.direct_answer.source == :bounded_fallback
    assert response.direct_answer[:model_enabled?] == true
    refute response.message =~ "Should this call a provider?"
  end

  test "default direct-answer failure never calls the global local profile" do
    Application.put_env(:allbert_assist, DirectAnswer, answerer: ScriptedAnswerer)
    put_setting!("intent.direct_answer_model_enabled", true)

    assert {:ok, response} = DirectAnswer.run(%{text: "answer"}, %{actor: "alice"})

    assert response.message =~ "configured direct-answer model was unavailable"
    assert_receive {:provider_called, "direct_answer_local"}
    refute_receive {:provider_called, "local"}
  end

  test "runtime failover cannot append global local to the closed default chain" do
    Application.put_env(:allbert_assist, DirectAnswer, answerer: ScriptedAnswerer)
    put_setting!("intent.direct_answer_model_enabled", true)
    put_setting!("models.fallback.enabled", true)

    assert {:ok, response} = DirectAnswer.run(%{text: "answer"}, %{actor: "alice"})

    assert response.message == "The configured model chain failed: direct_answer_local."
    assert response.direct_answer.fallback.provider_call_count == 1
    assert_receive {:provider_called, "direct_answer_local"}
    refute_receive {:provider_called, "local"}
  end

  test "runtime fallback is default off and makes exactly one provider call" do
    Application.put_env(:allbert_assist, DirectAnswer, answerer: ScriptedAnswerer)
    enable_text_chain!()

    assert {:ok, response} = DirectAnswer.run(%{text: "answer"}, %{actor: "alice"})

    assert response.message =~ "configured direct-answer model was unavailable"
    assert_receive {:provider_called, "local"}
    refute_receive {:provider_called, "fast"}
    refute Map.has_key?(response.direct_answer, :fallback)
  end

  test "grounded fanout worker never retries or audits a provider failure" do
    Application.put_env(:allbert_assist, DirectAnswer, answerer: ScriptedAnswerer)
    enable_text_chain!()
    put_setting!("models.fallback.enabled", true)
    put_setting!("models.fallback.allow_local_to_hosted", true)
    Process.put({ScriptedAnswerer, "fast"}, {:ok, "must not appear"})

    assert {:ok, response} =
             DirectAnswer.run(%{text: "Complete the grounded child task."}, %{
               actor: "alice",
               fanout_worker_policy: fanout_worker_policy()
             })

    assert response.direct_answer.source == :bounded_fallback
    assert response.fanout_worker == %{version: 1, provider_call_count: 1}
    assert_receive {:provider_called, "local"}
    refute_receive {:provider_called, "fast"}
    refute File.exists?(FallbackAudit.audit_path())
  end

  test "hosted primary makes no provider call before exact current-surface acknowledgement" do
    Application.put_env(:allbert_assist, DirectAnswer, answerer: ScriptedAnswerer)
    enable_text_chain!(["fast", "local"])
    Process.put({ScriptedAnswerer, "fast"}, {:ok, "hosted answer"})

    assert Disclosure.hosted_pending?(:cli)

    assert {:ok, denied} =
             DirectAnswer.run(%{text: "answer"}, %{actor: "alice", channel: :cli})

    assert denied.message =~ "waiting for its provider disclosure"
    assert denied.message =~ "allbert ask"
    assert denied.direct_answer.source == :bounded_fallback
    refute_receive {:provider_called, "fast"}

    assert :ok = Disclosure.render_and_ack(:cli, fn _text -> :ok end)

    assert {:ok, answered} =
             DirectAnswer.run(%{text: "answer"}, %{actor: "alice", channel: :cli})

    assert answered.message == "hosted answer"
    assert_receive {:provider_called, "fast"}
  end

  test "grounded fanout worker records zero calls when disclosure denies transport" do
    Application.put_env(:allbert_assist, DirectAnswer, answerer: ScriptedAnswerer)
    enable_text_chain!(["fast"])
    Process.put({ScriptedAnswerer, "fast"}, {:ok, "must not appear"})

    assert Disclosure.hosted_pending?(:cli)

    assert {:ok, response} =
             DirectAnswer.run(%{text: "Complete the grounded child task."}, %{
               actor: "alice",
               channel: :cli,
               fanout_worker_policy: fanout_worker_policy()
             })

    assert response.direct_answer.source == :bounded_fallback
    assert response.fanout_worker == %{version: 1, provider_call_count: 0}
    refute_receive {:provider_called, "fast"}
  end

  test "one surface cannot borrow another local surface acknowledgement" do
    Application.put_env(:allbert_assist, DirectAnswer, answerer: ScriptedAnswerer)
    enable_text_chain!(["fast"])
    Process.put({ScriptedAnswerer, "fast"}, {:ok, "must not appear"})

    assert :ok = Disclosure.render_and_ack(:web, fn _text -> :ok end)

    assert {:ok, denied} =
             DirectAnswer.run(%{text: "answer"}, %{request: %{channel: :tui}})

    assert denied.message =~ "allbert tui"
    assert Disclosure.hosted_pending?(:tui)
    refute_receive {:provider_called, "fast"}
  end

  test "resolver-skipped head still gates the actual hosted route before its first call" do
    Application.put_env(:allbert_assist, DirectAnswer, answerer: ScriptedAnswerer)

    assert {:ok, _settings} =
             Settings.write_user_settings(%{
               "intent" => %{"direct_answer_model_enabled" => true},
               "providers" => %{"openai" => %{"enabled" => true}},
               "model_preferences" => %{
                 "tasks" => %{"direct_answer" => ["voice_stt_fake", "fast"]}
               }
             })

    Process.put({ScriptedAnswerer, "fast"}, {:ok, "must wait"})

    assert {:ok, denied} =
             DirectAnswer.run(%{text: "answer"}, %{request: %{channel: :cli}})

    assert denied.message =~ "provider disclosure"
    refute_receive {:provider_called, "fast"}
    assert Disclosure.hosted_pending?(:cli)
  end

  test "local to hosted fallback is denied without the second acknowledgement" do
    Application.put_env(:allbert_assist, DirectAnswer, answerer: ScriptedAnswerer)
    enable_text_chain!()
    put_setting!("models.fallback.enabled", true)
    Process.put({ScriptedAnswerer, "fast"}, {:ok, "hosted answer"})

    assert {:ok, response} = DirectAnswer.run(%{text: "answer"}, %{actor: "alice"})

    assert response.message == "The configured model chain failed: local."
    assert response.direct_answer.fallback.classification == :ambiguous
    assert response.direct_answer.fallback.provider_call_count == 1
    assert_receive {:provider_called, "local"}
    refute_receive {:provider_called, "fast"}
    assert File.read!(FallbackAudit.audit_path()) =~ "model_fallback.egress_denied"
  end

  test "opted-in fallback names the non-primary answering profile and audits it" do
    Application.put_env(:allbert_assist, DirectAnswer, answerer: ScriptedAnswerer)
    enable_text_chain!()
    put_setting!("models.fallback.enabled", true)
    put_setting!("models.fallback.allow_local_to_hosted", true)
    Process.put({ScriptedAnswerer, "fast"}, {:ok, "hosted answer"})

    assert Disclosure.hosted_pending?(:cli)
    assert :ok = Disclosure.render_and_ack(:cli, fn _text -> :ok end)

    assert {:ok, response} =
             DirectAnswer.run(%{text: "answer"}, %{actor: "alice", channel: :cli})

    assert response.message == "hosted answer"
    assert response.direct_answer.model_profile == "fast"
    assert response.direct_answer.fallback.failed_profile == "local"
    assert response.direct_answer.fallback.answered_profile == "fast"
    assert response.direct_answer.fallback.provider_call_count == 2
    refute Map.has_key?(response, :fanout_worker)
    assert_receive {:provider_called, "local"}
    assert_receive {:provider_called, "fast"}

    audit = File.read!(FallbackAudit.audit_path())
    assert audit =~ "model_fallback.answered"
    assert audit =~ "failed_profile: local"
    assert audit =~ "answered_profile: fast"
  end

  test "opted-in fallback preserves the operator-authored task order" do
    Application.put_env(:allbert_assist, DirectAnswer, answerer: ScriptedAnswerer)
    enable_text_chain!(["fast", "anthropic_fast", "local"])
    put_setting!("providers.anthropic.enabled", true)
    put_setting!("models.fallback.enabled", true)
    Process.put({ScriptedAnswerer, "anthropic_fast"}, {:ok, "authored second answer"})

    assert Disclosure.hosted_pending?(:cli)
    assert :ok = Disclosure.render_and_ack(:cli, fn _text -> :ok end)

    assert {:ok, response} =
             DirectAnswer.run(%{text: "answer"}, %{actor: "alice", channel: :cli})

    assert response.message == "authored second answer"
    assert response.direct_answer.fallback.failed_profile == "fast"
    assert response.direct_answer.fallback.answered_profile == "anthropic_fast"
    assert_receive {:provider_called, "fast"}
    assert_receive {:provider_called, "anthropic_fast"}
    refute_receive {:provider_called, "local"}
  end

  test "unknown partial failures never retry" do
    Application.put_env(:allbert_assist, DirectAnswer, answerer: ScriptedAnswerer)
    enable_text_chain!()
    put_setting!("models.fallback.enabled", true)
    put_setting!("models.fallback.allow_local_to_hosted", true)
    Process.put({ScriptedAnswerer, "local"}, {:error, {:unknown_stream_state, :closed}})
    Process.put({ScriptedAnswerer, "fast"}, {:ok, "must not appear"})

    assert {:ok, response} = DirectAnswer.run(%{text: "answer"}, %{actor: "alice"})

    assert response.direct_answer.fallback.classification == :partial
    assert response.direct_answer.fallback.provider_call_count == 1
    assert_receive {:provider_called, "local"}
    refute_receive {:provider_called, "fast"}
  end

  test "fallback stops after one failover even when the setting permits two" do
    Application.put_env(:allbert_assist, DirectAnswer, answerer: ScriptedAnswerer)
    enable_text_chain!(["local", "fast", "anthropic_fast"])
    put_setting!("providers.anthropic.enabled", true)
    put_setting!("models.fallback.enabled", true)
    put_setting!("models.fallback.allow_local_to_hosted", true)
    put_setting!("models.fallback.max_failovers_per_turn", 2)

    assert Disclosure.hosted_pending?(:cli)
    assert :ok = Disclosure.render_and_ack(:cli, fn _text -> :ok end)

    assert {:ok, response} =
             DirectAnswer.run(%{text: "answer"}, %{actor: "alice", channel: :cli})

    assert response.message == "The configured model chain failed: local → fast."
    assert response.direct_answer.fallback.provider_call_count == 2
    assert_receive {:provider_called, "local"}
    assert_receive {:provider_called, "fast"}
    refute_receive {:provider_called, "anthropic_fast"}
  end

  defp append_kept(actor, body) do
    with {:ok, entry} <-
           Memory.append(%{
             category: :notes,
             body: body,
             actor: actor,
             agent: "direct-answer-test",
             channel: :test,
             source_signal_id: "budget"
           }) do
      Memory.review_entry(
        entry.path,
        %{status: :kept, reviewed_by: actor, reviewed_at: "2026-07-29T10:00:00Z"},
        user_id: actor
      )
    end
  end

  defp enable_text_chain!(profiles \\ ["local", "fast"]) do
    put_setting!("intent.direct_answer_model_enabled", true)
    put_setting!("providers.openai.enabled", true)
    put_setting!("model_preferences.tasks.direct_answer", profiles)
  end

  defp fanout_worker_policy do
    %{version: 1, provider_failover: :disabled, conversation_fanout: :disabled}
  end

  defp fanout_manager_response do
    %{
      "answer" => "I can research both items and join the findings.",
      "outer_request_task_count" => 2,
      "request_ownership" => "no_embedded_content",
      "all_advisory_or_read_only" => true,
      "children_self_contained" => true,
      "can_progress_concurrently" => true,
      "child_result_dependency" => false,
      "full_coverage_exactly_once" => true,
      "material_parallel_leverage" => true,
      "join_role" => "parent_presentation_only",
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
  end

  defp put_setting!(key, value) do
    assert {:ok, _setting} = Settings.put(key, value, %{audit?: false})
  end

  defp restore_home(nil), do: System.delete_env("ALLBERT_HOME")
  defp restore_home(value), do: System.put_env("ALLBERT_HOME", value)

  defp restore_env(module, nil), do: Application.delete_env(:allbert_assist, module)
  defp restore_env(module, config), do: Application.put_env(:allbert_assist, module, config)

  defp write_png!(name) do
    path = Path.join([System.fetch_env!("ALLBERT_HOME"), "tmp", name])
    File.mkdir_p!(Path.dirname(path))
    File.write!(path, @png)
    path
  end
end
