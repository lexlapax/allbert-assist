defmodule AllbertAssist.DevGates.V131HeadQualification do
  @moduledoc """
  Development-only answering-head qualification for v1.3.1.

  The fixture is an inert, digest-bound corpus. It can select one of six
  allowlisted validator names and supply closed phrase groups, but it cannot
  select code, modules, regular expressions, matching operations, runtime
  permissions, or provider behavior. Provider execution and content-free
  evidence are added by M2 on this same boundary.
  """

  alias AllbertAssist.Objectives.CanonicalJSON

  @fixture_sha256 "1b2946c0441477b06e41bfa3d0e7d235a9ce41ba5257aecda01b4b2c33b39cbf"
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
  @spec validate_fixture(term()) :: :ok | {:error, atom()}
  def validate_fixture(fixture) do
    if valid_fixture?(fixture), do: :ok, else: {:error, :invalid_fixture}
  end

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
