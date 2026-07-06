defmodule AllbertAssist.Intent.Eval.CorpusCompletenessTest do
  use ExUnit.Case, async: false

  alias AllbertAssist.Actions.Registry
  alias AllbertAssist.Intent.Eval.Corpus

  @intentionally_uncovered_actions MapSet.new([
                                     # Research app descriptors are inert handoff descriptors; the
                                     # specialist runs behind objective delegate steps, not a
                                     # registered runtime action.
                                     "research"
                                   ])

  @planned_operator_actions MapSet.new(~w(
    intent_doctor
    intent_list_descriptors
    intent_show_descriptor
    intent_coverage
    intent_eval_run
    intent_list_review
    model_doctor
    optimize_intent_descriptors
    promote_intent_descriptor
    edit_intent_descriptor
    disable_intent_descriptor
    enable_intent_descriptor
    reindex_intent_descriptors
    intent_eval_baseline
    intent_eval_capture
    intent_eval_add
  ))

  @slash_negative_ids MapSet.new(~w(
    slash-status-negative-001
    slash-channels-negative-001
    slash-events-negative-001
    slash-confirmations-negative-001
    slash-settings-get-negative-001
    slash-intents-negative-001
    slash-models-negative-001
    slash-help-negative-001
    slash-quit-negative-001
  ))

  @required_domains MapSet.new(~w(
    adversarial
    answer
    apps
    browser
    calendar
    channels
    confirmations
    email
    external
    github
    image
    marketplace
    mcp
    memory
    model
    negative-doctor
    negative-internal
    negative-operator
    negative-slash
    none
    notes
    objectives
    packages
    plan-build
    plugins
    public-protocol
    research
    resources
    settings
    shell
    skills
    stocks
    voice
  ))

  test "committed corpus loads and covers every required domain" do
    assert {:ok, cases} = Corpus.load()
    assert length(cases) >= 200

    domains = cases |> Enum.map(& &1.domain) |> MapSet.new()
    assert MapSet.difference(@required_domains, domains) == MapSet.new()
  end

  test "positive execute cases cover the current routable action inventory" do
    assert {:ok, cases} = Corpus.load()

    positive_actions =
      cases
      |> Enum.filter(&(&1.expected.kind == :execute and not &1.negative?))
      |> Enum.map(& &1.expected.action)
      |> MapSet.new()

    agent_actions = Registry.agent_modules() |> Enum.map(& &1.name()) |> MapSet.new()
    allowed_positive_actions = MapSet.union(agent_actions, @intentionally_uncovered_actions)

    assert MapSet.difference(agent_actions, positive_actions) == MapSet.new()
    assert MapSet.difference(positive_actions, allowed_positive_actions) == MapSet.new()
  end

  test "slot-bearing cases cover more than one action family" do
    assert {:ok, cases} = Corpus.load()

    slot_cases =
      Enum.filter(cases, fn case ->
        not case.negative? and map_size(case.expected.slots || %{}) > 0
      end)

    slot_actions = slot_cases |> Enum.map(& &1.expected.action) |> MapSet.new()

    assert length(slot_cases) >= 4

    assert MapSet.subset?(
             MapSet.new(~w(send_email send_channel_message create_calendar_event run_analysis)),
             slot_actions
           )
  end

  test "operator/internal negative cases default to no-execute semantics" do
    assert {:ok, cases} = Corpus.load()

    for case <- cases,
        case.negative?,
        case.domain in [
          "confirmations",
          "negative-doctor",
          "negative-internal",
          "negative-operator"
        ] do
      assert case.negative_mode == :no_execute
    end
  end

  test "negative execute cases enumerate internal and planned operator actions" do
    assert {:ok, cases} = Corpus.load()

    negative_actions =
      cases
      |> Enum.filter(&(&1.negative? and &1.expected.kind == :execute))
      |> Enum.map(& &1.expected.action)
      |> MapSet.new()

    internal_actions =
      Registry.internal_capabilities()
      |> Enum.map(& &1.name)
      |> MapSet.new()

    assert MapSet.difference(internal_actions, negative_actions) == MapSet.new()
    assert MapSet.difference(@planned_operator_actions, negative_actions) == MapSet.new()
  end

  test "TUI slash lines are explicit negative non-route cases" do
    assert {:ok, cases} = Corpus.load()

    slash_cases =
      cases
      |> Enum.filter(&(&1.id in @slash_negative_ids))
      |> Map.new(&{&1.id, &1})

    assert MapSet.new(Map.keys(slash_cases)) == @slash_negative_ids

    for case <- Map.values(slash_cases) do
      assert case.negative?
      assert case.expected.kind == :none
      assert String.starts_with?(case.utterance, "/")
    end
  end

  test "release baseline artifact is present and not parsed as a corpus case" do
    assert {:ok, cases} = Corpus.load()
    refute Enum.any?(cases, &(&1.id == "v056-release-baseline"))

    path = baseline_path()
    assert File.exists?(path)
    assert {:ok, baseline} = YamlElixir.read_from_file(path)

    assert baseline["schema_version"] == 1
    assert baseline["id"] == "v056-release-baseline"
    assert baseline["corpus_case_count"] == length(cases)
    # 289 = 277 + the twelve v0.62 M8.15 negative-internal rows for the newly
    # registered one-spine actions (create_job; channels configure_channel_secret/
    # configure_channel_setting/link_channel_identity/unlink_channel_identity;
    # sessions clear_session/sweep_expired_sessions; complete_thread; protocol
    # create/rotate/revoke_protocol_token; ensure_voice_token). 277 = 269 + the
    # eight earlier v0.62 rows (M0.1/M4/M5/M7) recaptured at M7.
    assert baseline["corpus_case_count"] == 289
    assert baseline["overall_accuracy"] == 1.0
    assert is_map(baseline["per_domain"])
    assert get_in(baseline, ["gate", "status"]) == "pass"
  end

  defp baseline_path do
    Enum.find(
      [
        "apps/allbert_assist/test/fixtures/intent/eval/baseline.yaml",
        "test/fixtures/intent/eval/baseline.yaml"
      ],
      &File.exists?/1
    )
  end
end
