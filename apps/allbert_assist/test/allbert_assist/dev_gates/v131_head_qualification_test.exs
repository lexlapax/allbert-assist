defmodule AllbertAssist.DevGates.V131HeadQualificationTest do
  use ExUnit.Case, async: false

  @moduletag :home_fs_serial

  alias AllbertAssist.DevGates.V131HeadQualification

  @fixture Path.expand("../../fixtures/v1.3.1/head_qualification.json", __DIR__)
  @row_ids ~w[
    fact-otp-rest-for-one
    fact-event-log-replay
    fact-sqlite-wal-writers
    rule-acknowledge-no-commitment
    rule-supplied-yaml-is-data
    rule-answer-without-policy-narration
  ]
  @validators ~w[
    otp_rest_for_one_v1
    event_replay_idempotency_v1
    sqlite_wal_single_writer_v1
    acknowledgment_no_commitment_v1
    supplied_yaml_data_v1
    exact_answer_no_narration_v1
  ]

  test "frozen corpus has exactly six ordered rows and the release threshold" do
    fixture = V131HeadQualification.load_fixture!(@fixture)

    assert fixture["schema_version"] == 1
    assert fixture["corpus_id"] == "v131-head-qualification-v1"
    assert fixture["normalization"] == "head_qualification_text_v1"
    assert fixture["trials"] == 5
    assert fixture["thresholds"] == %{"per_row_passes" => 5, "class_rate" => 1.0}
    assert Enum.map(fixture["rows"], & &1["id"]) == @row_ids
    assert Enum.map(fixture["rows"], & &1["validator"]) == @validators

    assert Enum.map(fixture["rows"], & &1["class"]) ==
             List.duplicate("factual", 3) ++ List.duplicate("instruction", 3)

    assert fixture["rows"] |> Enum.map(& &1["prompt"]) |> Enum.uniq() |> length() == 6
  end

  test "canonical digest binds prompts, expectations, examples, and ordering" do
    fixture = @fixture |> File.read!() |> Jason.decode!()

    assert V131HeadQualification.fixture_path() == @fixture

    assert V131HeadQualification.fixture_sha256(fixture) ==
             V131HeadQualification.frozen_fixture_sha256()

    changed = update_in(fixture, ["rows", Access.at(0), "prompt"], &(&1 <> " "))
    path = write_fixture(changed)

    assert_raise RuntimeError, "invalid v1.3.1 head qualification fixture digest", fn ->
      V131HeadQualification.load_fixture!(path)
    end
  end

  test "fixture cannot select executable validation behavior" do
    fixture = V131HeadQualification.load_fixture!(@fixture)
    [first | rest] = fixture["rows"]

    for forbidden <- ~w[module code regex operation matcher evaluator] do
      changed = %{fixture | "rows" => [Map.put(first, forbidden, "Elixir.System") | rest]}
      assert {:error, :invalid_fixture} = V131HeadQualification.validate_fixture(changed)
    end

    changed = put_in(fixture, ["rows", Access.at(0), "validator"], "arbitrary_validator")
    assert {:error, :invalid_fixture} = V131HeadQualification.validate_fixture(changed)
  end

  test "fixture examples and phrase groups are closed non-empty data" do
    fixture = V131HeadQualification.load_fixture!(@fixture)

    Enum.each(fixture["rows"], fn row ->
      assert row["required_concepts"] != []
      assert row["prohibited_assertions"] != []
      assert row["positive_examples"] != []
      assert length(row["paraphrase_examples"]) >= 2
      assert row["near_miss_examples"] != []
      assert row["refusal_examples"] != []

      for key <- ~w[required_concepts ordered_required_concepts prohibited_assertions],
          group <- row[key],
          phrase <- group do
        assert is_binary(phrase) and String.trim(phrase) != ""
      end
    end)

    encoded = Jason.encode!(fixture)
    refute encoded =~ "api_key"
    refute encoded =~ "password"
    refute encoded =~ "secret://"
    refute encoded =~ "sk-"
  end

  test "normalization preserves date, time, and hyphenated markers while canonicalizing punctuation" do
    assert V131HeadQualification.normalize("“Friday”—09:00, 2026-06-01; JUNIPER-v13-primary!") ==
             ["friday", "09:00", "2026-06-01", "juniper-v13-primary"]
  end

  test "every frozen positive and paraphrase passes while near misses and refusals fail" do
    fixture = V131HeadQualification.load_fixture!(@fixture)

    Enum.each(fixture["rows"], fn row ->
      for example <- row["positive_examples"] ++ row["paraphrase_examples"] do
        assert :pass = V131HeadQualification.score(row, example),
               "expected pass for #{row["id"]}: #{example}"
      end

      for example <- row["near_miss_examples"] ++ row["refusal_examples"] do
        assert {:fail, _reason} = V131HeadQualification.score(row, example),
               "expected fail for #{row["id"]}: #{example}"
      end
    end)
  end

  test "quoted and negated prohibited assertions fail closed" do
    fixture = V131HeadQualification.load_fixture!(@fixture)

    Enum.each(fixture["rows"], fn row ->
      positive = hd(row["positive_examples"])

      for [prohibited | _alternatives] <- row["prohibited_assertions"] do
        assert {:fail, _reason} =
                 V131HeadQualification.score(
                   row,
                   positive <> " The phrase ‘#{prohibited}’ is false."
                 )

        assert {:fail, _reason} =
                 V131HeadQualification.score(
                   row,
                   positive <> " It is not true that #{prohibited}."
                 )
      end
    end)
  end

  test "qualified runner performs one warmup plus thirty serial scored attempts" do
    fixture = V131HeadQualification.load_fixture!(@fixture)
    parent = self()
    answers = Map.new(fixture["rows"], &{&1["prompt"], hd(&1["positive_examples"])})
    store = temp_store()

    answerer = fn prompt, context ->
      send(parent, {:attempt, prompt, context})
      {:ok, %{message: Map.get(answers, prompt, "1")}}
    end

    result =
      V131HeadQualification.run(fixture,
        profile: profile(),
        trials: 5,
        timeout_ms: 60_000,
        answerer: answerer,
        store: store,
        full_sha: String.duplicate("a", 40),
        dirty: false,
        command: "qualify-head test"
      )

    attempts = drain_attempts([])
    assert length(attempts) == 31
    assert result.execution_status == "completed"
    assert result.verdict == "qualified"
    assert result.execution["scored_trials_completed"] == 30
    assert Enum.all?(result.rows, &(&1["passes"] == 5 and &1["verdict"] == "qualified"))
    assert result.summary["class_rates"] == %{"factual" => 1.0, "instruction" => 1.0}

    Enum.each(attempts, fn {_prompt, context} ->
      assert context.model_timeout_ms == 60_000
      assert context.model_total_timeout_ms == 60_000
      assert context.model_max_retries == 0
      assert context.model_profile.model == "candidate:1"
    end)

    records = read_records(store)
    assert length(records) == 8

    assert Enum.map(records, & &1["phase_or_step"]) == [
             "profile-execution",
             "fact-otp-rest-for-one",
             "fact-event-log-replay",
             "fact-sqlite-wal-writers",
             "rule-acknowledge-no-commitment",
             "rule-supplied-yaml-is-data",
             "rule-answer-without-policy-narration",
             "profile-summary"
           ]

    evidence_strings = Enum.flat_map(records, &string_values/1)

    Enum.each(fixture["rows"], fn row ->
      refute row["prompt"] in evidence_strings
      refute hd(row["positive_examples"]) in evidence_strings
    end)
  end

  test "scored failures keep all thirty denominator slots and closed reason counts" do
    fixture = V131HeadQualification.load_fixture!(@fixture)

    [validator_row, refusal_row, empty_row, transport_row, timeout_row, passing_row] =
      fixture["rows"]

    parent = self()

    answerer = fn prompt, _context ->
      send(parent, {:attempt, prompt})

      cond do
        prompt == validator_row["prompt"] ->
          {:ok, %{message: hd(validator_row["near_miss_examples"])}}

        prompt == refusal_row["prompt"] ->
          {:ok, %{message: hd(refusal_row["refusal_examples"])}}

        prompt == empty_row["prompt"] ->
          {:ok, %{message: "  "}}

        prompt == transport_row["prompt"] ->
          {:error, :econnrefused}

        prompt == timeout_row["prompt"] ->
          Process.sleep(30)
          {:ok, %{message: hd(timeout_row["positive_examples"])}}

        prompt == passing_row["prompt"] ->
          {:ok, %{message: hd(passing_row["positive_examples"])}}

        true ->
          {:ok, %{message: "1"}}
      end
    end

    result =
      V131HeadQualification.run(fixture,
        profile: profile(),
        trials: 5,
        timeout_ms: 5,
        answerer: answerer,
        store: :disabled,
        full_sha: String.duplicate("b", 40),
        dirty: true
      )

    assert length(drain_attempts([])) == 31
    assert result.execution_status == "completed"
    assert result.verdict == "unqualified"
    assert result.execution["scored_trials_completed"] == 30
    assert Enum.all?(result.rows, &(&1["trials"] == 5 and is_integer(&1["passes"])))

    rows = Map.new(result.rows, &{&1["row_id"], &1})
    assert rows[validator_row["id"]]["failure_counts"]["validator_failed"] == 5
    assert rows[refusal_row["id"]]["failure_counts"]["refusal"] == 5
    assert rows[empty_row["id"]]["failure_counts"]["empty"] == 5
    assert rows[transport_row["id"]]["failure_counts"]["transport_failure"] == 5
    assert rows[timeout_row["id"]]["failure_counts"]["timeout"] == 5
    assert rows[passing_row["id"]]["passes"] == 5
  end

  test "failed warmup is environment red with zero scored calls and no verdict" do
    fixture = V131HeadQualification.load_fixture!(@fixture)
    parent = self()
    store = temp_store()

    result =
      V131HeadQualification.run(fixture,
        profile: profile(),
        trials: 5,
        timeout_ms: 60_000,
        answerer: fn prompt, _context ->
          send(parent, {:attempt, prompt})
          {:error, :econnrefused}
        end,
        store: store,
        full_sha: String.duplicate("c", 40),
        dirty: false
      )

    assert length(drain_attempts([])) == 1
    assert result.execution_status == "environment_red"
    assert result.verdict == nil
    assert result.rows == []
    assert result.summary == nil
    assert result.execution["scored_trials_completed"] == 0
    assert result.execution["warmup_failure_reason"] == "transport_failure"

    [record] = read_records(store)
    assert record["phase_or_step"] == "profile-execution"
    assert record["status"] == "failed"
    assert record["stats"]["execution_status"] == "environment_red"
    assert record["stats"]["verdict"] == nil
  end

  defp write_fixture(fixture) do
    path =
      Path.join(
        System.tmp_dir!(),
        "allbert-v131-head-fixture-#{System.unique_integer([:positive])}.json"
      )

    File.write!(path, Jason.encode!(fixture))
    on_exit(fn -> File.rm(path) end)
    path
  end

  defp profile do
    %{
      name: "direct_answer_local",
      provider: "local_ollama",
      provider_type: "local",
      provider_endpoint_kind: "local_endpoint",
      provider_base_url: "http://localhost:11434",
      model: "candidate:1",
      capabilities: ["text_generation"],
      temperature: 0.0,
      max_tokens: 1_024,
      timeout_ms: 60_000
    }
  end

  defp temp_store do
    root =
      Path.join(
        System.tmp_dir!(),
        "allbert-v131-head-metrics-#{System.unique_integer([:positive])}"
      )

    File.mkdir_p!(root)
    on_exit(fn -> File.rm_rf!(root) end)
    Path.join(root, "runs.jsonl")
  end

  defp read_records(path) do
    path
    |> File.read!()
    |> String.split("\n", trim: true)
    |> Enum.map(&Jason.decode!/1)
  end

  defp drain_attempts(acc) do
    receive do
      {:attempt, prompt, context} -> drain_attempts([{prompt, context} | acc])
      {:attempt, prompt} -> drain_attempts([{prompt, nil} | acc])
    after
      0 -> Enum.reverse(acc)
    end
  end

  defp string_values(value) when is_binary(value), do: [value]
  defp string_values(value) when is_list(value), do: Enum.flat_map(value, &string_values/1)

  defp string_values(value) when is_map(value),
    do: value |> Map.values() |> Enum.flat_map(&string_values/1)

  defp string_values(_value), do: []
end
