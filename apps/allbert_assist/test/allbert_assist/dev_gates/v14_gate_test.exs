defmodule AllbertAssist.DevGates.V14GateTest do
  use ExUnit.Case, async: false
  @moduletag :global_process_serial

  alias AllbertAssist.DevGates.ScopeSelector
  alias Mix.Tasks.Allbert.Test, as: AllbertTestTask

  test "release.v14 freezes release.v1, v1.3, v1.3.1, and v1.3.2 and its closed thirteen-step delta" do
    proof = AllbertTestTask.release_v14_topology_proof()
    definitions = proof["definitions"]["release.v14"]

    assert proof["status"] == "passed"
    assert Enum.all?(proof["checks"], fn {_name, passed?} -> passed? end)

    assert proof["release_v1_frozen_sha256"] == proof["release_v1_observed_sha256"]
    assert proof["release_v13_frozen_sha256"] == proof["release_v13_observed_sha256"]
    assert proof["release_v131_frozen_sha256"] == proof["release_v131_observed_sha256"]
    assert proof["release_v132_frozen_sha256"] == proof["release_v132_observed_sha256"]

    assert length(proof["definitions"]["release.v1"]) == 10
    assert length(proof["definitions"]["release.v13"]) == 32
    assert length(proof["definitions"]["release.v131"]) == 8
    assert length(proof["definitions"]["release.v132"]) == 8
    assert length(definitions) == 13

    # v1.4 M16 added v14_license_drift. The reviewed catalog binds mix.lock by
    # digest, and no gate surviving this release checked it: v121_license_drift
    # is reachable only through release.v121 and release.v13.
    assert "v14_license_drift" in Enum.map(definitions, & &1["id"])

    assert Enum.map(definitions, & &1["id"]) == proof["release_v14_step_ids"]

    assert proof["release_v14_step_ids"] == [
             "v14_kernel_owners",
             "v14_composition_owners",
             "v14_action_roster_owners",
             "v14_ledger_owners",
             "v14_settings_composition_owner",
             "v14_notes_files_owner",
             "v14_telegram_owner",
             "v14_email_owner",
             "v14_release_asset_owners",
             "v14_topology_owner",
             "v14_license_drift",
             "v14_lane_inventory",
             "v14_manifest_inventory"
           ]

    test_targets =
      for %{"args" => ["test" | targets]} <- definitions,
          target <- targets,
          do: target

    assert test_targets == proof["release_v14_target_allowlist"]

    assert Enum.all?(definitions, &(&1["cwd"] == "root" and &1["executable"] == "mix"))
  end

  test "release.v14 target allowlist covers every declared step owner" do
    proof = AllbertTestTask.release_v14_topology_proof()
    definitions = proof["definitions"]["release.v14"]

    assert proof["release_v14_target_allowlist"] == [
             "apps/allbert_kernel/test/allbert_assist/kernel/contract_test.exs",
             "apps/allbert_kernel/test/allbert_assist/kernel/contract_owner_test.exs",
             "apps/allbert_kernel/test/allbert_assist/security/permission_gate_test.exs",
             "apps/allbert_kernel/test/allbert_assist/security/security_central_test.exs",
             "apps/allbert_kernel/test/allbert_assist/runtime/response_test.exs",
             "apps/allbert_kernel/test/allbert_assist/pack/registry_test.exs",
             "apps/allbert_kernel/test/allbert_assist/pack/canonical_test.exs",
             "apps/allbert_kernel/test/allbert_assist/pack/projection_test.exs",
             "apps/allbert_kernel/test/allbert_assist/pack/descriptor_test.exs",
             "apps/allbert_kernel/test/allbert_assist/pack/otp_metadata_test.exs",
             "apps/allbert_composition/test/allbert_assist/pack/application_boundary_test.exs",
             "apps/allbert_composition/test/allbert_assist/pack/candidate_builder_test.exs",
             "apps/allbert_composition/test/allbert_assist/pack/candidate_builder/metadata_rows_test.exs",
             "apps/allbert_composition/test/allbert_assist/pack/composition_coordinator_test.exs",
             "apps/allbert_composition/test/allbert_assist/pack/product_cli_licenses_test.exs",
             "apps/allbert_assist/test/allbert_assist/actions/param_contract_test.exs",
             "apps/allbert_assist/test/allbert_assist/actions/registry_test.exs",
             "apps/allbert_assist/test/allbert_assist/actions/runner_test.exs",
             "apps/allbert_assist/test/allbert_assist/actions/security_actions_test.exs",
             "apps/allbert_assist/test/allbert_assist/dev_gates/v14_m0_registry_ledger_test.exs",
             "apps/allbert_assist/test/allbert_assist/dev_gates/v14_m1_registry_shadow_parity_test.exs",
             "apps/allbert_assist/test/allbert_assist/dev_gates/v14_m4_semantics_inventory_test.exs",
             "apps/allbert_assist/test/allbert_assist/dev_gates/v14_m6_permission_migration_test.exs",
             "apps/allbert_assist/test/allbert_assist/dev_gates/v14_m71_closure_ledger_test.exs",
             "apps/allbert_assist/test/allbert_assist/settings_test.exs",
             "apps/allbert_assist/test/allbert_assist/pack/residual_test.exs",
             "apps/allbert_notes_files/test/allbert_notes_files/cli_test.exs",
             "apps/allbert_notes_files/test/allbert_notes_files/plugin_test.exs",
             "apps/allbert_notes_files/test/allbert_notes_files/actions_test.exs",
             "apps/allbert_notes_files/test/allbert_notes_files/intent_descriptors_test.exs",
             "apps/allbert_telegram/test/edit_test.exs",
             "apps/allbert_telegram/test/renderer_test.exs",
             "apps/allbert_email/test/renderer_test.exs",
             "apps/allbert_assist/test/allbert_assist/release/licenses_final_artifact_test.exs",
             "apps/allbert_assist/test/allbert_assist/licenses_test.exs",
             "apps/allbert_assist/test/mix/tasks/allbert_licenses_test.exs",
             "apps/allbert_assist/test/mix/tasks/allbert_test_task_test.exs",
             "apps/allbert_assist/test/allbert_assist/dev_gates/scope_test.exs",
             "apps/allbert_assist/test/allbert_assist/dev_gates/v14_gate_test.exs"
           ]

    # steps 6/7/8 (notes_files, telegram, email) stay single-owner so a
    # multi-owner fallback to repo root can never merge three pack
    # test_helper.exs files into one VM.
    single_owner_step_ids = ~w[v14_notes_files_owner v14_telegram_owner v14_email_owner]

    for step <- definitions, step["id"] in single_owner_step_ids do
      assert {"test", targets} = List.pop_at(step["args"], 0)

      owners_matched =
        targets
        |> Enum.map(&Path.split/1)
        |> Enum.map(&Enum.take(&1, 2))
        |> Enum.uniq()

      assert length(owners_matched) == 1
    end

    root_relative = Path.expand("../../../../..", __DIR__)

    for target <- proof["release_v14_target_allowlist"] do
      assert File.regular?(Path.join(root_relative, target)),
             "release.v14 target missing: #{target}"
    end
  end

  test "release.v14 has no docs step and cannot silently acquire one" do
    proof = AllbertTestTask.release_v14_topology_proof()
    definitions = proof["definitions"]["release.v14"]

    refute Enum.any?(definitions, &(&1["args"] == ["allbert.test", "docs"]))

    task_source =
      Path.expand("../../../lib/mix/tasks/allbert.test.ex", __DIR__)
      |> File.read!()

    refute task_source =~
             "defp allowed_v14_step?(%{\"args\" => [\"allbert.test\", \"docs\"]})"
  end

  test "release.v14 refuses every forbidden invocation" do
    proof = AllbertTestTask.release_v14_topology_proof()
    definitions = proof["definitions"]["release.v14"]

    refute Enum.any?(definitions, fn step ->
             step["args"] in [
               ["test"],
               ["allbert.test", "release"],
               ["allbert.test", "release.v1"],
               ["allbert.test", "release.v11"],
               ["allbert.test", "release.v12"],
               ["allbert.test", "release.v121"],
               ["allbert.test", "release.v13"],
               ["allbert.test", "release.v131"],
               ["allbert.test", "release.v132"],
               ["commit"],
               ["prepush"],
               ["allbert.test", "compatibility"],
               ["allbert.test", "qualify-head"],
               ["precommit"]
             ]
           end)
  end

  test "release.v14 does not appear in the frozen 42-key point-release map" do
    definitions = AllbertTestTask.all_release_step_definitions()
    refute Map.has_key?(definitions, "release.v14")
    assert map_size(definitions) == 42
  end

  test "release.v14 closed targets exist, are manifested, and rejoin aggregate lanes" do
    proof = AllbertTestTask.release_v14_structure_proof()

    assert proof["status"] == "passed"
    assert proof["targets_status"] == "passed"
    assert length(proof["target_checks"]) == 39

    assert Enum.all?(proof["target_checks"], fn target ->
             target["exists"] and target["manifest"] and target["aggregate_covered"] and
               target["owner"] in [
                 "core",
                 "web",
                 "kernel",
                 "composition",
                 "notes_files",
                 "telegram",
                 "email"
               ] and
               is_binary(target["primary_lane"])
           end)

    owners_present =
      proof["target_checks"] |> Enum.map(& &1["owner"]) |> Enum.uniq() |> Enum.sort()

    assert owners_present == ~w[composition core email kernel notes_files telegram]
  end

  test "the aggregate covers every owner the v1.4 M15 gap identified" do
    covered_owners = ~w[kernel composition notes_files telegram email]a

    for owner <- covered_owners do
      records =
        AllbertTestTask.inventory_records()
        |> Enum.filter(&(&1.owner == owner))

      assert records != [], "no inventory records for owner #{owner}"

      assert Enum.all?(records, &(&1.primary_lane != nil)),
             "owner #{owner} has a record with no reconciled primary lane"
    end
  end

  test "the affected-component selector widens to the aggregate for a shared-spine change" do
    result =
      ScopeSelector.classify_paths([
        "apps/allbert_assist/lib/allbert_assist/settings/schema.ex"
      ])

    assert result["aggregate_required"]
    assert result["required_gates"] == ["preflight", "release.v14"]
  end

  test "the affected-component selector widens to the aggregate for an unknown path" do
    result = ScopeSelector.classify_paths(["unexpected/new-root.txt"])

    assert result["aggregate_required"]
    assert result["required_gates"] == ["preflight", "release.v14"]
    assert result["diagnostics"] == ["unknown paths fail closed: unexpected/new-root.txt"]
  end

  test "browser, research, and tui no longer fall to the fail-closed unknown branch" do
    for {path, owner} <- [
          {"apps/allbert_browser/lib/allbert_browser/pack.ex", "browser"},
          {"apps/allbert_research/lib/allbert_research/pack.ex", "research"},
          {"apps/allbert_tui/lib/allbert_tui/pack.ex", "tui"}
        ] do
      result = ScopeSelector.classify_paths([path])

      assert result["matched_rules"] != [],
             "#{path} still falls to the fail-closed unknown branch"

      assert result["owners"] == [owner]
      assert result["diagnostics"] == []
    end
  end
end
