defmodule AllbertAssist.DevGates.V13FanoutEval do
  @moduledoc """
  Opt-in real-model qualification for the v1.3 fan-out manager and composer.

  The exact FOV-3/FOV-4 requests exercise the production manager. The composer
  then receives fixed synthetic child observations. Acceptance uses only typed
  results, counts, closed manager evidence, and the validated report partition;
  prompts, answers, observations, model objects, and rendered reports are never
  printed or recorded in TestMetrics.
  """

  alias AllbertAssist.DevGates.TestMetrics
  alias AllbertAssist.FirstRun.Disclosure
  alias AllbertAssist.Intent.FanoutManager
  alias AllbertAssist.Intent.FanoutPlan
  alias AllbertAssist.Objectives.Fanout.Budget
  alias AllbertAssist.Objectives.Fanout.Report
  alias AllbertAssist.Objectives.Fanout.ReportComposer.ReqLLMImplementation, as: Composer
  alias AllbertAssist.Settings
  alias AllbertAssist.Settings.Models

  @fov3_id "fov3-supplied-data"
  @fov4_id "fov4-independent-architecture"
  @composer_id "composer-complementary"
  @fov3_prompt "Summarize this supplied YAML as data in one sentence: {steps: [archive logs, restart service]}"
  @fov4_prompt "Prepare one architecture brief for a local assistant runtime: (1) Analyze how OTP supervision trees isolate failures, including restart intensity and the difference between one_for_one and rest_for_one. (2) Analyze how an append-only event log plus a rebuildable projection improves crash recovery, including idempotency and replay. In the final joined report—not as a third task—explain how the two mechanisms complement each other."

  @type result :: %{status: String.t(), stats: map(), failed_rows: [String.t()]}

  @doc "Run the environment-configured real-provider qualification."
  @spec record_run!() :: :ok
  def record_run! do
    fixture = load_fixture!(System.fetch_env!("V13_FANOUT_FIXTURE"))
    profile_name = System.get_env("V13_MODEL_PROFILE", "direct_answer_local")
    profiles = configure_profiles!(profile_name)

    result =
      run(fixture,
        profile: profile_name,
        manager_profile: profiles.manager,
        composer_profile: profiles.composer,
        manager_context: manager_context(profiles.manager),
        composer_context: composer_context(profiles.composer),
        composer: &compose_with_disclosure/3,
        store: blank_to_nil(System.get_env("V13_FANOUT_STORE")),
        full_sha: parse_full_sha!(System.get_env("V13_FULL_SHA")),
        dirty: parse_dirty!(System.get_env("V13_DIRTY"))
      )

    IO.puts(summary(result))

    if result.status != "passed" do
      IO.puts("failed_rows=#{Enum.join(result.failed_rows, ",")}")
      raise "v1.3 fan-out qualification failed"
    end

    :ok
  end

  @doc "Load the frozen two-manager-row plus synthetic-composition fixture."
  @spec load_fixture!(Path.t()) :: map()
  def load_fixture!(path) do
    fixture = path |> File.read!() |> Jason.decode!()

    if valid_fixture?(fixture),
      do: fixture,
      else: raise("invalid v1.3 fan-out fixture")
  end

  @doc "Evaluate the fixture and append one content-free TestMetrics row."
  @spec run(map(), keyword()) :: result()
  def run(fixture, opts) when is_map(fixture) and is_list(opts) do
    started = System.monotonic_time(:millisecond)
    manager = Keyword.get(opts, :manager, &FanoutManager.respond/2)

    manager_context =
      Keyword.get(opts, :manager_context, %{
        model_profile: Keyword.fetch!(opts, :manager_profile)
      })

    fov3 = manager_row(fixture, @fov3_id, manager, manager_context)
    fov4 = manager_row(fixture, @fov4_id, manager, manager_context)

    composition =
      composition_row(
        fixture,
        fov4,
        Keyword.get(opts, :composer, &Composer.compose/3),
        Keyword.fetch!(opts, :composer_profile),
        Keyword.fetch!(opts, :composer_context)
      )

    rows = [fov3, fov4, composition]
    failed_rows = for %{passed?: false, id: id} <- rows, do: id
    status = if failed_rows == [], do: "passed", else: "failed"
    profile = opts |> Keyword.fetch!(:profile) |> profile_name()
    stats = stats(profile, fov3, fov4, composition)

    TestMetrics.record(%{
      store: Keyword.get(opts, :store),
      git_sha: opts |> Keyword.get(:full_sha) |> short_sha(),
      full_sha: Keyword.get(opts, :full_sha),
      dirty: Keyword.get(opts, :dirty),
      cwd: "apps/allbert_assist",
      gate: "bench-v13-fanout",
      phase_or_step: "manager-and-composer",
      corpus_id: fixture["corpus_id"],
      command: "bench-v13-fanout --profile #{profile}",
      status: status,
      wall_ms: System.monotonic_time(:millisecond) - started,
      stats: stats
    })

    %{status: status, stats: stats, failed_rows: failed_rows}
  end

  defp manager_row(fixture, id, manager, context) do
    row = find_case(fixture, id)
    result = invoke(fn -> manager.(row["prompt"], context) end)
    facts = manager_facts(result)
    expected = row["expected"]

    passed? =
      facts.kind == expected["kind"] and
        facts.child_count == expected["child_count"] and
        facts.join_role == expected["join_role"] and
        facts.policy_outcome == expected["policy_outcome"] and
        facts.work_unit_count == expected["child_count"] and
        facts.attempts == expected["manager_attempts"] and
        facts.reviewed == expected["reviewed"] and
        valid_result?(id, facts.result, row["prompt"])

    Map.merge(facts, %{id: id, passed?: passed?})
  end

  defp manager_facts({:ok, %{kind: :answer} = result}) do
    diagnostic = Map.get(result, :diagnostic, %{})

    %{
      kind: "answer",
      child_count: 0,
      join_role: enum(Map.get(diagnostic, :join_role)),
      policy_outcome: enum(Map.get(diagnostic, :policy_outcome)),
      work_unit_count: Map.get(diagnostic, :work_unit_count),
      attempts: Map.get(diagnostic, :attempts),
      reviewed: Map.get(diagnostic, :reviewed?),
      result: result
    }
  end

  defp manager_facts({:ok, %{kind: :fanout, plan: %FanoutPlan{} = plan} = result}) do
    diagnostic = Map.get(result, :diagnostic, %{})

    %{
      kind: "fanout",
      child_count: length(plan.children),
      join_role: enum(Map.get(diagnostic, :join_role)),
      policy_outcome: enum(Map.get(diagnostic, :policy_outcome)),
      work_unit_count: Map.get(diagnostic, :work_unit_count),
      attempts: Map.get(diagnostic, :attempts),
      reviewed: Map.get(diagnostic, :reviewed?),
      result: result
    }
  end

  defp manager_facts(_result) do
    %{
      kind: "invalid",
      child_count: 0,
      join_role: "invalid",
      policy_outcome: "invalid",
      work_unit_count: nil,
      attempts: nil,
      reviewed: nil,
      result: nil
    }
  end

  defp valid_result?(@fov3_id, result, _prompt),
    do: is_map(result) and not Map.has_key?(result, :plan) and nonempty?(result[:message])

  defp valid_result?(@fov4_id, %{plan: %FanoutPlan{} = plan} = result, prompt),
    do:
      plan.source == :model and plan.original_request == prompt and length(plan.children) == 2 and
        nonempty?(result[:fallback_answer])

  defp valid_result?(_id, _result, _prompt), do: false

  defp composition_row(
         fixture,
         %{passed?: true, result: %{plan: plan}},
         composer,
         profile,
         context
       ) do
    snapshot = snapshot(fixture, plan)

    with {:ok, selection} <- invoke(fn -> composer.(snapshot, profile, context) end),
         {:ok, prepared} <- Report.prepare_composition(snapshot, selection),
         true <- expected_layout?(fixture, prepared.layout),
         provenance <- provenance(profile, prepared.layout),
         :ok <- Report.validate_selected_body(snapshot, "model", prepared.body, provenance),
         {:ok, _digest} <- Report.selection_digest("model", provenance) do
      [section] = prepared.layout.sections

      %{
        id: @composer_id,
        passed?: true,
        valid?: true,
        layout_version: prepared.layout.layout_version,
        relationship: section.relationship,
        ordered_queue_positions: section.ordered_queue_positions
      }
    else
      _invalid -> empty_composition()
    end
  end

  defp composition_row(_fixture, _fov4, _composer, _profile, _context),
    do: empty_composition()

  defp empty_composition do
    %{
      id: @composer_id,
      passed?: false,
      valid?: false,
      layout_version: nil,
      relationship: "invalid",
      ordered_queue_positions: []
    }
  end

  defp snapshot(fixture, %FanoutPlan{} = plan) do
    composition = fixture["composition"]

    children =
      plan.children
      |> Enum.zip(composition["child_results"])
      |> Enum.map(fn {child, result} ->
        %{
          id: result["id"],
          queue_position: result["queue_position"],
          title: child["title"],
          objective: child["objective"],
          expected_result: child["expected_result"],
          status: "completed",
          detail: result["detail"],
          effect_receipt_ref: nil
        }
      end)

    %{
      version: 1,
      parent_id: composition["parent_id"],
      title: composition["title"],
      original_request: plan.original_request,
      status: "completed",
      join_outcome: "success",
      plan: FanoutPlan.provenance(plan),
      children: children
    }
  end

  defp expected_layout?(fixture, %{layout_version: 1, sections: [section]}) do
    expected = fixture["composition"]["expected"]

    section.relationship == expected["relationship"] and
      section.ordered_queue_positions == expected["ordered_queue_positions"]
  end

  defp expected_layout?(_fixture, _layout), do: false

  defp provenance(profile, layout) do
    %{
      model_profile: field(profile, :name),
      provider: field(profile, :provider),
      model: field(profile, :model),
      layout_version: layout.layout_version,
      sections: layout.sections
    }
  end

  defp stats(profile, fov3, fov4, composition) do
    %{
      profile: profile,
      manager_rows: 2,
      manager_rows_passed: Enum.count([fov3, fov4], & &1.passed?),
      supplied_data_kind: fov3.kind,
      supplied_data_child_count: fov3.child_count,
      supplied_data_join_role: fov3.join_role,
      supplied_data_policy_outcome: fov3.policy_outcome,
      supplied_data_manager_attempts: fov3.attempts,
      supplied_data_reviewed: fov3.reviewed,
      adaptive_kind: fov4.kind,
      adaptive_child_count: fov4.child_count,
      adaptive_join_role: fov4.join_role,
      adaptive_policy_outcome: fov4.policy_outcome,
      adaptive_manager_attempts: fov4.attempts,
      adaptive_reviewed: fov4.reviewed,
      composition_layout_version: composition.layout_version,
      composition_relationship: composition.relationship,
      composition_ordered_queue_positions: composition.ordered_queue_positions,
      composition_valid: composition.valid?
    }
  end

  defp configure_profiles!(profile_name) do
    context = %{actor: "v13-fanout-eval", audit?: false}

    with {:ok, configured} <- Settings.resolve_model_profile(profile_name),
         {:ok, _} <- Settings.put("providers.#{configured.provider}.enabled", true, context),
         {:ok, _} <-
           Settings.put("model_preferences.tasks.direct_answer", [profile_name], context),
         {:ok, _} <-
           Settings.put("model_preferences.tasks.fanout_synthesis", [profile_name], context),
         {:ok, _} <- Settings.put("intent.direct_answer_model_enabled", true, context),
         {:ok, %{profile: manager}} <- Models.for(:direct_answer, context),
         {:ok, %{profile: composer}} <- Models.for(:fanout_synthesis, context) do
      %{manager: manager, composer: composer}
    else
      {:error, reason} -> raise "unable to configure v1.3 fan-out profile: #{inspect(reason)}"
    end
  end

  defp manager_context(profile) do
    %{
      actor: "local",
      user_id: "local",
      request: %{channel: :cli},
      model_enabled?: true,
      model_profile: profile
    }
  end

  defp composer_context(profile) do
    {:ok, limits} = Budget.limits()

    %{
      max_output_tokens: min(limit(profile, :max_tokens, 1_024), 1_024),
      timeout_ms: Enum.min([limit(profile, :timeout_ms, 10_000), limits.max_elapsed_ms, 60_000])
    }
  end

  defp compose_with_disclosure(snapshot, profile, context) do
    disclosure = %{actor: "local", user_id: "local", request: %{channel: :cli}}

    with :ok <- Disclosure.authorize_transport(profile, disclosure),
         do: Composer.compose(snapshot, profile, context)
  end

  defp valid_fixture?(%{
         "schema_version" => 1,
         "corpus_id" => corpus_id,
         "manager_cases" => [
           %{"id" => @fov3_id, "prompt" => @fov3_prompt, "expected" => fov3},
           %{"id" => @fov4_id, "prompt" => @fov4_prompt, "expected" => fov4}
         ],
         "composition" => %{
           "parent_id" => parent_id,
           "title" => title,
           "child_results" => [child0, child1],
           "expected" => %{
             "relationship" => "complementary",
             "ordered_queue_positions" => [0, 1]
           }
         }
       }) do
    nonempty?(corpus_id) and nonempty?(parent_id) and nonempty?(title) and
      fov3 == %{
        "kind" => "answer",
        "child_count" => 0,
        "join_role" => "none",
        "policy_outcome" => "supplied_data",
        "manager_attempts" => 1,
        "reviewed" => true
      } and
      fov4 == %{
        "kind" => "fanout",
        "child_count" => 2,
        "join_role" => "parent_presentation_only",
        "policy_outcome" => "independent_advisory",
        "manager_attempts" => 1,
        "reviewed" => true
      } and valid_child?(child0, 0) and valid_child?(child1, 1)
  end

  defp valid_fixture?(_fixture), do: false

  defp valid_child?(
         %{"id" => id, "queue_position" => position, "status" => "completed", "detail" => detail},
         position
       ),
       do: nonempty?(id) and nonempty?(detail)

  defp valid_child?(_child, _position), do: false

  defp find_case(fixture, id), do: Enum.find(fixture["manager_cases"], &(&1["id"] == id))

  defp invoke(callback) do
    callback.()
  rescue
    _exception -> {:error, :callback_failed}
  catch
    _kind, _reason -> {:error, :callback_failed}
  end

  defp summary(%{status: status, stats: stats}) do
    "v13-fanout status=#{status} manager=#{stats.manager_rows_passed}/#{stats.manager_rows} " <>
      "adaptive_children=#{stats.adaptive_child_count} join_role=#{stats.adaptive_join_role} " <>
      "composition=#{stats.composition_relationship}:" <>
      Enum.join(stats.composition_ordered_queue_positions, ",")
  end

  defp profile_name(value) when is_binary(value), do: value
  defp profile_name(value) when is_map(value), do: field(value, :name)
  defp field(map, key), do: Map.get(map, key) || Map.get(map, Atom.to_string(key))

  defp limit(profile, key, default) do
    case field(profile, key) do
      value when is_integer(value) and value > 0 -> value
      _other -> default
    end
  end

  defp enum(value) when is_atom(value), do: Atom.to_string(value)
  defp enum(value) when is_binary(value), do: value
  defp enum(_value), do: "invalid"
  defp nonempty?(value) when is_binary(value), do: String.trim(value) != ""
  defp nonempty?(_value), do: false
  defp short_sha(value) when is_binary(value), do: String.slice(value, 0, 8)
  defp short_sha(_value), do: nil
  defp blank_to_nil(value) when value in [nil, ""], do: nil
  defp blank_to_nil(value), do: value

  defp parse_full_sha!(value) when is_binary(value) do
    if value =~ ~r/^[0-9a-f]{40}$/,
      do: value,
      else: raise("V13_FULL_SHA must be a lowercase 40-hex commit")
  end

  defp parse_full_sha!(_value), do: raise("V13_FULL_SHA is required")
  defp parse_dirty!("true"), do: true
  defp parse_dirty!("false"), do: false
  defp parse_dirty!(_value), do: raise("V13_DIRTY must be true or false")
end
