defmodule AllbertAssist.DevGates.V14M0RegistryLedgerTest do
  use ExUnit.Case, async: false

  @moduletag :global_process_serial

  alias AllbertAssist.DevGates.V14M0RegistryLedger

  @fixture Path.expand("../../fixtures/v1.4/m0_registry_ledger.json", __DIR__)

  test "live registry ledger has a stable versioned canonical shape" do
    snapshot = V14M0RegistryLedger.snapshot()

    assert snapshot["schema_version"] == 1
    assert snapshot["normalization"] == "v14_m0_registry_ledger_v1"
    assert is_map(snapshot["payload"])
    assert V14M0RegistryLedger.digest(snapshot["payload"]) =~ ~r/^[0-9a-f]{64}$/
  end

  test "live payload retains element-level rows for every composed registry" do
    payload = V14M0RegistryLedger.snapshot()["payload"]

    assert [%{"index" => 1, "module" => _, "name" => _} | _] =
             payload["actions"]["rows"]

    assert [%{"index" => 1, "id" => _, "schema" => schema} | _] =
             payload["settings"]["fragments"]

    assert is_map(schema) and map_size(schema) > 0
    assert [%{"index" => 1, "plugin_id" => _} | _] = payload["plugins"]["entries"]
    assert [%{"index" => 1, "app_id" => _} | _] = payload["apps"]["entries"]
    assert is_list(payload["extensions"]["actions"])
    assert is_list(payload["extensions"]["settings_schema"])
  end

  test "frozen fixture binds the complete live payload and its section digests" do
    frozen = V14M0RegistryLedger.load_frozen!()

    assert V14M0RegistryLedger.fixture_path() == @fixture
    assert frozen["provenance"]["source_sha"] =~ ~r/^[0-9a-f]{40}$/
    assert frozen["provenance"]["generator_command"] =~ "write_frozen!"
    assert Map.drop(frozen, ["provenance"]) == V14M0RegistryLedger.snapshot()
    assert frozen["digests"]["payload_sha256"] == V14M0RegistryLedger.digest(frozen["payload"])
    assert :ok = V14M0RegistryLedger.check!()
  end

  test "live generation is repeatable, complete, and identical through explicit servers" do
    first = V14M0RegistryLedger.snapshot()
    second = V14M0RegistryLedger.snapshot()
    payload = first["payload"]

    assert first == second
    assert Enum.all?(payload["explicit_server_parity"], fn {_registry, parity?} -> parity? end)

    assert payload["actions"]["counts"] == %{
             "agent" => 62,
             "dynamic_overlay" => 0,
             "internal" => 219,
             "plugin_append" => 37,
             "static" => 244,
             "total" => 281
           }

    assert payload["settings"]["counts"]["fragments"] == 56
    assert payload["settings"]["counts"]["effective_keys"] == 624
    assert payload["settings"]["counts"]["safe_write_rows"] == 625
    assert payload["settings"]["counts"]["safe_write_unique_keys"] == 625
    assert payload["settings"]["counts"]["writable_effective_keys"] == 586
    assert payload["settings"]["counts"]["safe_and_writable_effective_keys"] == 586
    assert length(payload["apps"]["entries"]) == 6
    assert length(payload["plugins"]["entries"]) == 13

    assert payload["actions"]["definition_completeness"] == %{
             "compiled" => 281,
             "missing_from_registry" => [],
             "registry_missing_definition" => []
           }
  end

  test "isolated mutations bind lookup, duplicate diagnostics, and clear semantics" do
    scenario = V14M0RegistryLedger.snapshot()["payload"]["isolated_mutation_diagnostics"]

    assert scenario["initial"]["apps"] == 0
    assert scenario["initial"]["plugins"] == 0
    assert scenario["mutated"]["counts"]["apps"] == 1
    assert scenario["mutated"]["counts"]["plugins"] == 1
    assert scenario["mutated"]["action_diagnostics"] != []
    assert scenario["mutated"]["plugin_diagnostics"] != %{}
    assert scenario["mutated"]["app_diagnostics"] != %{}
    assert scenario["cleared"]["counts"] == scenario["initial"]
    assert scenario["cleared"]["action_diagnostics"] == []
    assert scenario["cleared"]["plugin_diagnostics"] == %{}
    assert scenario["cleared"]["app_diagnostics"] == %{}
  end

  test "canonical snapshot redacts environment-specific roots" do
    encoded = V14M0RegistryLedger.snapshot() |> Jason.encode!()

    refute encoded =~ Path.expand("../../../../..", __DIR__)
    refute encoded =~ System.fetch_env!("ALLBERT_HOME")
  end
end
