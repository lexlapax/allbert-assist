defmodule AllbertAssist.DevGates.V14M1A3EffectBoundaryRosterTest do
  use ExUnit.Case, async: true

  @fixture Path.expand("../../fixtures/v1.4/m1a3_effect_boundaries.json", __DIR__)
  @source_roots [
    "apps/allbert_assist/lib",
    "apps/allbert_assist_web/lib",
    "apps/allbert_composition/lib",
    "plugins/*/lib"
  ]
  @required_fields ~w[
    id owner entrypoint source_path phase admission_mode carrier_policy
    missing_or_stale_result compatibility_provenance focused_test
  ]

  test "the generated roster has one complete, phase-classified row for every boundary" do
    fixture = load_fixture!()
    rows = fixture["rows"]

    assert fixture["schema_version"] == 1
    assert fixture["normalization"] == "v14_m1a3_effect_boundaries_v1"
    assert is_list(rows) and rows != []
    assert Enum.uniq_by(rows, & &1["id"]) == rows

    Enum.each(rows, fn row ->
      assert Map.keys(row) |> Enum.sort() == Enum.sort(@required_fields)
      assert row["phase"] in ["ready", "authorizing"]
      assert row["admission_mode"] in ["ready_carried", "ready_compat_admit", "authorizing_boot"]
      assert File.regular?(project_path(row["source_path"]))

      case row["admission_mode"] do
        "ready_compat_admit" -> assert is_binary(row["compatibility_provenance"])
        _other -> assert is_nil(row["compatibility_provenance"])
      end
    end)
  end

  test "every direct guard caller is rostered, and no unlisted caller can appear" do
    fixture = load_fixture!()

    assert source_paths_matching(~r/\bEffectGuard\b/) == fixture["expected_effect_guard_sources"]

    assert source_paths_matching(~r/\bActivationGuard\./) ==
             fixture["expected_activation_guard_sources"]

    assert source_paths_matching(~r/\ballbert_pack_epoch\b/) == fixture["expected_epoch_sources"]

    row_paths = fixture["rows"] |> Enum.map(& &1["source_path"]) |> MapSet.new()

    Enum.each(
      fixture["expected_effect_guard_sources"] ++
        fixture["expected_activation_guard_sources"] ++ fixture["expected_epoch_sources"],
      fn path -> assert MapSet.member?(row_paths, path), "missing roster row for #{path}" end
    )
  end

  test "compatibility admission is restricted to enumerated frozen facades" do
    fixture = load_fixture!()

    compatibility =
      fixture["rows"]
      |> Enum.filter(&(&1["admission_mode"] == "ready_compat_admit"))
      |> Enum.map(& &1["id"])
      |> MapSet.new()

    assert compatibility ==
             MapSet.new([
               "runner-run-3",
               "runner-run-2",
               "runtime-submit-1",
               "cli-run-1",
               "cli-run-attached-1",
               "app-registry-register-2",
               "plugin-registry-register"
             ])
  end

  test "activation is accepted only through the internal carrier at rostered authorizing callsites" do
    fixture = load_fixture!()

    authorizing_rows = Enum.filter(fixture["rows"], &(&1["phase"] == "authorizing"))

    assert authorizing_rows != []

    Enum.each(authorizing_rows, fn row ->
      source = File.read!(project_path(row["source_path"]))

      assert source =~ ":allbert_pack_activation",
             "#{row["id"]} must accept only the internal :allbert_pack_activation carrier"

      assert source =~ "ActivationGuard.validate",
             "#{row["id"]} must validate the authorizing carrier"
    end)

    activation_key_sources = source_paths_matching(~r/\ballbert_pack_activation\b/)
    authorizing_paths = authorizing_rows |> Enum.map(& &1["source_path"]) |> MapSet.new()
    rejection_paths = MapSet.new(fixture["expected_activation_rejection_sources"])

    assert activation_key_sources
           |> Enum.reject(
             &(MapSet.member?(authorizing_paths, &1) or MapSet.member?(rejection_paths, &1))
           ) == [],
           "public/steady-state source accepts the activation carrier"

    Enum.each(fixture["expected_activation_rejection_sources"], fn path ->
      assert File.read!(project_path(path)) =~ "{:error, :product_not_ready}"
    end)
  end

  defp load_fixture! do
    @fixture
    |> File.read!()
    |> Jason.decode!()
  end

  defp source_paths_matching(pattern) do
    @source_roots
    |> Enum.flat_map(fn root ->
      Path.wildcard(Path.join([project_root(), root, "**", "*.ex"]))
    end)
    |> Enum.filter(&(File.read!(&1) =~ pattern))
    |> Enum.map(&Path.relative_to(&1, project_root()))
    |> Enum.sort()
  end

  defp project_path(path), do: Path.join(project_root(), path)
  defp project_root, do: Path.expand("../../../../..", __DIR__)
end
