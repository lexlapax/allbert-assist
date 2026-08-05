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
end
