defmodule AllbertAssist.DevGates.PreflightTest do
  use ExUnit.Case, async: false
  @moduletag :external_runtime_serial

  alias AllbertAssist.DevGates.Preflight
  alias AllbertAssist.DevGates.PreflightGuard
  alias Mix.Tasks.Allbert.Test, as: AllbertTestTask

  test "composition freezes owner-CWD load before both inventory checks" do
    ids = Enum.map(Preflight.step_definitions(), & &1.id)

    assert Enum.take(ids, 8) == [
             "forced_compile",
             "format",
             "whitespace",
             "docs",
             "registry_and_param_contract",
             "owner_cwd_test_load",
             "lane_tags",
             "test_manifest"
           ]

    assert Enum.drop(ids, 8) == [
             "fixture_memory_projection_and_schema_floor",
             "fixture_historical_security_release_and_intent_contracts"
           ]
  end

  test "all seven historical stops map to an executable preflight or compatibility check" do
    ids = Preflight.step_definitions() |> Enum.map(& &1.id) |> MapSet.new()
    allowed = MapSet.put(ids, "compatibility")
    mappings = Preflight.historical_stop_checks()

    assert map_size(mappings) == 7

    assert Enum.sort(Map.keys(mappings)) ==
             Enum.sort(~w[42adfef3 70b9bbf8 b9f60352 a86d721c 10f392de 34c7452f e9a39696])

    assert Enum.all?(mappings, fn {_sha, checks} ->
             checks != [] and Enum.all?(checks, &MapSet.member?(allowed, &1))
           end)

    historical_fixture = "fixture_historical_security_release_and_intent_contracts"
    assert mappings["42adfef3"] == ["docs", historical_fixture]
    assert mappings["a86d721c"] == [historical_fixture]
    assert mappings["34c7452f"] == [historical_fixture]
  end

  test "expensive command classification is central and high-coverage fast-local is conditional" do
    assert PreflightGuard.guarded?(["prepush"])

    assert PreflightGuard.guarded?([
             "serial-owner",
             "--owner",
             "kernel",
             "--lane",
             "app_env_serial"
           ])

    assert PreflightGuard.guarded?(["serial-core", "--lane", "db_serial"])
    assert PreflightGuard.guarded?(["release-assembly", "--checkpoint", "v14-m1a1"])
    assert PreflightGuard.guarded?(["release"])
    assert PreflightGuard.guarded?(["release.v132"])
    assert PreflightGuard.guarded?(["external-smoke", "docker_sandbox"])
    assert PreflightGuard.guarded?(["bench-v13-latency"])
    assert PreflightGuard.guarded?(["compatibility"])
    assert PreflightGuard.guarded?(["fast-local", "--core-lanes"])

    refute PreflightGuard.guarded?(["preflight"])
    refute PreflightGuard.guarded?(["scope", "--base", "abcdef0"])
    refute PreflightGuard.guarded?(["docs"])
    refute PreflightGuard.guarded?(["focused", "--", "test/example_test.exs"])
    refute PreflightGuard.guarded?(["fast-local"])
    refute PreflightGuard.guarded?(["external-smoke", "list"])

    refute PreflightGuard.clean_required?([
             "serial-owner",
             "--owner",
             "core",
             "--lane",
             "app_env_serial"
           ])

    assert PreflightGuard.clean_required?([
             "release-assembly",
             "--checkpoint",
             "v14-m1a1"
           ])
  end

  test "an unclassified future command is refused before it can dispatch" do
    assert_raise Mix.Error, ~r/unclassified allbert.test command: future-expensive/, fn ->
      PreflightGuard.verify!(["future-expensive"], "/unused")
    end

    assert :ok = PreflightGuard.verify!(["docs"], "/unused")
    assert :ok = PreflightGuard.verify!(["release.structure", "v132"], "/unused")
  end

  test "normalized contract digest is stable and complete" do
    digest = Preflight.contract_digest()
    assert digest =~ ~r/\A[0-9a-f]{64}\z/
    assert digest == Preflight.contract_digest()
  end

  test "lane reconciliation fails red-first on missing and duplicate primary tags" do
    record = %{
      path: "test/example_test.exs",
      template: "ExUnit.Case",
      primary_lane: :pure_async
    }

    assert [missing] =
             AllbertTestTask.lane_reconciliation_issues([record], fn _path ->
               "use ExUnit.Case, async: true\n"
             end)

    assert missing =~ "found no primary lane tag"

    assert [duplicate] =
             AllbertTestTask.lane_reconciliation_issues([record], fn _path ->
               "@module" <> "tag :pure_async\n@module" <> "tag :db_serial\n"
             end)

    assert duplicate =~ "found :pure_async, :db_serial"
  end
end
