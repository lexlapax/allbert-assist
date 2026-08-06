defmodule AllbertAssist.DevGates.V131HeadQualification do
  @moduledoc """
  Development-only answering-head qualification for v1.3.1.

  The fixture is an inert, digest-bound corpus. It can select one of six
  allowlisted validator names and supply closed phrase groups, but it cannot
  select code, modules, regular expressions, matching operations, runtime
  permissions, or provider behavior. Provider execution stays opt-in and uses
  the production DirectAnswer request assembly. Qualification output and
  TestMetrics evidence contain only provenance, counts, durations, closed
  failure reasons, and verdicts.
  """

  alias AllbertAssist.Actions.Intent.DirectAnswer.ReqLLMAnswerer
  alias AllbertAssist.DevGates.TestMetrics
  alias AllbertAssist.Objectives.CanonicalJSON
  alias AllbertAssist.Settings
  alias AllbertAssist.Settings.ModelRuntime

  @fixture_sha256 "258d118fe97e7a97b5b72cc8ef3654bc44a3ffb9ad8344b98331be5579993c00"
  @warmup_prompt "Answer with only the numeral 1."
  @command_deadline_ms 1_920_000
  @failure_reasons ~w[timeout refusal empty validator_failed transport_failure]
  @refusal_groups [
    ~w[i cannot],
    ~w[i can not],
    ~w[i do not have enough],
    ~w[i am unable],
    ~w[unable to],
    ~w[cannot comply],
    ~w[can not comply]
  ]
  @row_keys ~w[
    id class prompt validator required_concepts ordered_required_concepts
    prohibited_assertions positive_examples paraphrase_examples near_miss_examples
    refusal_examples
  ]
  @row_contracts [
    {"fact-otp-rest-for-one", "factual", "otp_rest_for_one_v1"},
    {"fact-event-log-replay", "factual", "event_replay_idempotency_v1"},
    {"fact-sqlite-wal-writers", "factual", "sqlite_wal_single_writer_v1"},
    {"rule-acknowledge-no-commitment", "instruction", "acknowledgment_no_commitment_v1"},
    {"rule-supplied-yaml-is-data", "instruction", "supplied_yaml_data_v1"},
    {"rule-answer-without-policy-narration", "instruction", "exact_answer_no_narration_v1"}
  ]

  @doc "Return the repository-owned frozen fixture path."
  @spec fixture_path() :: Path.t()
  def fixture_path do
    Path.expand("../../../test/fixtures/v1.3.1/head_qualification.json", __DIR__)
  end

  @doc "Return the frozen canonical decoded-fixture digest."
  @spec frozen_fixture_sha256() :: String.t()
  def frozen_fixture_sha256, do: @fixture_sha256

  @doc "Return the SHA-256 of a canonical decoded fixture."
  @spec fixture_sha256(map()) :: String.t()
  def fixture_sha256(fixture) when is_map(fixture) do
    :crypto.hash(:sha256, CanonicalJSON.encode(fixture))
    |> Base.encode16(case: :lower)
  end

  @doc "Load the frozen qualification corpus before any provider setup or call."
  @spec load_fixture!(Path.t()) :: map()
  def load_fixture!(path \\ fixture_path()) do
    fixture = path |> File.read!() |> Jason.decode!()

    case validate_fixture(fixture) do
      :ok ->
        if fixture_sha256(fixture) == @fixture_sha256,
          do: fixture,
          else: raise("invalid v1.3.1 head qualification fixture digest")

      {:error, _reason} ->
        raise "invalid v1.3.1 head qualification fixture"
    end
  end

  @doc false
  @spec validate_fixture(term()) :: :ok | {:error, :invalid_fixture}
  def validate_fixture(fixture) do
    if valid_fixture?(fixture), do: :ok, else: {:error, :invalid_fixture}
  end

  @doc "Run the environment-configured real-provider qualification."
  @spec record_run!() :: :ok
  def record_run! do
    fixture = load_fixture!(System.fetch_env!("V131_HEAD_FIXTURE"))
    profile_name = System.fetch_env!("V131_HEAD_PROFILE")
    model = System.fetch_env!("V131_HEAD_MODEL")
    trials = System.fetch_env!("V131_HEAD_TRIALS") |> parse_positive_integer!("trials")
    timeout_ms = System.fetch_env!("V131_HEAD_TIMEOUT_MS") |> parse_positive_integer!("timeout")
    profile = candidate_profile!(profile_name, model)

    result =
      run(fixture,
        profile: profile,
        trials: trials,
        timeout_ms: timeout_ms,
        store: blank_to_nil(System.get_env("V131_HEAD_STORE")),
        full_sha: parse_full_sha!(System.get_env("V131_FULL_SHA")),
        dirty: parse_dirty!(System.get_env("V131_DIRTY")),
        command:
          "qualify-head --profile #{profile_name} --model #{model} --trials #{trials} " <>
            "--timeout-ms #{timeout_ms}",
        progress: &print_progress/1
      )

    print_summary(result)

    if result.execution_status != "completed" do
      raise "v1.3.1 head qualification did not complete"
    end

    :ok
  end

  @doc "Run qualification under the frozen 32-minute command watchdog."
  @spec record_run_with_watchdog!() :: :ok
  def record_run_with_watchdog! do
    task = Task.async(&record_run!/0)

    case Task.yield(task, @command_deadline_ms) do
      {:ok, :ok} ->
        :ok

      {:exit, _reason} ->
        raise "v1.3.1 head qualification failed"

      nil ->
        Task.shutdown(task, :brutal_kill)
        raise "v1.3.1 head qualification exceeded its command watchdog"
    end
  end

  @doc "Normalize qualification text under the frozen v1 rules."
  @spec normalize(String.t()) :: [String.t()]
  def normalize(text) when is_binary(text) do
    text
    |> String.normalize(:nfc)
    |> String.downcase()
    |> canonical_punctuation()
    |> then(
      &Regex.scan(
        ~r/\d{4}-\d{2}-\d{2}|\d{1,2}:\d{2}|[\p{L}\p{N}]+(?:-[\p{L}\p{N}]+)*/u,
        &1
      )
    )
    |> List.flatten()
  end

  @doc "Score one provider response with the row's code-owned closed validator."
  @spec score(map(), String.t()) ::
          :pass | {:fail, :empty | :refusal | :validator_failed}
  def score(row, text) when is_map(row) and is_binary(text) do
    tokens = normalize(text)

    cond do
      tokens == [] -> {:fail, :empty}
      refusal?(tokens) -> {:fail, :refusal}
      validator_passes?(row, tokens) -> :pass
      true -> {:fail, :validator_failed}
    end
  end

  @doc "Run one profile serially and append content-free qualification evidence."
  def run(fixture, opts) when is_map(fixture) and is_list(opts) do
    corpus_digest = validated_fixture_sha256!(fixture)
    profile = Keyword.fetch!(opts, :profile)
    trials = Keyword.get(opts, :trials, fixture["trials"])
    timeout_ms = Keyword.get(opts, :timeout_ms, 60_000)
    validate_run_options!(trials, timeout_ms)

    answerer = Keyword.get(opts, :answerer, &ReqLLMAnswerer.answer/2)
    progress = Keyword.get(opts, :progress, fn _event -> :ok end)
    provenance = provenance(profile, corpus_digest, opts)
    context = qualification_context(profile, timeout_ms)

    {warmup_outcome, warmup_duration_ms} =
      timed_answer(answerer, @warmup_prompt, context, timeout_ms)

    execution = %{
      "warmup_status" =>
        if(match?({:ok, _message}, warmup_outcome), do: "passed", else: "failed"),
      "warmup_duration_ms" => warmup_duration_ms,
      "warmup_failure_reason" => warmup_failure_reason(warmup_outcome),
      "scored_trials_expected" => length(fixture["rows"]) * trials,
      "scored_trials_completed" => 0,
      "receive_timeout_ms" => timeout_ms,
      "total_timeout_ms" => timeout_ms,
      "max_retries" => 0,
      "command_deadline_ms" => @command_deadline_ms
    }

    progress.(%{
      stage: :warmup,
      status: execution["warmup_status"],
      duration_ms: warmup_duration_ms
    })

    case warmup_outcome do
      {:ok, _message} ->
        rows =
          Enum.map(fixture["rows"], fn row ->
            result = run_row(row, trials, answerer, context, timeout_ms, provenance)
            progress.(%{stage: :row, result: result})
            result
          end)

        execution = Map.put(execution, "scored_trials_completed", length(rows) * trials)
        summary = summary(rows, provenance)
        result = completed_result(rows, summary, execution, provenance)
        record_evidence(result, opts)
        result

      {:error, _reason} ->
        result = incomplete_result("environment_red", execution, provenance)
        record_evidence(result, opts)
        result
    end
  end

  defp run_row(row, trials, answerer, context, timeout_ms, provenance) do
    started = System.monotonic_time(:millisecond)

    outcomes =
      for _trial <- 1..trials do
        case timed_answer(answerer, row["prompt"], context, timeout_ms) do
          {{:ok, message}, _duration_ms} -> score(row, message)
          {{:error, reason}, _duration_ms} -> {:fail, reason}
        end
      end

    passes = Enum.count(outcomes, &(&1 == :pass))
    verdict = if passes == trials, do: "qualified", else: "unqualified"

    Map.merge(provenance, %{
      "row_id" => row["id"],
      "class" => row["class"],
      "trials" => trials,
      "passes" => passes,
      "failure_counts" => failure_counts(outcomes),
      "duration_ms" => System.monotonic_time(:millisecond) - started,
      "execution_status" => "completed",
      "threshold" => %{"passes" => trials, "rate" => 1.0},
      "verdict" => verdict
    })
  end

  defp completed_result(rows, summary, execution, provenance) do
    %{
      execution_status: "completed",
      verdict: summary["verdict"],
      rows: rows,
      summary: summary,
      execution: execution,
      provenance: provenance
    }
  end

  defp incomplete_result(status, execution, provenance) do
    %{
      execution_status: status,
      verdict: nil,
      rows: [],
      summary: nil,
      execution: execution,
      provenance: provenance
    }
  end

  defp summary(rows, provenance) do
    class_rates =
      rows
      |> Enum.group_by(& &1["class"])
      |> Map.new(fn {class, class_rows} ->
        passes = Enum.sum(Enum.map(class_rows, & &1["passes"]))
        trials = Enum.sum(Enum.map(class_rows, & &1["trials"]))
        {class, passes / trials}
      end)

    verdict =
      if Enum.all?(rows, &(&1["verdict"] == "qualified")) and
           Enum.all?(class_rates, fn {_class, rate} -> rate == 1.0 end),
         do: "qualified",
         else: "unqualified"

    Map.merge(provenance, %{
      "rows" => length(rows),
      "scored_trials" => Enum.sum(Enum.map(rows, & &1["trials"])),
      "passes" => Enum.sum(Enum.map(rows, & &1["passes"])),
      "class_rates" => class_rates,
      "execution_status" => "completed",
      "verdict" => verdict
    })
  end

  defp provenance(profile, corpus_digest, opts) do
    {:ok, transport} = ModelRuntime.effective_transport(profile)

    %{
      "schema_version" => 1,
      "run_sha" => Keyword.get(opts, :full_sha),
      "profile" => Map.fetch!(profile, :name),
      "provider" => Map.fetch!(profile, :provider),
      "model" => Map.fetch!(profile, :model),
      "endpoint_digest" => transport.endpoint_sha256,
      "corpus_digest" => corpus_digest
    }
  end

  defp qualification_context(profile, timeout_ms) do
    %{
      model_profile: profile,
      active_memory: [],
      image_inputs: [],
      model_timeout_ms: timeout_ms,
      model_total_timeout_ms: timeout_ms,
      model_max_retries: 0
    }
  end

  defp timed_answer(answerer, prompt, context, timeout_ms) do
    started = System.monotonic_time(:millisecond)
    task = Task.async(fn -> answerer.(prompt, context) end)

    outcome =
      case Task.yield(task, timeout_ms) do
        {:ok, {:ok, %{message: message}}} when is_binary(message) ->
          if String.trim(message) == "", do: {:error, :empty}, else: {:ok, message}

        {:ok, {:error, reason}} ->
          {:error, provider_failure_reason(reason)}

        {:ok, _other} ->
          {:error, :transport_failure}

        {:exit, _reason} ->
          {:error, :transport_failure}

        nil ->
          Task.shutdown(task, :brutal_kill)
          {:error, :timeout}
      end

    {outcome, System.monotonic_time(:millisecond) - started}
  end

  defp failure_counts(outcomes) do
    counts =
      outcomes
      |> Enum.flat_map(fn
        {:fail, reason} -> [Atom.to_string(reason)]
        :pass -> []
      end)
      |> Enum.frequencies()

    Map.new(@failure_reasons, &{&1, Map.get(counts, &1, 0)})
  end

  defp warmup_failure_reason({:ok, _message}), do: nil
  defp warmup_failure_reason({:error, reason}), do: Atom.to_string(reason)

  defp provider_failure_reason(reason) do
    atoms = nested_atoms(reason)

    cond do
      :empty_model_text in atoms -> :empty
      Enum.any?(atoms, &(&1 in [:timeout, :receive_timeout, :total_timeout])) -> :timeout
      true -> :transport_failure
    end
  end

  defp nested_atoms(value) when is_atom(value), do: [value]

  defp nested_atoms(value) when is_tuple(value),
    do: value |> Tuple.to_list() |> Enum.flat_map(&nested_atoms/1)

  defp nested_atoms(value) when is_list(value), do: Enum.flat_map(value, &nested_atoms/1)

  defp nested_atoms(value) when is_map(value),
    do: value |> Map.values() |> Enum.flat_map(&nested_atoms/1)

  defp nested_atoms(_value), do: []

  defp validator_passes?(%{"validator" => "supplied_yaml_data_v1"} = row, tokens) do
    common_validator?(row, tokens) and ordered_groups?(tokens, row["ordered_required_concepts"])
  end

  defp validator_passes?(%{"validator" => "exact_answer_no_narration_v1"} = row, tokens) do
    exact_tokens?(tokens, row["required_concepts"]) and
      none_groups?(tokens, row["prohibited_assertions"])
  end

  defp validator_passes?(%{"validator" => validator} = row, tokens)
       when validator in [
              "otp_rest_for_one_v1",
              "event_replay_idempotency_v1",
              "sqlite_wal_single_writer_v1",
              "acknowledgment_no_commitment_v1"
            ],
       do: common_validator?(row, tokens)

  defp validator_passes?(_row, _tokens), do: false

  defp common_validator?(row, tokens) do
    all_groups?(tokens, row["required_concepts"]) and
      none_groups?(tokens, row["prohibited_assertions"])
  end

  defp all_groups?(tokens, groups),
    do: Enum.all?(groups, &Enum.any?(&1, fn phrase -> contains?(tokens, normalize(phrase)) end))

  defp none_groups?(tokens, groups),
    do:
      Enum.all?(groups, &Enum.all?(&1, fn phrase -> not contains?(tokens, normalize(phrase)) end))

  defp ordered_groups?(tokens, groups) do
    Enum.reduce_while(groups, 0, fn group, offset ->
      indexes =
        group
        |> Enum.map(&normalize/1)
        |> Enum.map(&sequence_index(tokens, &1, offset))
        |> Enum.reject(&is_nil/1)

      case indexes do
        [] -> {:halt, false}
        indexes -> {:cont, Enum.min(indexes) + 1}
      end
    end) != false
  end

  defp exact_tokens?(tokens, [alternatives]),
    do: Enum.any?(alternatives, &(tokens == normalize(&1)))

  defp exact_tokens?(_tokens, _groups), do: false

  defp refusal?(tokens), do: Enum.any?(@refusal_groups, &contains?(tokens, &1))

  defp contains?(_tokens, []), do: false
  defp contains?(tokens, sequence), do: not is_nil(sequence_index(tokens, sequence, 0))

  defp sequence_index(tokens, sequence, offset) do
    tokens
    |> Enum.drop(offset)
    |> Enum.chunk_every(length(sequence), 1, :discard)
    |> Enum.find_index(&(&1 == sequence))
    |> case do
      nil -> nil
      index -> index + offset
    end
  end

  defp canonical_punctuation(text) do
    text
    |> String.replace(["‘", "’", "‚", "‛", "“", "”", "„", "‟"], "\"")
    |> String.replace(["‐", "‑", "‒", "–", "—", "―"], "-")
  end

  defp record_evidence(result, opts) do
    common = %{
      store: Keyword.get(opts, :store),
      git_sha: short_sha(Keyword.get(opts, :full_sha)),
      full_sha: Keyword.get(opts, :full_sha),
      dirty: Keyword.get(opts, :dirty),
      cwd: "apps/allbert_assist",
      gate: "qualify-head",
      corpus_id: "v131-head-qualification-v1",
      command: Keyword.get(opts, :command)
    }

    record_metric(common, "profile-execution", execution_metric(result))

    if result.execution_status == "completed" do
      Enum.each(result.rows, &record_metric(common, &1["row_id"], &1))
      record_metric(common, "profile-summary", result.summary)
    end
  end

  defp execution_metric(result) do
    result.provenance
    |> Map.merge(result.execution)
    |> Map.put("execution_status", result.execution_status)
    |> Map.put("verdict", result.verdict)
  end

  defp record_metric(common, phase, stats) do
    TestMetrics.record(
      Map.merge(common, %{
        phase_or_step: phase,
        status: if(stats["execution_status"] == "completed", do: "passed", else: "failed"),
        wall_ms: stats["duration_ms"] || stats["warmup_duration_ms"] || 0,
        stats: stats
      })
    )
  end

  defp candidate_profile!(profile_name, model) do
    with true <- nonempty?(profile_name),
         true <- valid_model_name?(model),
         {:ok, profile} <- Settings.resolve_model_profile(profile_name),
         true <- profile.provider_endpoint_kind == "local_endpoint",
         true <- profile.provider_type in ["local", "openai_compatible"],
         true <- "text_generation" in profile.capabilities do
      profile
      |> Map.put(:model, model)
      |> Map.put(:temperature, 0.0)
    else
      _reason -> raise "invalid v1.3.1 qualification candidate profile"
    end
  end

  defp valid_model_name?(model) do
    nonempty?(model) and byte_size(model) <= 240 and
      not String.contains?(model, ["\n", "\r", "\0"])
  end

  defp validate_run_options!(trials, timeout_ms) do
    if not (is_integer(trials) and trials > 0 and is_integer(timeout_ms) and timeout_ms > 0) do
      raise ArgumentError, "qualification trials and timeout must be positive integers"
    end
  end

  defp validated_fixture_sha256!(fixture) do
    case validate_fixture(fixture) do
      :ok ->
        digest = fixture_sha256(fixture)

        if digest == @fixture_sha256,
          do: digest,
          else: raise("invalid v1.3.1 head qualification fixture digest")

      {:error, _reason} ->
        raise "invalid v1.3.1 head qualification fixture"
    end
  end

  defp print_progress(%{stage: :warmup, status: status, duration_ms: duration_ms}) do
    IO.puts("qualify-head warmup status=#{status} duration_ms=#{duration_ms}")
  end

  defp print_progress(%{stage: :row, result: result}) do
    IO.puts(
      "qualify-head row=#{result["row_id"]} passes=#{result["passes"]}/#{result["trials"]} " <>
        "verdict=#{result["verdict"]} duration_ms=#{result["duration_ms"]}"
    )
  end

  defp print_summary(result) do
    IO.puts(
      "qualify-head execution_status=#{result.execution_status} verdict=#{result.verdict || "none"} " <>
        "scored_trials=#{result.execution["scored_trials_completed"]}/#{result.execution["scored_trials_expected"]}"
    )

    if result.summary do
      IO.puts(
        "qualify-head class_rates factual=#{result.summary["class_rates"]["factual"]} " <>
          "instruction=#{result.summary["class_rates"]["instruction"]}"
      )
    end
  end

  defp parse_positive_integer!(value, label) do
    case Integer.parse(value) do
      {integer, ""} when integer > 0 -> integer
      _invalid -> raise "invalid v1.3.1 qualification #{label}"
    end
  end

  defp parse_full_sha!(sha) when is_binary(sha) do
    sha = String.trim(sha)
    if Regex.match?(~r/\A[0-9a-f]{40}\z/, sha), do: sha, else: raise("invalid git SHA")
  end

  defp parse_full_sha!(_sha), do: raise("invalid git SHA")

  defp parse_dirty!("true"), do: true
  defp parse_dirty!("false"), do: false
  defp parse_dirty!(_value), do: raise("invalid dirty-tree provenance")

  defp short_sha(sha) when is_binary(sha), do: String.slice(sha, 0, 12)
  defp short_sha(_sha), do: nil

  defp blank_to_nil(nil), do: nil

  defp blank_to_nil(value) when is_binary(value),
    do: if(String.trim(value) == "", do: nil, else: value)

  defp valid_fixture?(
         %{
           "schema_version" => 1,
           "corpus_id" => "v131-head-qualification-v1",
           "normalization" => "head_qualification_text_v1",
           "trials" => 5,
           "thresholds" => %{"per_row_passes" => 5, "class_rate" => 1.0},
           "rows" => rows
         } = fixture
       ) do
    exact_keys?(
      fixture,
      ~w[schema_version corpus_id normalization trials thresholds rows]
    ) and
      exact_keys?(fixture["thresholds"], ~w[per_row_passes class_rate]) and
      valid_rows?(rows)
  end

  defp valid_fixture?(_fixture), do: false

  defp valid_rows?(rows) when is_list(rows) do
    contracts = Enum.map(rows, &{&1["id"], &1["class"], &1["validator"]})

    contracts == @row_contracts and
      Enum.all?(rows, &valid_row?/1)
  end

  defp valid_rows?(_rows), do: false

  defp valid_row?(row) when is_map(row) do
    exact_keys?(row, @row_keys) and
      nonempty?(row["prompt"]) and
      phrase_groups?(row["required_concepts"], allow_empty?: false) and
      phrase_groups?(row["ordered_required_concepts"], allow_empty?: true) and
      phrase_groups?(row["prohibited_assertions"], allow_empty?: false) and
      examples?(row["positive_examples"], 1) and
      examples?(row["paraphrase_examples"], 2) and
      examples?(row["near_miss_examples"], 1) and
      examples?(row["refusal_examples"], 1)
  end

  defp valid_row?(_row), do: false

  defp phrase_groups?(groups, opts) when is_list(groups) do
    (Keyword.fetch!(opts, :allow_empty?) or groups != []) and
      Enum.all?(groups, fn group ->
        is_list(group) and group != [] and Enum.all?(group, &nonempty?/1)
      end)
  end

  defp phrase_groups?(_groups, _opts), do: false

  defp examples?(values, minimum) when is_list(values),
    do: length(values) >= minimum and Enum.all?(values, &nonempty?/1)

  defp examples?(_values, _minimum), do: false

  defp exact_keys?(map, keys) when is_map(map),
    do: map |> Map.keys() |> Enum.sort() == Enum.sort(keys)

  defp nonempty?(value), do: is_binary(value) and String.trim(value) != ""
end
