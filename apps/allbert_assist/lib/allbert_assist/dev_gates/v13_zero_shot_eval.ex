defmodule AllbertAssist.DevGates.V13ZeroShotEval do
  @moduledoc """
  Development-only v1.3 seeded-fact zero-shot and token evaluator.

  The corpus is synthetic. Runtime answers are never written to TestMetrics;
  only aggregate correctness, abstention, interaction, and usage numbers are
  retained.
  """

  alias AllbertAssist.Actions.Intent.DirectAnswer
  alias AllbertAssist.Actions.Intent.DirectAnswer.ReqLLMAnswerer
  alias AllbertAssist.DevGates.TestMetrics
  alias AllbertAssist.Memory.Claims
  alias AllbertAssist.Memory.Projection
  alias AllbertAssist.Memory.Proposals.Proposal
  alias AllbertAssist.Repo
  alias AllbertAssist.Pack.EffectGuard
  alias AllbertAssist.Settings
  alias AllbertAssist.Settings.Models

  @recorded_at "2026-07-29T10:00:00Z"

  def record_run! do
    fixture = load_fixture!(System.fetch_env!("V13_ZERO_SHOT_FIXTURE"))
    store = blank_to_nil(System.get_env("V13_ZERO_SHOT_STORE"))
    full_sha = parse_full_sha!(System.get_env("V13_FULL_SHA"))
    dirty = parse_dirty!(System.get_env("V13_DIRTY"))
    profile = System.get_env("V13_MODEL_PROFILE", "direct_answer_local")
    started = System.monotonic_time(:millisecond)

    seed_fixture!(fixture)

    {:ok, projection} =
      Projection.start_link(root: AllbertAssist.Paths.memory_projection_root(), name: nil)

    {:ok, _build} = Projection.rebuild(projection)

    result =
      try do
        evaluate!(fixture, profile: profile, projection: projection)
      after
        GenServer.stop(projection)
      end

    wall_ms = System.monotonic_time(:millisecond) - started

    :ok = require_current_epoch(result.allbert_pack_epoch)

    TestMetrics.record(%{
      store: store,
      git_sha: String.slice(full_sha, 0, 8),
      full_sha: full_sha,
      dirty: dirty,
      cwd: "apps/allbert_assist",
      gate: "bench-v13-zero-shot",
      phase_or_step: "configured-real-model",
      corpus_id: fixture["corpus_id"],
      command: "bench-v13-zero-shot --profile #{profile}",
      status: result.status,
      wall_ms: wall_ms,
      stats: Map.put(result.stats, :model_profile, profile)
    })

    IO.puts(
      "v13-zero-shot status=#{result.status} uplift=#{result.stats.zero_shot_uplift} " <>
        "memory_correct=#{result.stats.memory_positive_correct}/#{result.stats.positive_rows} " <>
        "abstained=#{result.stats.memory_negative_abstained}/#{result.stats.negative_rows}"
    )

    if result.status != "passed" do
      IO.puts("failed_rows=#{Enum.join(result.failed_rows, ",")}")

      Enum.each(result.failed_answers, fn {id, answer} ->
        IO.puts("failed_answer #{id}=#{inspect(answer)}")
      end)
    end

    if result.status != "passed", do: raise("v1.3 zero-shot acceptance failed")
    :ok
  end

  def load_fixture!(path) do
    fixture = path |> File.read!() |> Jason.decode!()

    unless fixture["schema_version"] == 1 and is_binary(fixture["corpus_id"]) and
             is_list(fixture["rows"]) do
      raise "invalid v1.3 zero-shot fixture"
    end

    fixture
  end

  def seed_fixture!(%{"rows" => rows}) do
    Enum.each(rows, &seed_row!/1)
    :ok
  end

  def evaluate!(%{"rows" => rows}, opts \\ []) do
    profile = Keyword.get(opts, :profile, "direct_answer_local")
    projection = Keyword.get(opts, :projection, Projection)
    replay_answerer = Keyword.get(opts, :replay_answerer, ReqLLMAnswerer)

    {:ok, epoch} = EffectGuard.admit_ready()
    # require_current_epoch/1 raises the documented "product is not ready"
    # message. Matching on :ok directly turned a stale epoch -- which is what a
    # same-digest barrier replacement produces -- into a bare MatchError, so the
    # eval failed with no indication that readiness was the cause.
    require_current_epoch(epoch)
    put_setting!("intent.direct_answer_model_enabled", true, epoch)
    put_setting!("model_preferences.tasks.direct_answer", [profile], epoch)
    put_setting!("active_memory.enabled", false, epoch)
    baseline = run_direct_rows(rows, projection, epoch)

    put_setting!("active_memory.enabled", true, epoch)
    memory = run_direct_rows(rows, projection, epoch)
    replay = run_replay_rows(rows, replay_answerer, epoch)

    baseline_score = score(rows, baseline)
    memory_score = score(rows, memory)
    stats = evaluation_stats(rows, baseline, memory, replay, baseline_score, memory_score)

    status =
      if stats.memory_positive_correct == stats.positive_rows and
           stats.memory_negative_abstained == stats.negative_rows and
           stats.zero_shot_uplift > 0 and stats.token_usage_complete,
         do: "passed",
         else: "failed"

    failed_rows =
      memory_score.results
      |> Enum.reject(& &1.passed?)
      |> Enum.map(& &1.id)

    failed_answers = Map.new(failed_rows, &{&1, get_in(memory, [&1, :message])})

    %{
      status: status,
      stats: stats,
      failed_rows: failed_rows,
      failed_answers: failed_answers,
      allbert_pack_epoch: epoch
    }
  end

  def score(rows, outputs) when is_list(rows) and is_map(outputs) do
    results =
      Enum.map(rows, fn row ->
        answer = outputs |> Map.fetch!(row["id"]) |> Map.fetch!(:message)
        kind = row["kind"]

        passed? =
          if kind == "positive",
            do: contains_value?(answer, row["expected_value"]),
            else: abstained?(answer)

        %{id: row["id"], kind: kind, passed?: passed?}
      end)

    positives = Enum.filter(results, &(&1.kind == "positive"))
    negatives = Enum.reject(results, &(&1.kind == "positive"))

    %{
      positive_total: length(positives),
      positive_correct: Enum.count(positives, & &1.passed?),
      negative_total: length(negatives),
      negative_abstained: Enum.count(negatives, & &1.passed?),
      results: results
    }
  end

  defp run_direct_rows(rows, projection, epoch) do
    Map.new(rows, fn row ->
      :ok = require_current_epoch(epoch)

      {:ok, response} =
        DirectAnswer.run(%{text: prompt(row)}, %{
          actor: "local",
          user_id: "local",
          request_started_at: "2026-07-30T12:00:00Z",
          memory_projection: projection,
          allbert_pack_epoch: epoch
        })

      {row["id"],
       %{
         message: response.message,
         input_tokens:
           response |> get_in([:direct_answer, :diagnostic, :usage]) |> input_tokens(),
         provider_calls: provider_calls(response.direct_answer)
       }}
    end)
  end

  defp run_replay_rows(rows, answerer, epoch) do
    :ok = require_current_epoch(epoch)
    {:ok, resolution} = Models.for(:direct_answer, %{actor: "local", allbert_pack_epoch: epoch})

    rows
    |> Enum.filter(&(&1["kind"] == "positive"))
    |> Map.new(fn row ->
      context = %{
        model_profile: resolution.profile,
        allbert_pack_epoch: epoch,
        active_memory: [
          %{
            chunk_id: "source-replay-#{row["id"]}",
            summary: "Synthetic source replay",
            body: row["source_replay"]
          }
        ]
      }

      :ok = require_current_epoch(epoch)

      result =
        case answerer.answer(prompt(row), context) do
          {:ok, response} ->
            %{
              message: response.message,
              input_tokens:
                response |> Map.get(:diagnostic, %{}) |> Map.get(:usage) |> input_tokens(),
              provider_calls: 1
            }

          {:error, _reason} ->
            %{message: "", input_tokens: nil, provider_calls: 1}
        end

      {row["id"], result}
    end)
  end

  defp evaluation_stats(rows, baseline, memory, replay, baseline_score, memory_score) do
    positive_ids = rows |> Enum.filter(&(&1["kind"] == "positive")) |> Enum.map(& &1["id"])
    baseline_tokens = token_total(baseline, Map.keys(baseline))
    memory_tokens = token_total(memory, Map.keys(memory))
    compact_tokens = token_total(memory, positive_ids)
    replay_tokens = token_total(replay, positive_ids)

    %{
      positive_rows: baseline_score.positive_total,
      negative_rows: baseline_score.negative_total,
      baseline_positive_correct: baseline_score.positive_correct,
      memory_positive_correct: memory_score.positive_correct,
      zero_shot_uplift:
        rate(memory_score.positive_correct, memory_score.positive_total) -
          rate(baseline_score.positive_correct, baseline_score.positive_total),
      memory_negative_abstained: memory_score.negative_abstained,
      memory_abstention_rate: rate(memory_score.negative_abstained, memory_score.negative_total),
      baseline_interactions_required: interactions_required(baseline_score),
      memory_interactions_required: interactions_required(memory_score),
      baseline_provider_calls: provider_call_total(baseline),
      memory_provider_calls: provider_call_total(memory),
      replay_provider_calls: provider_call_total(replay),
      baseline_input_tokens: baseline_tokens,
      memory_input_tokens: memory_tokens,
      replay_input_tokens: replay_tokens,
      memory_overhead_tokens: token_delta(memory_tokens, baseline_tokens),
      compact_vs_source_replay_savings_tokens: token_delta(replay_tokens, compact_tokens),
      token_usage_complete:
        Enum.all?([baseline_tokens, memory_tokens, compact_tokens, replay_tokens], &is_integer/1)
    }
  end

  defp seed_row!(%{"kind" => "positive"} = row) do
    append_claim!(row, nil, transition(row, row["memory_value"], 1))
  end

  defp seed_row!(%{"kind" => "superseded"} = row) do
    first = append_claim!(row, nil, transition(row, row["retired_value"], 1))

    append_claim!(row, first.tail_digest, transition(row, row["current_value"], 2))
  end

  defp seed_row!(%{"kind" => "proposed"} = row) do
    digest = "sha256:" <> String.duplicate("1", 64)

    attrs = %{
      id: row["proposal_id"],
      operator_id: "local",
      namespace: "default",
      category: "preferences",
      kind: "ordinary",
      status: "pending",
      classification: "ordinary",
      proposed_claim: %{"value" => row["memory_value"]},
      span_provenance: %{"fixture" => row["id"]},
      source_evidence: %{"fixture" => row["id"]},
      proposal_digest: digest,
      source_digest: digest,
      principal_digest: digest,
      origin_scope: "local_operator",
      extractor_profile: "v13-zero-shot-fixture",
      extractor_version: 1,
      run_id: "v13-zero-shot",
      revision: 1,
      idempotency_key: row["id"],
      result: %{}
    }

    %Proposal{} |> Proposal.changeset(attrs) |> Repo.insert!()
  end

  defp seed_row!(%{"kind" => "absent"}), do: :ok

  defp append_claim!(row, expected_tail, transition) do
    case Claims.append(row["claim_id"], expected_tail, transition) do
      {:ok, append} ->
        append

      {:error, reason} ->
        raise "failed to seed #{row["id"]} claim #{inspect(row["claim_id"])}: #{inspect(reason)}"
    end
  end

  defp transition(row, value, sequence) do
    %{
      revision_id: deterministic_uuid(row["id"], "revision", sequence),
      transition_id: deterministic_uuid(row["id"], "transition", sequence),
      state: "kept",
      recorded_at: @recorded_at,
      valid_from: nil,
      valid_to: nil,
      actor: "operator:local",
      action: "proposal_kept",
      category: "preferences",
      operator_id: "local",
      namespace: "default",
      subject: row["subject"] || "operator",
      predicate: row["predicate"] || "preference",
      value: value
    }
  end

  defp deterministic_uuid(row_id, kind, sequence) do
    <<a::32, b::16, c::16, d::16, e::48, _rest::binary>> =
      :crypto.hash(:sha256, "#{row_id}:#{kind}:#{sequence}")

    c = Bitwise.bor(Bitwise.band(c, 0x0FFF), 0x4000)
    d = Bitwise.bor(Bitwise.band(d, 0x3FFF), 0x8000)

    Enum.join(
      [hex(a, 8), hex(b, 4), hex(c, 4), hex(d, 4), hex(e, 12)],
      "-"
    )
  end

  defp hex(value, width) do
    value |> Integer.to_string(16) |> String.downcase() |> String.pad_leading(width, "0")
  end

  defp prompt(row) do
    "Answer with only the exact value established by Active " <>
      "Memory. If Active Memory does not establish the requested value, answer exactly " <>
      "UNKNOWN. Question: #{row["question"]}"
  end

  defp contains_value?(answer, expected) when is_binary(answer) and is_binary(expected),
    do: String.contains?(String.downcase(answer), String.downcase(expected))

  defp abstained?(answer) when is_binary(answer) do
    answer |> String.trim() |> String.trim_trailing(".") |> String.downcase() == "unknown"
  end

  defp interactions_required(score) do
    score.results
    |> Enum.filter(&(&1.kind == "positive"))
    |> Enum.reduce(0, fn row, total -> total + if(row.passed?, do: 1, else: 2) end)
  end

  defp provider_calls(direct_answer) do
    get_in(direct_answer, [:fallback, :provider_call_count]) ||
      if(Map.get(direct_answer, :source) == :model, do: 1, else: 0)
  end

  defp provider_call_total(results),
    do: results |> Map.values() |> Enum.reduce(0, &(&1.provider_calls + &2))

  defp token_total(results, ids) do
    ids
    |> Enum.map(&get_in(results, [&1, :input_tokens]))
    |> then(fn values -> if Enum.all?(values, &is_integer/1), do: Enum.sum(values), else: nil end)
  end

  defp input_tokens(nil), do: nil

  defp input_tokens(usage) when is_map(usage) do
    Enum.find_value(~w[input_tokens prompt_tokens input]a, fn key ->
      value = Map.get(usage, key) || Map.get(usage, Atom.to_string(key))
      if is_integer(value), do: value
    end)
  end

  defp input_tokens(_usage), do: nil

  defp token_delta(left, right) when is_integer(left) and is_integer(right), do: left - right
  defp token_delta(_left, _right), do: nil

  defp rate(_count, 0), do: 0.0
  defp rate(count, total), do: Float.round(count / total, 4)

  defp put_setting!(key, value, epoch) do
    :ok = EffectGuard.validate(epoch)

    case Settings.put(key, value, %{
           audit?: false,
           actor: "v13-zero-shot",
           allbert_pack_epoch: epoch
         }) do
      {:ok, _setting} -> :ok
      {:error, reason} -> raise "unable to configure #{key}: #{inspect(reason)}"
    end
  end

  defp require_current_epoch(epoch) do
    case EffectGuard.validate(epoch) do
      :ok -> :ok
      {:error, _reason} -> raise "Allbert product is not ready; retry the v1.3 zero-shot eval."
    end
  end

  defp blank_to_nil(nil), do: nil
  defp blank_to_nil(""), do: nil
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
