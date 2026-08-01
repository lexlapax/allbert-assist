defmodule AllbertAssist.Objectives.CanonicalJSONTest do
  use ExUnit.Case, async: true

  alias AllbertAssist.Objectives.CanonicalJSON
  alias AllbertAssist.Objectives.Fanout.PlanProvenance
  alias AllbertAssist.Objectives.Fanout.Report

  test "encodes maps with lexicographically sorted keys" do
    assert CanonicalJSON.encode(%{"z" => 1, "a" => 2, "middle" => 3}) ==
             ~s({"a":2,"middle":3,"z":1})
  end

  test "equivalent atom-keyed and string-keyed domains have identical bytes" do
    atom_keyed = %{outer: %{answer: 42, enabled: true}}
    string_keyed = %{"outer" => %{"answer" => 42, "enabled" => true}}

    assert CanonicalJSON.encode(atom_keyed) == CanonicalJSON.encode(string_keyed)
  end

  test "stringifies map keys recursively" do
    assert CanonicalJSON.encode(%{1 => %{nested_key: nil}}) ==
             ~s({"1":{"nested_key":null}})
  end

  test "preserves declared list order and compact UTF-8" do
    assert CanonicalJSON.encode([%{z: 1, a: 2}, "β", "α"]) ==
             ~s([{"a":2,"z":1},"β","α"])
  end

  test "keeps the existing v1 plan-provenance bytes" do
    plan = valid_plan()

    assert {:ok, parent_hint} = PlanProvenance.encode_parent_hint(plan)

    assert parent_hint ==
             ~s({"fanout_plan":{"budget":{"child_count":2,"configured_model_calls":40,"configured_output_tokens":24000,"manager_attempts":1,"max_elapsed_ms":300000,"required_model_calls":10,"required_output_tokens":6144,"version":1,"worker_attempts_per_child":2},"deadline_unix_ms":1800000000000,"manager_attempts":1,"manager_profile":"direct_answer_local","manager_profile_sha256":"cccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccc","original_request_sha256":"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa","plan_sha256":"bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb","source":"conversation_manager","version":1}})

    assert {:ok, proposal_event} =
             PlanProvenance.encode_proposal_event(plan, ["child-0", "child-1"])

    assert proposal_event ==
             ~s({"budget":{"child_count":2,"configured_model_calls":40,"configured_output_tokens":24000,"manager_attempts":1,"max_elapsed_ms":300000,"required_model_calls":10,"required_output_tokens":6144,"version":1,"worker_attempts_per_child":2},"child_count":2,"child_ids":["child-0","child-1"],"deadline_unix_ms":1800000000000,"manager_attempts":1,"manager_profile":"direct_answer_local","manager_profile_sha256":"cccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccc","original_request_sha256":"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa","plan_sha256":"bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb","plan_source":"conversation_manager","plan_version":1})
  end

  test "keeps the existing v1 report-binding bytes" do
    snapshot = %{
      version: 1,
      parent_id: "parent-1",
      title: "Unicode ☃",
      original_request: "Analyze alpha then beta",
      status: "completed",
      join_outcome: "success",
      plan: %{},
      children: []
    }

    assert Report.digest(snapshot) ==
             "384fe54644c5ce8b71a45114490f22cd6759fbba2c4f188bede08ceaa112353e"

    assert {:ok, selection_digest} =
             Report.selection_digest("deterministic_fallback", %{
               fallback_reason: "model_disabled",
               layout_version: 1
             })

    assert selection_digest ==
             "7e7331764156bcfba04cc97f303e30c6699913086a561d25ededd43039ecb4bc"
  end

  defp valid_plan do
    %{
      "version" => 1,
      "source" => "conversation_manager",
      "original_request_sha256" => String.duplicate("a", 64),
      "plan_sha256" => String.duplicate("b", 64),
      "manager_profile" => "direct_answer_local",
      "manager_profile_sha256" => String.duplicate("c", 64),
      "manager_attempts" => 1,
      "budget" => %{
        "version" => 1,
        "child_count" => 2,
        "manager_attempts" => 1,
        "worker_attempts_per_child" => 2,
        "configured_model_calls" => 40,
        "required_model_calls" => 10,
        "configured_output_tokens" => 24_000,
        "required_output_tokens" => 6_144,
        "max_elapsed_ms" => 300_000
      },
      "deadline_unix_ms" => 1_800_000_000_000
    }
  end
end
