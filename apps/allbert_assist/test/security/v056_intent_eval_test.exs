defmodule AllbertAssist.Security.V056IntentEvalTest do
  @moduledoc """
  v0.56 intent descriptor learning, routing-accuracy gate, model recommendation,
  and operator-action-layer release evals.
  """
  use ExUnit.Case, async: false
  @moduletag :security_eval_serial

  alias AllbertAssist.Actions.Channels.SendChannelMessage
  alias AllbertAssist.Actions.Registry
  alias AllbertAssist.Actions.Runner, as: ActionsRunner
  alias AllbertAssist.App.Registry, as: AppRegistry
  alias AllbertAssist.Channels.TUI.SlashCommands
  alias AllbertAssist.Intent.Eval.{Corpus, Gate, Runner, Scorer}
  alias AllbertAssist.Intent.Learning.Miner
  alias AllbertAssist.Intent.Router.DescriptorResolver
  alias AllbertAssist.Intent.Router.DescriptorStore
  alias AllbertAssist.Intent.Router.Disambiguator.FakeDisambiguator
  alias AllbertAssist.Intent.Router.Embedder.FakeEmbedder
  alias AllbertAssist.Intent.Router.Index
  alias AllbertAssist.Intent.Router.Optimizer
  alias AllbertAssist.Paths
  alias AllbertAssist.Plugin.Discovery
  alias AllbertAssist.Plugin.Registry, as: PluginRegistry
  alias AllbertAssist.SecurityFixtures.EvalInventory
  alias AllbertAssist.Settings
  alias AllbertAssist.TestSupport.ShippedRegistries

  defmodule ValidLLM do
    def generate_object(spec, prompt, schema, opts) do
      send(Keyword.fetch!(opts, :test_pid), {:llm_request, spec, prompt, schema})

      {:ok,
       %{
         object: %{
           "label" => "Send a channel message",
           "examples" => [
             "send a slack message to #eng saying release is ready",
             "message the discord channel with the deploy status"
           ],
           "synonyms" => ["send channel message", "post to channel"],
           "required_slots" => ["channel", "target", "body"],
           "optional_slots" => [],
           "negative_phrases" => ["list channels", "show channel status"]
         }
       }}
    end
  end

  defmodule InvalidLLM do
    def generate_object(_spec, _prompt, _schema, opts) do
      send(Keyword.fetch!(opts, :test_pid), :invalid_llm_called)
      {:ok, %{object: %{"label" => "", "examples" => []}}}
    end
  end

  defmodule SecretEchoLLM do
    def generate_object(_spec, _prompt, _schema, opts) do
      send(Keyword.fetch!(opts, :test_pid), :secret_echo_llm_called)

      {:ok,
       %{
         object: %{
           "label" => "Use sk-testsecret to send",
           "examples" => ["send using secret://providers/openai/api_key"],
           "synonyms" => ["send bearer xoxb-testsecret"],
           "required_slots" => ["channel"],
           "optional_slots" => [],
           "negative_phrases" => []
         }
       }}
    end
  end

  @eval_groups [
    authority_lifecycle: ~w(
      intent-descriptor-model-generation-local-only-001
      intent-descriptor-model-invalid-fallback-heuristic-001
      intent-descriptor-learned-review-inert-001
      intent-descriptor-promotion-required-001
      intent-descriptor-optimize-action-grants-no-authority-001
      intent-descriptor-registration-signal-rebuild-001
      intent-descriptor-reindex-disabled-escape-hatch-001
      intent-descriptor-rollback-removes-routability-001
      intent-descriptor-redaction-no-raw-prompts-or-secrets-001
    ),
    routing_accuracy: ~w(
      intent-routing-accuracy-baseline-gate-001
      intent-routing-negative-route-001
      intent-routing-cross-surface-001
      intent-slot-extraction-accuracy-001
      intent-clarify-vs-execute-001
      intent-promotion-blocked-on-regression-001
      intent-generated-descriptor-no-misroute-001
    ),
    systemic_corpus: ~w(
      intent-operations-action-backed-001
      intent-eval-corpus-deterministic-001
    ),
    model_recommendations: ~w(
      intent-model-doctor-no-secret-leak-001
      intent-model-recommendation-grants-no-egress-001
    )
  ]
  @eval_ids @eval_groups |> Keyword.values() |> List.flatten()

  @operator_read_actions ~w(
    intent_doctor
    intent_list_descriptors
    intent_show_descriptor
    intent_coverage
    intent_eval_run
    intent_list_review
    model_doctor
  )
  @operator_mutation_actions ~w(
    optimize_intent_descriptors
    promote_intent_descriptor
    reindex_intent_descriptors
    edit_intent_descriptor
    disable_intent_descriptor
    enable_intent_descriptor
    intent_eval_baseline
    intent_eval_capture
    intent_eval_add
  )
  @representative_cross_surface_ids ~w(
    notes-create-001
    stocks-analyze-001
    settings-model-ambiguous-001
    answer-001
    slash-intents-negative-001
    planned-operator-intent-doctor-negative-001
  )

  setup {Req.Test, :verify_on_exit!}

  setup do
    original_home = System.get_env("ALLBERT_HOME")
    original_home_dir = System.get_env("ALLBERT_HOME_DIR")
    original_paths = Application.get_env(:allbert_assist, Paths)
    original_settings = Application.get_env(:allbert_assist, Settings)
    original_embedder = Application.get_env(:allbert_assist, :intent_router_embedder)
    original_embedder_error = Application.get_env(:allbert_assist, :intent_router_embedder_error)
    original_disambiguator = Application.get_env(:allbert_assist, :intent_router_disambiguator)
    original_fake_selection = Application.get_env(:allbert_assist, :intent_router_fake_selection)

    original_fake_escalated_selection =
      Application.get_env(:allbert_assist, :intent_router_fake_escalated_selection)

    original_fake_outcome = Application.get_env(:allbert_assist, :intent_router_fake_outcome)
    original_strategy = Application.get_env(:allbert_assist, :intent_router_strategy_override)
    original_reindex = Application.get_env(:allbert_assist, :intent_index_reindex_on_signal)

    home =
      Path.join(
        System.tmp_dir!(),
        "allbert-v056-intent-eval-#{System.unique_integer([:positive])}"
      )

    System.put_env("ALLBERT_HOME", home)
    System.delete_env("ALLBERT_HOME_DIR")
    reset_bootstrap_registries!()
    Application.put_env(:allbert_assist, Paths, home: home)
    Application.put_env(:allbert_assist, Settings, root: Path.join(home, "settings"))
    Application.put_env(:allbert_assist, :intent_router_embedder, FakeEmbedder)
    Application.put_env(:allbert_assist, :intent_router_disambiguator, FakeDisambiguator)
    Application.delete_env(:allbert_assist, :intent_router_embedder_error)
    Application.delete_env(:allbert_assist, :intent_router_fake_selection)
    Application.delete_env(:allbert_assist, :intent_router_fake_escalated_selection)
    Application.delete_env(:allbert_assist, :intent_router_fake_outcome)
    Application.delete_env(:allbert_assist, :intent_router_strategy_override)
    Application.delete_env(:allbert_assist, :intent_index_reindex_on_signal)

    on_exit(fn ->
      if original_home,
        do: System.put_env("ALLBERT_HOME", original_home),
        else: System.delete_env("ALLBERT_HOME")

      if original_home_dir,
        do: System.put_env("ALLBERT_HOME_DIR", original_home_dir),
        else: System.delete_env("ALLBERT_HOME_DIR")

      ShippedRegistries.restore!()
      restore_env(Paths, original_paths)
      restore_env(Settings, original_settings)
      restore_env(:intent_router_embedder, original_embedder)
      restore_env(:intent_router_embedder_error, original_embedder_error)
      restore_env(:intent_router_disambiguator, original_disambiguator)
      restore_env(:intent_router_fake_selection, original_fake_selection)
      restore_env(:intent_router_fake_escalated_selection, original_fake_escalated_selection)
      restore_env(:intent_router_fake_outcome, original_fake_outcome)
      restore_env(:intent_router_strategy_override, original_strategy)
      restore_env(:intent_index_reindex_on_signal, original_reindex)
      File.rm_rf!(home)
    end)

    {:ok, home: home}
  end

  test "v0.56 eval inventory rows are complete" do
    rows = EvalInventory.rows_for_milestone(:v056)
    row_ids = Enum.map(rows, & &1.id)

    assert MapSet.new(row_ids) == MapSet.new(@eval_ids)
    assert length(row_ids) == length(@eval_ids)
    assert Enum.all?(rows, &(&1.surface == :intent_routing))
    assert Enum.all?(rows, &(&1.test_module == inspect(__MODULE__)))
  end

  test "descriptor generation and learned proposals stay advisory and redacted" do
    assert_eval_group!(:authority_lifecycle)

    attrs =
      Optimizer.generate(SendChannelMessage, :model,
        llm_client: ValidLLM,
        llm_opts: [test_pid: self()]
      )

    assert_receive {:llm_request, %{id: "llama3.1:8b"}, prompt, schema}
    assert schema[:label][:required]
    refute prompt =~ "http://"
    refute prompt =~ "secret://"
    assert attrs.generation.strategy == "model"
    assert attrs.generation.model_profile == "router_local"
    assert attrs.generation.endpoint_kind == "local_endpoint"
    refute inspect(attrs) =~ "http://"

    invalid =
      Optimizer.generate(SendChannelMessage, :model,
        llm_client: InvalidLLM,
        llm_opts: [test_pid: self()]
      )

    assert_received :invalid_llm_called
    assert invalid.generation.strategy == "heuristic"
    assert invalid.generation.fallback_reason =~ "invalid_model_field"

    secret =
      Optimizer.generate(SendChannelMessage, :model,
        llm_client: SecretEchoLLM,
        llm_opts: [test_pid: self()]
      )

    assert_received :secret_echo_llm_called
    refute inspect(secret) =~ "sk-testsecret"
    refute inspect(secret) =~ "secret://"

    assert [%{action_name: "append_memory"}] =
             Miner.mine(%{
               source: :trace,
               action_name: "append_memory",
               utterance: "remember the release preference sk-test-secret",
               confidence: 0.7,
               evidence_ref: %{trace_id: "tr_1", api_key: "sk-test-secret"}
             })

    {:ok, review_path} = DescriptorStore.path(:review, :allbert, "append_memory")
    review_yaml = File.read!(review_path)
    refute review_yaml =~ "sk-test-secret"

    refute DescriptorResolver.resolve()
           |> Enum.any?(&(&1.action_name == "append_memory" and &1.source == :review))

    assert {:ok, capability} = Registry.capability("optimize_intent_descriptors")
    assert capability.exposure == :internal
    assert capability.permission == :settings_write
    assert {:ok, optimize_module} = Registry.resolve("optimize_intent_descriptors")
    refute optimize_module in Registry.agent_modules()
  end

  test "promotion is required, gate-backed, and rollback removes routability" do
    assert_eval_group!(:authority_lifecycle)
    assert_eval_group!(:routing_accuracy)

    {:ok, _review_path} =
      DescriptorStore.put(:review, %{
        app_id: :allbert,
        action_name: "show_app",
        label: "Show app",
        examples: ["show app"],
        synonyms: ["app details"],
        required_slots: []
      })

    refute DescriptorResolver.resolve()
           |> Enum.any?(&(&1.action_name == "show_app" and &1.source == :review))

    refute DescriptorResolver.resolve()
           |> Enum.any?(&(&1.action_name == "show_app" and &1.source == :generated))

    assert {:ok, promoted} =
             ActionsRunner.run(
               "promote_intent_descriptor",
               %{action: "show_app", from: "learned"},
               operator_context()
             )

    assert promoted.status == :completed

    assert DescriptorResolver.resolve()
           |> Enum.any?(&(&1.action_name == "show_app" and &1.source == :generated))

    assert {:ok, _path} = DescriptorStore.delete(:generated, :allbert, "show_app")

    refute DescriptorResolver.resolve()
           |> Enum.any?(&(&1.action_name == "show_app" and &1.source == :generated))

    assert DescriptorResolver.resolve() |> Enum.any?(&(&1.action_name == "write_note"))

    {:ok, _override_path} =
      DescriptorStore.put(:overrides, %{
        app_id: :notes_files,
        action_name: "write_note",
        disabled: true
      })

    refute DescriptorResolver.resolve() |> Enum.any?(&(&1.action_name == "write_note"))
    assert {:ok, _deleted} = DescriptorStore.delete(:overrides, :notes_files, "write_note")
    assert DescriptorResolver.resolve() |> Enum.any?(&(&1.action_name == "write_note"))

    {:ok, review_path} =
      DescriptorStore.put(:review, %{
        app_id: :allbert,
        action_name: "list_channels",
        label: "List channels",
        examples: ["list my channels"],
        synonyms: ["channels"],
        required_slots: [:channel]
      })

    assert {:ok, rejected} =
             ActionsRunner.run(
               "promote_intent_descriptor",
               %{action: "list_channels"},
               operator_context()
             )

    assert rejected.status == :rejected
    assert rejected.message =~ "gate failed"
    assert File.exists?(review_path)
    {:ok, generated_path} = DescriptorStore.path(:generated, :allbert, "list_channels")
    refute File.exists?(generated_path)
  end

  test "registration signals mark the index stale and the escape hatch disables subscription" do
    assert_eval_group!(:authority_lifecycle)

    {:ok, pid} = Index.start_link(name: :"v056_index_#{System.unique_integer([:positive])}")
    %{status: :built} = Index.rebuild(pid)

    send(pid, {:signal, %{type: "allbert.app.registered"}})
    assert Index.state(pid).status == :not_built
    assert Index.state(pid).rebuild_timer != nil

    previous = Application.get_env(:allbert_assist, :intent_index_reindex_on_signal)
    Application.put_env(:allbert_assist, :intent_index_reindex_on_signal, false)

    on_exit(fn ->
      restore_env(:intent_index_reindex_on_signal, previous)
    end)

    {:ok, disabled_pid} =
      Index.start_link(name: :"v056_index_disabled_#{System.unique_integer([:positive])}")

    assert Index.state(disabled_pid).subscription_id == nil
  end

  test "routing corpus is deterministic and the baseline gate is clean", %{home: home} do
    assert_eval_group!(:routing_accuracy)
    assert_eval_group!(:systemic_corpus)

    {:ok, cases} = Corpus.load()
    run = Runner.run(cases)
    repeat_run = Runner.run(cases)

    assert replay_signature(run) == replay_signature(repeat_run)

    score = Scorer.score(run, baseline_raw())
    assert score.overall_accuracy == 1.0
    assert score.negative_violations == []
    assert score.slot_accuracy.total > 0
    assert score.slot_accuracy.passed == score.slot_accuracy.total
    assert score.clarify_vs_execute.total > 0
    assert score.clarify_vs_execute.passed == score.clarify_vs_execute.total
    assert Gate.check(score, baseline_raw()) == :ok

    assert_cross_surface_stable!(cases)

    assert {:ok, captured} =
             ActionsRunner.run(
               "intent_eval_capture",
               %{
                 case: %{
                   id: "v056-captured-secret-001",
                   domain: "captured",
                   surface: "tui",
                   utterance: "operator saw a routing miss with sk-test-secret",
                   context: %{api_key: "sk-test-secret"},
                   expected: %{kind: "none"},
                   negative: false,
                   rationale: "operator reviewed"
                 }
               },
               operator_context()
             )

    assert captured.status == :completed
    assert captured.path |> Path.expand() |> String.starts_with?(Path.expand(home))
    captured_yaml = File.read!(captured.path)
    refute captured_yaml =~ "sk-test-secret"

    {:ok, committed_after_capture} = Corpus.load()
    refute Enum.any?(committed_after_capture, &(&1.id == "v056-captured-secret-001"))
  end

  test "operator intent/model operations are action-backed and slash-only reads reuse DTOs" do
    assert_eval_group!(:systemic_corpus)

    agent_action_names = Registry.agent_modules() |> Enum.map(& &1.name()) |> MapSet.new()

    for action_name <- @operator_read_actions ++ @operator_mutation_actions do
      assert {:ok, module} = Registry.resolve(action_name)
      assert {:ok, capability} = Registry.capability(action_name)
      assert capability.exposure == :internal
      refute MapSet.member?(agent_action_names, action_name)
      refute module in Registry.agent_modules()
    end

    assert {:ok, intents} = SlashCommands.dispatch("/intents", operator_context())
    assert intents.runner_metadata.action_name == "intent_coverage"
    assert intents.surface_payload =~ "coverage: routable="

    assert {:ok, eval_run} = ActionsRunner.run("intent_eval_run", %{}, operator_context())
    assert eval_run.runner_metadata.action_name == "intent_eval_run"
    assert eval_run.eval_result.gate.status in [:pass, :fail]
  end

  test "model doctor is redacted and recommendations remain advisory" do
    assert_eval_group!(:model_recommendations)

    assert {:ok, _setting} =
             Settings.put("intent.router_escalation_profile", "fast", %{audit?: false})

    Req.Test.stub(__MODULE__, fn conn ->
      assert conn.request_path == "/api/tags"

      Req.Test.json(conn, %{
        "models" => [
          %{"model" => "nomic-embed-text", "context_length" => 2048},
          %{"model" => "llama3.1:8b", "context_length" => 128_000}
        ]
      })
    end)

    context = Map.put(operator_context(), :req_options, plug: {Req.Test, __MODULE__})

    assert {:ok, response} = ActionsRunner.run("model_doctor", operator_report_params(), context)
    assert response.runner_metadata.action_name == "model_doctor"
    assert response.message =~ "model doctor ok="
    assert response.message =~ "intent_embedding"
    assert response.message =~ "remote-egress-warning"
    refute_secret_or_endpoint!(inspect(response))
    refute_secret_or_endpoint!(response.message)

    rows = Map.new(response.model_doctor.rows, &{&1.id, &1})
    assert rows["intent_escalation"].status == "remote-egress-warning"

    assert {:ok, slash_models} = SlashCommands.dispatch("/models", context)
    assert slash_models.runner_metadata.action_name == "model_doctor"
    assert slash_models.surface_payload =~ "model doctor ok="
    refute_secret_or_endpoint!(slash_models.surface_payload)
  end

  defp assert_cross_surface_stable!(cases) do
    cases_by_id = Map.new(cases, &{&1.id, &1})

    for id <- @representative_cross_surface_ids do
      case = Map.fetch!(cases_by_id, id)
      expected = route_label(Runner.run([case], disambiguation_margin: 0.12).results)

      for surface <- Corpus.surfaces() -- [:any] do
        surface_case = %{case | id: "#{case.id}-#{surface}", surface: surface}

        assert route_label(
                 Runner.run([surface_case], surface: surface, disambiguation_margin: 0.12).results
               ) == expected,
               "#{case.id} drifted on #{surface}"
      end
    end
  end

  defp replay_signature(run) do
    Enum.map(run.results, fn %{case: case, actual: actual} ->
      {case.id, Map.take(actual, [:kind, :action, :slots])}
    end)
  end

  defp route_label([%{actual: actual}]), do: {actual.kind, actual.action}

  defp baseline_raw do
    path =
      [
        "apps/allbert_assist/test/fixtures/intent/eval/baseline.yaml",
        "test/fixtures/intent/eval/baseline.yaml"
      ]
      |> Enum.find(&File.exists?/1)

    assert path
    assert {:ok, baseline} = YamlElixir.read_from_file(path)
    baseline
  end

  defp assert_eval_group!(group) do
    ids = Keyword.fetch!(@eval_groups, group)
    milestone_rows = EvalInventory.rows_for_milestone(:v056)
    rows = Enum.map(ids, &find_eval_row!(milestone_rows, &1))

    assert Enum.map(rows, & &1.id) == ids
    assert Enum.all?(rows, &(&1.milestone == :v056))
    assert Enum.all?(rows, &(&1.surface == :intent_routing))
  end

  defp find_eval_row!(rows, id) do
    Enum.find(rows, &(&1.id == id)) || flunk("missing v0.56 eval row #{id}")
  end

  defp operator_context do
    %{
      actor: "local",
      user_id: "local",
      operator_id: "local",
      channel: :test,
      surface: "security_eval",
      request: %{operator_id: "local", user_id: "local", channel: :test}
    }
  end

  defp operator_report_params do
    %{render_mode: "operator_report", surface_policy_affordance: true}
  end

  defp refute_secret_or_endpoint!(text) do
    refute text =~ "secret://"
    refute text =~ "api_key"
    refute text =~ "sk-"
    refute text =~ "http://"
    refute text =~ "https://"
  end

  defp restore_env(key, nil) when is_atom(key), do: Application.delete_env(:allbert_assist, key)

  defp restore_env(key, value) when is_atom(key),
    do: Application.put_env(:allbert_assist, key, value)

  defp reset_bootstrap_registries! do
    PluginRegistry.clear()
    AppRegistry.clear()

    Discovery.discover()
    |> Enum.each(&register_discovery!/1)

    configured_apps()
    |> Kernel.++(PluginRegistry.registered_apps())
    |> Enum.uniq()
    |> Enum.each(&AppRegistry.register/1)
  end

  defp register_discovery!({:module, module, opts}) do
    {:ok, _plugin_id} = PluginRegistry.register_module(module, opts)
  end

  defp register_discovery!({:entry, entry}) do
    {:ok, _plugin_id} = PluginRegistry.register_entry(entry)
  end

  defp register_discovery!({:diagnostic, key, diagnostics}) do
    PluginRegistry.put_diagnostics(to_string(key), diagnostics)
  end

  defp configured_apps do
    case Application.get_env(:allbert_assist, :apps, [AllbertAssist.App.CoreApp]) do
      apps when is_list(apps) -> apps
      _other -> [AllbertAssist.App.CoreApp]
    end
  end
end
