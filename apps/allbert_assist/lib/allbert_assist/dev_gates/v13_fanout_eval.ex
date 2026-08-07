defmodule AllbertAssist.DevGates.V13FanoutEval do
  @moduledoc """
  Opt-in real-model qualification for the v1.3 fan-out manager and composer.

  The exact FOV-3/FOV-4 requests exercise the production manager. The composer
  then receives a frozen seven-row matrix of layout-v2 snapshots.
  Acceptance uses only typed results, counts, closed manager evidence, validated
  body/provenance bindings, and content-free digests; prompts, answers,
  observations, model objects, and rendered reports are never printed or
  recorded in TestMetrics.

  v1.3 M9.b.6 adds the single-turn parity control: the exact FOV-4 prompt
  answered by one DirectAnswer call on the configured head, with no manager, no
  children, and no synthesis. It is the reference the operator scores fan-out
  child observations against, so fan-out is qualified on what fan-out controls —
  that decomposing a request does not make the answer materially worse than the
  same model answering it in one turn.

  The control's answer text is the thing being scored, so it cannot go into
  TestMetrics without breaking the content-free invariant. The metrics row
  carries only the call count, byte size, digest, and resolved profile; the exact
  text is written to a separate operator-named transcript path and nowhere else.
  """

  alias AllbertAssist.Actions.Intent.DirectAnswer
  alias AllbertAssist.DevGates.TestMetrics
  alias AllbertAssist.FirstRun.Disclosure
  alias AllbertAssist.Intent.FanoutManager
  alias AllbertAssist.Pack.EffectGuard
  alias AllbertAssist.Intent.FanoutPlan
  alias AllbertAssist.Models.ProviderAttempt
  alias AllbertAssist.Objectives.CanonicalJSON
  alias AllbertAssist.Objectives.Fanout.Budget
  alias AllbertAssist.Objectives.Fanout.Report
  alias AllbertAssist.Objectives.Fanout.ReportComposer.ReqLLMImplementation, as: Composer
  alias AllbertAssist.Objectives.Fanout.ReportComposer.SynthesisAgent
  alias AllbertAssist.Settings
  alias AllbertAssist.Settings.ModelRuntime
  alias AllbertAssist.Settings.Models

  @profile_binding_domain "allbert:v13-fanout-gate-profile-binding:v1\0"
  @mixed_mistral_profile "mistral_small31_24b_challenger"
  @mixed_mistral_model "mistral-small3.1:24b-instruct-2503-q4_K_M"
  @mixed_mistral_fields [
    provider: "local_ollama",
    model: @mixed_mistral_model,
    aliases: [],
    capabilities: ["text_generation"],
    media: %{
      "input_modalities" => ["text"],
      "output_modalities" => ["text"],
      "deployment_mode" => "local_endpoint"
    },
    temperature: 0.0,
    max_tokens: 1_024,
    timeout_ms: 60_000
  ]

  @fov3_id "fov3-supplied-data"
  @fov4_id "fov4-independent-architecture"
  @control_id "fov4-single-turn-control"
  @composition_case_ids ~w[
    composer-complementary-architecture
    composer-contrasting-energy
    composer-sequential-incident-response
    composer-supporting-archaeology
    composer-independent-travel
    composer-partial-data-migration
    composer-unrelated-domain-culinary
  ]
  @failure_stages ~w[
    none manager_admission transport_authorization provider_setup provider_call
    provider_output synthesis_schema synthesis_layout synthesis_validation synthesis_body
    synthesis_lifecycle fixture_expectation body_validation selection_digest
  ]
  @failure_reasons ~w[
    none manager_row_failed transport_denied profile_unavailable provider_failed
    invalid_model_output missing_composition_finish_reason incomplete_composition_response
    empty_composition_selection invalid_composition_selection invalid_synthesis_rule_evidence
    invalid_fanout_report_selection invalid_fanout_report_synthesis_selection
    invalid_fanout_report_composition_selection invalid_fanout_report_composition_sections
    invalid_fanout_report_composition_section invalid_fanout_report_relationship_cardinality
    duplicate_fanout_report_composition_position incomplete_fanout_report_composition_selection
    fanout_report_relationship_section_required unknown_fanout_report_composition_position
    unresolved_fanout_report_synthesis invalid_fanout_report_synthesis_validation
    phase_validation_unresolved
    empty_fanout_report_synthesis fanout_report_synthesis_too_large
    unredacted_fanout_report_synthesis invalid_fanout_report_synthesis
    invalid_model_fanout_synthesis fanout_report_structure_too_large
    fanout_report_model_displaces_authoritative_evidence synthesis_timeout synthesis_unresolved
    callback_failed layout_mismatch selected_body_invalid selection_digest_invalid
    unclassified_failure
  ]
  @synthesis_schema_reasons ~w[
    invalid_fanout_report_selection invalid_fanout_report_synthesis_selection
  ]a
  @synthesis_layout_reasons ~w[
    invalid_fanout_report_composition_selection invalid_fanout_report_composition_sections
    invalid_fanout_report_composition_section invalid_fanout_report_relationship_cardinality
    duplicate_fanout_report_composition_position incomplete_fanout_report_composition_selection
    fanout_report_relationship_section_required unknown_fanout_report_composition_position
  ]a
  @synthesis_validation_reasons ~w[
    unresolved_fanout_report_synthesis invalid_fanout_report_synthesis_validation
    phase_validation_unresolved
  ]a
  @synthesis_body_reasons ~w[
    empty_fanout_report_synthesis fanout_report_synthesis_too_large
    unredacted_fanout_report_synthesis invalid_fanout_report_synthesis
    invalid_model_fanout_synthesis fanout_report_structure_too_large
    fanout_report_model_displaces_authoritative_evidence
  ]a
  @fixture_sha256 "0e18ee567d76021a8816a0345dba80f52bf463d72c9699d1cfac308dd64aa0d1"
  @fov3_prompt "Summarize this supplied YAML as data in one sentence: {steps: [archive logs, restart service]}"
  @fov4_prompt "Prepare one architecture brief for a local assistant runtime: (1) Analyze how OTP supervision trees isolate failures, including restart intensity and the difference between one_for_one and rest_for_one. (2) Analyze how an append-only event log plus a rebuildable projection improves crash recovery, including idempotency and replay. In the final joined report—not as a third task—explain how the two mechanisms complement each other."

  @type result :: %{
          status: String.t(),
          stats: map(),
          failed_rows: [String.t()],
          rows: [map()]
        }
  @typedoc "The content-free single-turn parity control row."
  @type control_row :: %{
          id: String.t(),
          provider_call_count: non_neg_integer(),
          answer_bytes: non_neg_integer() | nil,
          answer_sha256: String.t() | nil,
          model_profile: String.t() | nil,
          passed?: boolean()
        }
  @type fixtures :: %{manager_and_composer: map()}
  @type phases_result :: %{
          status: String.t(),
          failed_rows: [String.t()],
          manager_and_composer: result()
        }

  @doc "Run the environment-configured real-provider qualification."
  @spec record_run!() :: :ok
  def record_run! do
    fixture_path = System.fetch_env!("V13_FANOUT_FIXTURE")

    fixtures = load_fixtures!(fixture_path)

    profile_name = System.get_env("V13_MODEL_PROFILE", "direct_answer_local")

    mixed_mistral? =
      "V13_FANOUT_MIXED_MISTRAL"
      |> System.get_env("false")
      |> parse_mixed_mistral!()

    profiles = configure_profiles!(profile_name, mixed_mistral?: mixed_mistral?)

    command =
      if mixed_mistral?,
        do: "bench-v13-fanout --mixed-mistral",
        else: "bench-v13-fanout --profile #{profile_name}"

    store = blank_to_nil(System.get_env("V13_FANOUT_STORE"))
    control_output = blank_to_nil(System.get_env("V13_FANOUT_CONTROL_OUTPUT"))
    full_sha = parse_full_sha!(System.get_env("V13_FULL_SHA"))
    dirty = parse_dirty!(System.get_env("V13_DIRTY"))

    control_opts =
      if control_output do
        [
          control_answerer: &direct_answer/2,
          control_profile: profiles.worker,
          control_context: control_context(profiles.worker, profiles.allbert_pack_epoch),
          control_output: control_output
        ]
      else
        []
      end

    phases =
      run_phases(fixtures,
        manager_and_composer:
          [
            profile: profiles.manager,
            manager_profile: profiles.manager,
            composer_profile: profiles.synthesis,
            manager_context: manager_context(profiles.manager, profiles.allbert_pack_epoch),
            composer_context: composer_context(profiles.synthesis, profiles.allbert_pack_epoch),
            composer_client: Composer,
            role_profile_bindings: profiles.bindings,
            command: command,
            store: store,
            full_sha: full_sha,
            dirty: dirty
          ] ++ control_opts
      )

    IO.puts(summary(phases.manager_and_composer))

    if phases.failed_rows != [] do
      IO.puts("failed_rows=#{Enum.join(phases.failed_rows, ",")}")
      raise "v1.3 fan-out qualification failed"
    end

    :ok
  end

  @doc "Load the frozen two-manager-row plus seven-case layout-v2 synthesis fixture."
  @spec load_fixture!(Path.t()) :: map()
  def load_fixture!(path) do
    fixture = path |> File.read!() |> Jason.decode!()

    cond do
      not valid_fixture?(fixture) ->
        raise("invalid v1.3 fan-out fixture")

      fixture_sha256(fixture) != @fixture_sha256 ->
        raise("invalid v1.3 fan-out fixture digest")

      true ->
        fixture
    end
  end

  @doc "Load and validate the frozen qualification fixture before runtime setup."
  @spec load_fixtures!(Path.t()) :: fixtures()
  def load_fixtures!(manager_fixture_path) do
    %{manager_and_composer: load_fixture!(manager_fixture_path)}
  end

  @doc "Return the SHA-256 of the canonical decoded manager/composer fixture."
  @spec fixture_sha256(map()) :: String.t()
  def fixture_sha256(fixture) when is_map(fixture),
    do: sha256(CanonicalJSON.encode(fixture))

  @doc "Run the recorded qualification phase and report its status."
  @spec run_phases(fixtures(), keyword()) :: phases_result()
  def run_phases(%{manager_and_composer: manager_fixture}, opts) when is_list(opts) do
    manager_result = run(manager_fixture, Keyword.fetch!(opts, :manager_and_composer))

    %{
      status: if(manager_result.failed_rows == [], do: "passed", else: "failed"),
      failed_rows: manager_result.failed_rows,
      manager_and_composer: manager_result
    }
  end

  @doc "Evaluate the fixture and append one content-free TestMetrics row."
  @spec run(map(), keyword()) :: result()
  def run(fixture, opts) when is_map(fixture) and is_list(opts) do
    epoch = ready_epoch!(opts)
    :ok = require_current_epoch(epoch)
    started = System.monotonic_time(:millisecond)
    fixture_sha256 = validated_fixture_sha256!(fixture)
    manager = Keyword.get(opts, :manager, &FanoutManager.respond/2)

    manager_context =
      Keyword.get(opts, :manager_context, %{
        model_profile: Keyword.fetch!(opts, :manager_profile)
      })
      |> Map.put(:allbert_pack_epoch, epoch)

    composer_context =
      opts
      |> Keyword.fetch!(:composer_context)
      |> Map.put(:allbert_pack_epoch, epoch)

    control_opts =
      Keyword.update(opts, :control_context, %{allbert_pack_epoch: epoch}, fn context ->
        Map.put(context, :allbert_pack_epoch, epoch)
      end)

    control = control_row(control_opts)
    fov3 = manager_row(fixture, @fov3_id, manager, manager_context)
    fov4 = manager_row(fixture, @fov4_id, manager, manager_context)

    composition_rows =
      composition_rows(
        fixture,
        fov4,
        Keyword.get(opts, :composer_client, Composer),
        Keyword.get(opts, :composer_authorizer, &authorize_composer/2),
        Keyword.fetch!(opts, :composer_profile),
        composer_context
      )

    rows = List.wrap(control) ++ [fov3, fov4] ++ composition_rows
    failed_rows = for %{passed?: false, id: id} <- rows, do: id
    status = if failed_rows == [], do: "passed", else: "failed"
    profile = opts |> Keyword.fetch!(:profile) |> profile_name()

    stats =
      stats(
        profile,
        fixture_sha256,
        fov3,
        fov4,
        composition_rows,
        Keyword.get(opts, :role_profile_bindings, %{})
      )
      |> Map.merge(control_stats(control))

    :ok = require_current_epoch(epoch)

    TestMetrics.record(%{
      store: Keyword.get(opts, :store),
      git_sha: opts |> Keyword.get(:full_sha) |> short_sha(),
      full_sha: Keyword.get(opts, :full_sha),
      dirty: Keyword.get(opts, :dirty),
      cwd: "apps/allbert_assist",
      gate: "bench-v13-fanout",
      phase_or_step: "manager-and-composer",
      corpus_id: fixture["corpus_id"],
      command: Keyword.get(opts, :command, "bench-v13-fanout --profile #{profile}"),
      status: status,
      wall_ms: System.monotonic_time(:millisecond) - started,
      stats: stats
    })

    %{status: status, stats: stats, failed_rows: failed_rows, rows: composition_rows}
  end

  @doc """
  Answer the exact FOV-4 prompt once on the configured head, with no fan-out.

  This is the parity reference. It deliberately does not go through the manager,
  the plan compiler, Objectives, or the composer: those are the very things the
  control exists to hold fan-out accountable to. A control that routed through
  any of them could not distinguish "the model does not know this" from
  "decomposing made it worse", which is the only question this row answers.
  """
  @spec run_control(keyword()) :: control_row() | nil
  def run_control(opts) when is_list(opts), do: control_row(opts)

  @doc "Return the exact frozen FOV-4 prompt the control and the manager share."
  @spec control_prompt() :: String.t()
  def control_prompt, do: @fov4_prompt

  defp control_row(opts) do
    case Keyword.get(opts, :control_answerer) do
      nil -> nil
      answerer -> control_row(answerer, opts)
    end
  end

  defp control_row(answerer, opts) do
    context =
      opts
      |> Keyword.get(:control_context, %{})
      |> Map.put(:model_profile, Keyword.get(opts, :control_profile))

    {context, counter} = ProviderAttempt.attach(context)
    :ok = require_current_epoch(Map.get(context, :allbert_pack_epoch))
    result = invoke(fn -> answerer.(@fov4_prompt, context) end)
    calls = ProviderAttempt.count(counter)
    message = control_message(result)

    row = %{
      id: @control_id,
      provider_call_count: calls,
      answer_bytes: if(message, do: byte_size(message)),
      answer_sha256: if(message, do: sha256(message)),
      model_profile: control_profile_name(result, opts),
      # One call is the whole point: a control that retried or fell back would
      # be a different amount of compute than the fan-out row it anchors.
      passed?: calls == 1 and is_binary(message) and message != ""
    }

    :ok = require_current_epoch(Map.get(context, :allbert_pack_epoch))
    write_control_transcript(Keyword.get(opts, :control_output), row, message)
    row
  end

  defp control_message({:ok, %{message: message}}) when is_binary(message), do: message
  defp control_message(_result), do: nil

  defp control_profile_name(_result, opts) do
    case Keyword.get(opts, :control_profile) do
      nil -> nil
      profile -> profile_name(profile)
    end
  end

  defp control_stats(nil), do: %{}

  defp control_stats(row) do
    %{
      control_status: if(row.passed?, do: "passed", else: "failed"),
      control_provider_call_count: row.provider_call_count,
      control_answer_bytes: row.answer_bytes,
      control_answer_sha256: row.answer_sha256,
      control_model_profile: row.model_profile
    }
  end

  # The transcript is the operator's scoring input and the only place the exact
  # answer bytes are written. TestMetrics never sees them.
  defp write_control_transcript(nil, _row, _message), do: :ok

  defp write_control_transcript(path, row, message) do
    payload = %{
      "id" => @control_id,
      "prompt" => @fov4_prompt,
      "answer" => message,
      "answer_sha256" => row.answer_sha256,
      "answer_bytes" => row.answer_bytes,
      "provider_call_count" => row.provider_call_count,
      "model_profile" => row.model_profile,
      "status" => if(row.passed?, do: "passed", else: "failed")
    }

    path |> Path.dirname() |> File.mkdir_p!()
    File.write!(path, CanonicalJSON.encode(payload))
  end

  defp manager_row(fixture, id, manager, context) do
    :ok = require_current_epoch(Map.get(context, :allbert_pack_epoch))
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
      model_profile: Map.get(diagnostic, :model_profile),
      model_profile_sha256: Map.get(diagnostic, :model_profile_sha256),
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
      model_profile: Map.get(diagnostic, :model_profile),
      model_profile_sha256: Map.get(diagnostic, :model_profile_sha256),
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
      model_profile: nil,
      model_profile_sha256: nil,
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

  defp composition_rows(fixture, %{passed?: true}, client, authorizer, profile, context) do
    Enum.map(fixture["composition_cases"], fn composition_case ->
      composition_row(composition_case, client, authorizer, profile, context)
    end)
  end

  defp composition_rows(fixture, _fov4, _client, _authorizer, _profile, _context) do
    Enum.map(fixture["composition_cases"], fn composition_case ->
      failed_composition(composition_case, "manager_admission", "manager_row_failed")
    end)
  end

  defp composition_row(composition_case, client, authorizer, profile, context) do
    # Own the attempt counter so a row that fails inside synthesis still reports
    # the calls it consumed. The agent reuses a supplied counter, so this
    # observes the same physical attempts it enforces its own bounds against.
    {context, counter} = ProviderAttempt.attach(context)

    with {:ok, snapshot} <- fixture_snapshot(composition_case["snapshot"]),
         :ok <- require_current_epoch(Map.get(context, :allbert_pack_epoch)),
         :ok <- authorize_result(invoke(fn -> authorizer.(profile, context) end)),
         :ok <- require_current_epoch(Map.get(context, :allbert_pack_epoch)),
         {:ok, prepared} <-
           synthesis_result(
             invoke(fn ->
               SynthesisAgent.run(
                 snapshot,
                 profile,
                 context,
                 client,
                 Map.fetch!(context, :timeout_ms)
               )
             end)
           ) do
      composed_row(composition_case, snapshot, profile, prepared)
    else
      {:error, {stage, reason}} ->
        failed_composition(composition_case, stage, reason, observed_evidence(counter))

      _unclassified ->
        failed_composition(
          composition_case,
          "synthesis_lifecycle",
          "unclassified_failure",
          observed_evidence(counter)
        )
    end
  end

  # A row that never reached the provider reports no calls rather than zero, so
  # "not attempted" stays distinguishable from "attempted and returned nothing".
  defp observed_evidence(counter) do
    case ProviderAttempt.phase_counts(counter) do
      %{total: 0} ->
        %{}

      %{total: total, generation: generation} ->
        %{
          provider_call_count: total,
          generation_call_count: generation
        }
    end
  end

  # Once a synthesis result exists, its attempt evidence is real and survives
  # every later rejection. A row that reached the provider and then failed
  # validation must not report null calls: the gate would under-report actual
  # provider usage on exactly the paths worth auditing.
  defp composed_row(composition_case, snapshot, profile, prepared) do
    attempted = attempted_evidence(prepared)

    with :ok <- expected_layout(composition_case, prepared),
         {:ok, provenance} <- provenance(profile, prepared),
         :ok <- selected_body_valid(snapshot, prepared, provenance),
         phase_evidence <- phase_evidence(provenance),
         {:ok, selection_sha256} <- selection_digest(provenance) do
      successful_composition(
        composition_case,
        prepared,
        provenance,
        phase_evidence,
        selection_sha256
      )
    else
      {:error, {stage, reason}} ->
        failed_composition(composition_case, stage, reason, attempted)
    end
  end

  defp attempted_evidence(prepared) do
    prepared
    |> Map.take([:generation_call_count, :provider_call_count])
    |> Map.filter(fn {_key, value} -> is_integer(value) end)
  end

  defp authorize_result(:ok), do: :ok

  defp authorize_result(_denied),
    do: {:error, {"transport_authorization", "transport_denied"}}

  defp synthesis_result({:ok, prepared}) when is_map(prepared), do: {:ok, prepared}

  defp synthesis_result({:error, reason}), do: {:error, classify_synthesis_failure(reason)}

  defp synthesis_result(_invalid),
    do: {:error, {"synthesis_lifecycle", "synthesis_unresolved"}}

  defp classify_synthesis_failure({:profile_unavailable, _reason}),
    do: {"provider_setup", "profile_unavailable"}

  defp classify_synthesis_failure({:provider_failed, _reason}),
    do: {"provider_call", "provider_failed"}

  defp classify_synthesis_failure({:invalid_model_output, reason}),
    do: classify_invalid_model_output(reason)

  defp classify_synthesis_failure(:fanout_synthesis_timeout),
    do: {"synthesis_lifecycle", "synthesis_timeout"}

  defp classify_synthesis_failure(:callback_failed),
    do: {"synthesis_lifecycle", "callback_failed"}

  defp classify_synthesis_failure({:phase_validation_unresolved, _closed_reason}),
    do: {"synthesis_validation", "phase_validation_unresolved"}

  defp classify_synthesis_failure(_reason),
    do: {"synthesis_lifecycle", "unclassified_failure"}

  defp classify_invalid_model_output(:missing_composition_finish_reason),
    do: {"provider_output", "missing_composition_finish_reason"}

  defp classify_invalid_model_output({:incomplete_composition_response, _reason}),
    do: {"provider_output", "incomplete_composition_response"}

  defp classify_invalid_model_output(reason)
       when reason in [
              :empty_composition_selection,
              :invalid_composition_selection,
              :invalid_synthesis_rule_evidence
            ],
       do: {"provider_output", Atom.to_string(reason)}

  defp classify_invalid_model_output(reason) when reason in @synthesis_schema_reasons,
    do: {"synthesis_schema", Atom.to_string(reason)}

  defp classify_invalid_model_output(reason) when reason in @synthesis_layout_reasons,
    do: {"synthesis_layout", Atom.to_string(reason)}

  defp classify_invalid_model_output(reason) when reason in @synthesis_validation_reasons,
    do: {"synthesis_validation", Atom.to_string(reason)}

  defp classify_invalid_model_output(reason) when reason in @synthesis_body_reasons,
    do: {"synthesis_body", Atom.to_string(reason)}

  defp classify_invalid_model_output(_reason),
    do: {"provider_output", "invalid_model_output"}

  defp expected_layout(composition_case, prepared) do
    {:ok, expected} = fixture_expected(composition_case["expected"])

    if layout_matches?(prepared[:layout], expected) do
      :ok
    else
      {:error, {"fixture_expectation", "layout_mismatch"}}
    end
  end

  defp layout_matches?(
         %{layout_version: version, sections: produced},
         %{layout_version: version, sections: expected}
       )
       when length(produced) == length(expected) do
    produced |> Enum.zip(expected) |> Enum.all?(&section_matches?/1)
  end

  defp layout_matches?(_produced, _expected), do: false

  # The partition is the report's structural claim about which child each
  # section covers, so it is always exact. The relationship word only selects a
  # heading and an intro sentence, so it is pinned exactly where the operator's
  # own request names it -- "contrast these", "how they complement each other",
  # "as an independent finding" -- which tests instruction-following. Where the
  # request names only that observations belong together, more than one label
  # is defensible and the fixture author's pick is not privileged; production
  # has already enforced the one objective constraint on it, namely that a
  # single-position section is independent and a multi-position section is not.
  defp section_matches?({produced, expected}) do
    produced.ordered_queue_positions == expected.ordered_queue_positions and
      relationship_matches?(produced.relationship, expected)
  end

  defp relationship_matches?(_relationship, %{relationship_source: :model}), do: true

  defp relationship_matches?(relationship, %{relationship: expected}),
    do: relationship == expected

  defp selected_body_valid(snapshot, prepared, provenance) do
    case Report.validate_selected_body(snapshot, "model", prepared.body, provenance) do
      :ok ->
        :ok

      {:error, _reason} ->
        {:error, {"body_validation", "selected_body_invalid"}}
    end
  end

  defp selection_digest(provenance) do
    case Report.selection_digest("model", provenance) do
      {:ok, digest} ->
        {:ok, digest}

      {:error, _reason} ->
        {:error, {"selection_digest", "selection_digest_invalid"}}
    end
  end

  defp successful_composition(
         composition_case,
         prepared,
         provenance,
         phase_evidence,
         selection_sha256
       ) do
    sections = prepared.layout.sections

    %{
      id: composition_case["id"],
      domain: composition_case["domain"],
      passed?: true,
      valid?: true,
      layout_version: prepared.layout.layout_version,
      relationship: sections |> List.first() |> Map.fetch!(:relationship),
      relationships: Enum.map(sections, & &1.relationship),
      ordered_queue_positions: Enum.flat_map(sections, & &1.ordered_queue_positions),
      failure_stage: "none",
      failure_reason: "none",
      body_sha256: sha256(prepared.body),
      provenance_sha256: sha256(CanonicalJSON.encode(provenance)),
      selection_sha256: selection_sha256
    }
    |> Map.merge(phase_evidence)
  end

  defp failed_composition(composition_case, stage, reason, attempted \\ %{})

  defp failed_composition(composition_case, stage, reason, attempted)
       when stage in @failure_stages and reason in @failure_reasons and is_map(attempted) do
    %{
      id: composition_case["id"],
      domain: composition_case["domain"],
      passed?: false,
      valid?: false,
      layout_version: nil,
      relationship: "invalid",
      relationships: [],
      ordered_queue_positions: [],
      failure_stage: stage,
      failure_reason: reason,
      body_sha256: nil,
      provenance_sha256: nil,
      selection_sha256: nil,
      generation_call_count: Map.get(attempted, :generation_call_count),
      provider_call_count: Map.get(attempted, :provider_call_count)
    }
  end

  defp provenance(
         profile,
         %{layout: %{layout_version: layout_version, sections: sections}} = prepared
       ) do
    required = [
      :synthesis_contract_version,
      :generation_call_count,
      :provider_call_count,
      :validation_outcome,
      :covered_queue_positions,
      :synthesis_sha256
    ]

    if Enum.all?(required, &Map.has_key?(prepared, &1)) do
      {:ok,
       prepared
       |> Map.take(required)
       |> Map.merge(%{
         model_profile: field(profile, :name),
         provider: field(profile, :provider),
         model: field(profile, :model),
         layout_version: layout_version,
         sections: sections
       })}
    else
      {:error, {"synthesis_validation", "invalid_fanout_report_synthesis_validation"}}
    end
  end

  defp provenance(_profile, _prepared),
    do: {:error, {"synthesis_validation", "invalid_fanout_report_synthesis_validation"}}

  defp phase_evidence(provenance) do
    Map.take(provenance, [:generation_call_count, :provider_call_count])
  end

  defp stats(profile, fixture_sha256, fov3, fov4, compositions, role_profile_bindings) do
    primary = List.first(compositions)

    %{
      profile: profile,
      role_profile_bindings: role_profile_bindings,
      fixture_sha256: fixture_sha256,
      manager_rows: 2,
      manager_rows_passed: Enum.count([fov3, fov4], & &1.passed?),
      supplied_data_kind: fov3.kind,
      supplied_data_child_count: fov3.child_count,
      supplied_data_join_role: fov3.join_role,
      supplied_data_policy_outcome: fov3.policy_outcome,
      supplied_data_manager_attempts: fov3.attempts,
      supplied_data_reviewed: fov3.reviewed,
      supplied_data_model_profile: fov3.model_profile,
      supplied_data_model_profile_sha256: fov3.model_profile_sha256,
      adaptive_kind: fov4.kind,
      adaptive_child_count: fov4.child_count,
      adaptive_join_role: fov4.join_role,
      adaptive_policy_outcome: fov4.policy_outcome,
      adaptive_manager_attempts: fov4.attempts,
      adaptive_reviewed: fov4.reviewed,
      adaptive_model_profile: fov4.model_profile,
      adaptive_model_profile_sha256: fov4.model_profile_sha256,
      composition_rows: length(compositions),
      composition_rows_passed: Enum.count(compositions, & &1.passed?),
      composition_layout_version: primary.layout_version,
      composition_relationship: primary.relationship,
      composition_ordered_queue_positions: primary.ordered_queue_positions,
      composition_relationship_counts:
        compositions |> Enum.flat_map(& &1.relationships) |> Enum.frequencies(),
      composition_domain_count: compositions |> Enum.map(& &1.domain) |> Enum.uniq() |> length(),
      composition_failure_stage_by_row: row_map(compositions, :failure_stage),
      composition_failure_reason_by_row: row_map(compositions, :failure_reason),
      composition_body_sha256_by_row: row_map(compositions, :body_sha256),
      composition_provenance_sha256_by_row: row_map(compositions, :provenance_sha256),
      composition_selection_sha256_by_row: row_map(compositions, :selection_sha256),
      composition_generation_call_count_by_row: row_map(compositions, :generation_call_count),
      composition_provider_call_count_by_row: row_map(compositions, :provider_call_count),
      composition_valid: Enum.all?(compositions, & &1.valid?)
    }
  end

  defp row_map(rows, key), do: Map.new(rows, &{&1.id, Map.fetch!(&1, key)})

  @doc "Configure the uniform gate profile or its one frozen mixed-Mistral comparison."
  @spec configure_profiles!(String.t(), keyword()) :: %{
          worker: map(),
          manager: map(),
          synthesis: map(),
          bindings: map()
        }
  def configure_profiles!(profile_name, opts \\ []) do
    {:ok, epoch} = EffectGuard.admit_ready()
    :ok = EffectGuard.validate(epoch)
    context = %{actor: "v13-fanout-eval", audit?: false, allbert_pack_epoch: epoch}
    mixed_mistral? = Keyword.get(opts, :mixed_mistral?, false)

    if mixed_mistral? and profile_name != "direct_answer_local" do
      raise "unable to configure v1.3 fan-out profile: :mixed_mistral_requires_direct_answer_local"
    end

    fanout_profile = if mixed_mistral?, do: @mixed_mistral_profile, else: profile_name

    names = %{
      worker: profile_name,
      manager: fanout_profile,
      synthesis: fanout_profile
    }

    with {:ok, worker_profile} <- Settings.resolve_model_profile(profile_name),
         :ok <- validate_worker_profile(worker_profile, mixed_mistral?),
         :ok <- validate_epoch(epoch),
         :ok <- maybe_seed_mixed_mistral(mixed_mistral?, context),
         {:ok, configured} <- resolve_role_profiles(names),
         :ok <- validate_epoch(epoch),
         :ok <- enable_role_providers(configured, context),
         :ok <- validate_epoch(epoch),
         {:ok, _} <-
           Settings.put("model_preferences.tasks.direct_answer", [profile_name], context),
         {:ok, _} <-
           Settings.put("model_preferences.tasks.fanout_manager", [fanout_profile], context),
         {:ok, _} <-
           Settings.put("model_preferences.tasks.fanout_synthesis", [fanout_profile], context),
         {:ok, _} <- Settings.put("intent.direct_answer_model_enabled", true, context),
         {:ok, %{profile: worker}} <- Models.for(:direct_answer, context),
         {:ok, %{profile: manager}} <- Models.for(:fanout_manager, context),
         {:ok, %{profile: synthesis}} <- Models.for(:fanout_synthesis, context),
         {:ok, bindings} <-
           profile_bindings(%{worker: worker, manager: manager, synthesis: synthesis}) do
      %{
        worker: worker,
        manager: manager,
        synthesis: synthesis,
        bindings: bindings,
        allbert_pack_epoch: epoch
      }
    else
      {:error, reason} -> raise "unable to configure v1.3 fan-out profile: #{inspect(reason)}"
    end
  end

  defp validate_worker_profile(_profile, false), do: :ok

  defp validate_worker_profile(
         %{
           name: "direct_answer_local",
           provider: "local_ollama",
           provider_endpoint_kind: "local_endpoint",
           model: "qwen2.5:7b"
         },
         true
       ),
       do: :ok

  defp validate_worker_profile(_profile, true), do: {:error, :mixed_mistral_worker_drift}

  defp maybe_seed_mixed_mistral(false, _context), do: :ok

  defp maybe_seed_mixed_mistral(true, context) do
    Enum.reduce_while(@mixed_mistral_fields, :ok, fn {field, value}, :ok ->
      case Settings.put("model_profiles.#{@mixed_mistral_profile}.#{field}", value, context) do
        {:ok, _setting} -> {:cont, :ok}
        {:error, reason} -> {:halt, {:error, {:mixed_mistral_seed_failed, field, reason}}}
      end
    end)
  end

  defp resolve_role_profiles(names) do
    Enum.reduce_while(names, {:ok, %{}}, fn {role, name}, {:ok, profiles} ->
      case Settings.resolve_model_profile(name) do
        {:ok, profile} -> {:cont, {:ok, Map.put(profiles, role, profile)}}
        {:error, reason} -> {:halt, {:error, {:role_profile_unavailable, role, reason}}}
      end
    end)
  end

  defp enable_role_providers(profiles, context) do
    profiles
    |> Map.values()
    |> Enum.map(& &1.provider)
    |> Enum.uniq()
    |> Enum.reduce_while(:ok, fn provider, :ok ->
      case Settings.put("providers.#{provider}.enabled", true, context) do
        {:ok, _setting} -> {:cont, :ok}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
  end

  defp validate_epoch(epoch) do
    case EffectGuard.validate(epoch) do
      :ok -> :ok
      {:error, _reason} -> {:error, :product_not_ready}
    end
  end

  defp profile_bindings(profiles) do
    Enum.reduce_while(profiles, {:ok, %{}}, fn {role, profile}, {:ok, bindings} ->
      case profile_binding(role, profile) do
        {:ok, binding} ->
          {:cont, {:ok, Map.put(bindings, Atom.to_string(role), binding)}}

        {:error, reason} ->
          {:halt, {:error, {:invalid_role_profile_binding, role, reason}}}
      end
    end)
  end

  defp profile_binding(role, profile) do
    with {:ok, transport} <- ModelRuntime.effective_transport(profile) do
      projection = %{
        "role" => Atom.to_string(role),
        "profile" =>
          Map.take(profile, [
            :name,
            :provider,
            :provider_type,
            :provider_endpoint_kind,
            :model,
            :aliases,
            :capabilities,
            :media,
            :temperature,
            :max_tokens,
            :timeout_ms
          ]),
        "endpoint_sha256" => transport.endpoint_sha256,
        "credential_reference_sha256" => optional_sha256(profile.provider_api_key_ref)
      }

      {:ok,
       %{
         profile: profile.name,
         provider: profile.provider,
         model: profile.model,
         endpoint_class: to_string(transport.endpoint_class),
         endpoint_sha256: transport.endpoint_sha256,
         configuration_sha256: sha256(@profile_binding_domain <> CanonicalJSON.encode(projection))
       }}
    end
  end

  defp optional_sha256(value) when is_binary(value) and value != "", do: sha256(value)
  defp optional_sha256(_missing), do: nil

  defp manager_context(_profile, epoch) do
    %{
      actor: "local",
      user_id: "local",
      request: %{channel: :cli},
      model_enabled?: true,
      allbert_pack_epoch: epoch
    }
  end

  # The control is one ordinary single-turn request on the Worker head: same
  # surface, same disclosure, no fan-out capability in the context.
  defp control_context(_profile, epoch) do
    %{
      actor: "local",
      user_id: "local",
      request: %{channel: :cli},
      model_enabled?: true,
      allbert_pack_epoch: epoch
    }
  end

  defp direct_answer(text, context) do
    :ok = require_current_epoch(Map.get(context, :allbert_pack_epoch))
    DirectAnswer.run(%{text: text}, context)
  end

  defp composer_context(profile, epoch) do
    {:ok, limits} = Budget.limits()

    %{
      max_output_tokens: min(limit(profile, :max_tokens, 1_024), 1_024),
      timeout_ms: Enum.min([limit(profile, :timeout_ms, 10_000), limits.max_elapsed_ms, 60_000]),
      allbert_pack_epoch: epoch
    }
  end

  defp require_current_epoch(epoch) do
    case EffectGuard.validate(epoch) do
      :ok -> :ok
      {:error, _reason} -> raise "Allbert product is not ready; retry the v1.3 fan-out eval."
    end
  end

  # `run/2` is the public gate boundary. Production callers inherit the epoch
  # admitted while configuring profiles; pure fixture callers admit once here.
  # Every nested callback receives that same exact epoch rather than admitting
  # independently.
  defp ready_epoch!(opts) do
    epochs =
      for key <- [:manager_context, :control_context, :composer_context],
          context = Keyword.get(opts, key),
          is_map(context),
          Map.has_key?(context, :allbert_pack_epoch),
          do: Map.fetch!(context, :allbert_pack_epoch)

    case Enum.uniq(epochs) do
      [] ->
        {:ok, epoch} = EffectGuard.admit_ready()
        epoch

      [epoch] ->
        epoch

      _conflicting_epochs ->
        raise "Allbert product is not ready; conflicting Pack epochs were supplied."
    end
  end

  defp authorize_composer(profile, _context) do
    disclosure = %{actor: "local", user_id: "local", request: %{channel: :cli}}
    Disclosure.authorize_transport(profile, disclosure)
  end

  defp valid_fixture?(
         %{
           "schema_version" => 2,
           "corpus_id" => corpus_id,
           "manager_cases" => [
             %{"id" => @fov3_id, "prompt" => @fov3_prompt, "expected" => fov3} = manager0,
             %{"id" => @fov4_id, "prompt" => @fov4_prompt, "expected" => fov4} = manager1
           ],
           "composition_cases" => composition_cases
         } = fixture
       ) do
    exact_keys?(fixture, ~w[schema_version corpus_id manager_cases composition_cases]) and
      exact_keys?(manager0, ~w[id prompt expected]) and
      exact_keys?(manager1, ~w[id prompt expected]) and
      nonempty?(corpus_id) and
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
      } and valid_composition_cases?(composition_cases)
  end

  defp valid_fixture?(_fixture), do: false

  defp validated_fixture_sha256!(fixture) do
    digest = fixture_sha256(fixture)

    if valid_fixture?(fixture) and digest == @fixture_sha256,
      do: digest,
      else: raise("invalid v1.3 fan-out fixture digest")
  end

  defp valid_composition_cases?(cases) when is_list(cases) do
    Enum.all?(cases, &is_map/1) and
      Enum.map(cases, & &1["id"]) == @composition_case_ids and
      valid_domains?(cases) and
      Enum.all?(cases, &valid_composition_case?/1) and
      MapSet.equal?(
        covered_relationships(cases),
        MapSet.new(~w[complementary contrasting sequential supporting independent])
      ) and
      Enum.any?(cases, &(&1["snapshot"]["join_outcome"] == "partial"))
  end

  defp valid_composition_cases?(_cases), do: false

  defp valid_domains?(cases) do
    domains = Enum.map(cases, & &1["domain"])
    Enum.all?(domains, &nonempty?/1) and length(Enum.uniq(domains)) == length(cases)
  end

  defp valid_composition_case?(
         %{
           "id" => id,
           "domain" => domain,
           "snapshot" => raw_snapshot,
           "expected" => raw_expected
         } = composition_case
       ) do
    with true <- exact_keys?(composition_case, ~w[id domain snapshot expected]),
         true <- nonempty?(id) and nonempty?(domain),
         {:ok, snapshot} <- fixture_snapshot(raw_snapshot),
         :ok <- Report.synthesis_eligibility(snapshot),
         {:ok, expected} <- fixture_expected(raw_expected),
         {:ok, prepared} <-
           Report.prepare_synthesis(snapshot, fixture_result(snapshot, expected.sections)),
         true <- layout_matches?(prepared.layout, expected) do
      true
    else
      _invalid -> false
    end
  rescue
    _invalid_fixture -> false
  end

  defp valid_composition_case?(_composition_case), do: false

  defp fixture_snapshot(
         %{
           "version" => 2,
           "parent_id" => parent_id,
           "title" => title,
           "original_request" => original_request,
           "status" => status,
           "join_outcome" => join_outcome,
           "plan" => plan,
           "children" => raw_children
         } = raw_snapshot
       ) do
    if exact_keys?(
         raw_snapshot,
         ~w[version parent_id title original_request status join_outcome plan children]
       ) and is_list(raw_children) do
      with {:ok, children} <- fixture_children(raw_children) do
        {:ok,
         %{
           version: 2,
           parent_id: parent_id,
           title: title,
           original_request: original_request,
           status: status,
           join_outcome: join_outcome,
           plan: plan,
           children: children
         }}
      end
    else
      {:error, :invalid_fixture_snapshot}
    end
  rescue
    _invalid_fixture -> {:error, :invalid_fixture_snapshot}
  end

  defp fixture_snapshot(_raw_snapshot), do: {:error, :invalid_fixture_snapshot}

  defp fixture_expected(%{"layout_version" => 2, "sections" => raw_sections} = expected) do
    if exact_keys?(expected, ~w[layout_version sections]) do
      with {:ok, sections} <- fixture_sections(raw_sections) do
        {:ok, %{layout_version: 2, sections: sections}}
      end
    else
      {:error, :invalid_fixture_expected}
    end
  rescue
    _invalid_fixture -> {:error, :invalid_fixture_expected}
  end

  defp fixture_expected(_expected), do: {:error, :invalid_fixture_expected}

  # The only caller guards is_list/1, so a non-list never reaches here.
  defp fixture_children(children) when is_list(children) do
    traverse_fixture(children, &fixture_child/1, :invalid_fixture_snapshot)
  end

  defp fixture_child(
         %{
           "id" => id,
           "queue_position" => queue_position,
           "title" => title,
           "objective" => objective,
           "expected_result" => expected_result,
           "status" => status,
           "detail" => detail,
           "effect_receipt_ref" => effect_receipt_ref,
           "result_authority" => result_authority,
           "quality_receipt_sha256" => quality_receipt_sha256
         } = child
       ) do
    if exact_keys?(
         child,
         ~w[
           id queue_position title objective expected_result status detail effect_receipt_ref
           result_authority quality_receipt_sha256
         ]
       ) do
      {:ok,
       %{
         id: id,
         queue_position: queue_position,
         title: title,
         objective: objective,
         expected_result: expected_result,
         status: status,
         detail: detail,
         effect_receipt_ref: effect_receipt_ref,
         result_authority: result_authority,
         quality_receipt_sha256: quality_receipt_sha256
       }}
    else
      {:error, :invalid_fixture_snapshot}
    end
  end

  defp fixture_child(_child), do: {:error, :invalid_fixture_snapshot}

  defp fixture_sections(sections) when is_list(sections) do
    traverse_fixture(sections, &fixture_section/1, :invalid_fixture_expected)
  end

  defp fixture_sections(_sections), do: {:error, :invalid_fixture_expected}

  defp fixture_section(
         %{
           "relationship" => relationship,
           "ordered_queue_positions" => ordered_queue_positions,
           "relationship_source" => source
         } = section
       )
       when source in ~w[request model] do
    if exact_keys?(section, ~w[relationship ordered_queue_positions relationship_source]) do
      {:ok,
       %{
         relationship: relationship,
         ordered_queue_positions: ordered_queue_positions,
         relationship_source: String.to_existing_atom(source)
       }}
    else
      {:error, :invalid_fixture_expected}
    end
  end

  defp fixture_section(_section), do: {:error, :invalid_fixture_expected}

  defp traverse_fixture(values, decoder, error_reason) do
    values
    |> Enum.reduce_while({:ok, []}, fn value, {:ok, decoded} ->
      case decoder.(value) do
        {:ok, item} -> {:cont, {:ok, [item | decoded]}}
        {:error, _reason} -> {:halt, {:error, error_reason}}
      end
    end)
    |> case do
      {:ok, decoded} -> {:ok, Enum.reverse(decoded)}
      {:error, _reason} = error -> error
    end
  end

  defp fixture_result(snapshot, sections) do
    completed_positions =
      snapshot.children
      |> Enum.filter(&(&1.status == "completed"))
      |> Enum.map(& &1.queue_position)
      |> Enum.sort()

    %{
      # relationship_source is gate-side expectation metadata, never part of
      # the layout contract Report validates.
      sections: Enum.map(sections, &Map.take(&1, [:relationship, :ordered_queue_positions])),
      advisory_synthesis: "Fixture validation advisory.",
      validation: %{outcome: "passed", covered_queue_positions: completed_positions}
    }
  end

  defp covered_relationships(cases) do
    cases
    |> Enum.flat_map(&get_in(&1, ["expected", "sections"]))
    |> Enum.map(& &1["relationship"])
    |> MapSet.new()
  end

  defp exact_keys?(map, keys) when is_map(map),
    do: map |> Map.keys() |> Enum.sort() == Enum.sort(keys)

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
      "composition=#{stats.composition_rows_passed}/#{stats.composition_rows} " <>
      "primary=#{stats.composition_relationship}:" <>
      Enum.join(stats.composition_ordered_queue_positions, ",") <>
      control_summary(stats) <>
      role_profile_summary(stats.role_profile_bindings)
  end

  defp control_summary(%{control_status: status} = stats) do
    " control=#{status}/#{stats.control_provider_call_count}call" <>
      " control_answer=#{stats.control_answer_bytes}B/#{stats.control_answer_sha256}"
  end

  defp control_summary(_stats), do: ""

  defp role_profile_summary(bindings) when map_size(bindings) == 3 do
    " profiles " <>
      Enum.map_join(~w[worker manager synthesis], " ", fn role ->
        binding = Map.fetch!(bindings, role)

        "#{role}=#{binding.profile}|#{binding.provider}|#{binding.model}|" <>
          "#{binding.endpoint_class}|#{binding.endpoint_sha256}|#{binding.configuration_sha256}"
      end)
  end

  defp role_profile_summary(_bindings), do: ""

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

  defp parse_mixed_mistral!("true"), do: true
  defp parse_mixed_mistral!("false"), do: false

  defp parse_mixed_mistral!(_value),
    do: raise("V13_FANOUT_MIXED_MISTRAL must be true or false")

  defp sha256(value) do
    :sha256
    |> :crypto.hash(value)
    |> Base.encode16(case: :lower)
  end
end
