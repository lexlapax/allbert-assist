defmodule AllbertAssist.DevGates.V14M1A3ReleaseEvalInventoryTest do
  use ExUnit.Case, async: false

  @moduletag :external_runtime_serial

  @fixture Path.expand("../../fixtures/v1.4/m1a3_release_eval_inventory.json", __DIR__)

  test "every tracked raw release eval in a launcher, smoke, workflow, operator doc, or test is classified" do
    fixture = load_fixture!()
    rows = fixture["rows"]

    assert fixture["schema_version"] == 1
    assert fixture["normalization"] == "v14_m1a3_release_eval_inventory_v1"
    assert Enum.uniq_by(rows, &{&1["path"], &1["line"]}) == rows

    actual = tracked_raw_eval_rows()
    expected = MapSet.new(Enum.map(rows, &{&1["path"], &1["line"]}))

    assert MapSet.new(Enum.map(actual, &{&1.path, &1.line})) == expected

    Enum.each(rows, fn row ->
      assert row["classification"] in [
               "runtime_free",
               "unsafe_operator_passthrough",
               "runtime_bearing_bootstrapped",
               "runtime_bearing_product_entry",
               "attach_only_daemon_guarded"
             ]

      line = line_at!(row["path"], row["line"])

      assert digest(line) == row["line_sha256"],
             "stale raw-eval line digest for #{row["path"]}:#{row["line"]}"
    end)
  end

  test "runtime-bearing product validation uses ProductBootstrap before residual runtime code" do
    fixture = load_fixture!()

    fixture["rows"]
    |> Enum.filter(&(&1["classification"] == "runtime_bearing_bootstrapped"))
    |> Enum.each(fn row ->
      line = line_at!(row["path"], row["line"])

      assert line =~ "ProductBootstrap.ensure_ready([])",
             "#{row["path"]}:#{row["line"]} is runtime-bearing but bypasses ProductBootstrap"

      {bootstrap_index, bootstrap_length} =
        :binary.match(line, "ProductBootstrap.ensure_ready([])")

      after_bootstrap =
        binary_part(
          line,
          bootstrap_index + bootstrap_length,
          byte_size(line) - bootstrap_index - bootstrap_length
        )

      assert after_bootstrap =~ "AllbertAssist" or after_bootstrap =~ "$SQLITE_PROBE",
             "#{row["path"]}:#{row["line"]} reaches residual runtime code before readiness bootstrap"
    end)
  end

  test "unsafe passthrough is launcher-only and never a repository-owned PASS or FV row" do
    fixture = load_fixture!()

    fixture["rows"]
    |> Enum.filter(&(&1["classification"] == "unsafe_operator_passthrough"))
    |> Enum.each(fn row ->
      assert row["path"] =~ ~r{(?:^|/)(?:bin|scripts)/}
      line = line_at!(row["path"], row["line"])
      refute line =~ ~r/\b(?:PASS|FV|smoke|rehearsal)\b/i
    end)
  end

  test "the primary launcher separates raw passthrough, attach-only TUI, and ProductCLI boot" do
    fixture = load_fixture!()

    launcher_rows =
      Enum.filter(fixture["rows"], &(&1["path"] == "rel/overlays/bin/allbert-dispatch"))

    assert MapSet.new(launcher_rows, & &1["classification"]) ==
             MapSet.new([
               "unsafe_operator_passthrough",
               "attach_only_daemon_guarded",
               "runtime_bearing_product_entry"
             ])

    attach = Enum.find(launcher_rows, &(&1["classification"] == "attach_only_daemon_guarded"))
    product = Enum.find(launcher_rows, &(&1["classification"] == "runtime_bearing_product_entry"))

    assert line_at!(attach["path"], attach["line"]) =~ "AllbertAssist.CLI.Tui.launch!()"
    assert File.read!(project_path(attach["path"])) =~ "ALLBERT_CLI_ATTACH_ONLY=1"
    assert line_at!(product["path"], product["line"]) =~ "AllbertAssist.Pack.ProductCLI.main"

    product_cli =
      File.read!(project_path("apps/allbert_composition/lib/allbert_assist/pack/product_cli.ex"))

    assert product_cli =~ "ProductBootstrap.ensure_ready"
  end

  defp tracked_raw_eval_rows do
    for path <- tracked_paths(),
        eval_scope?(path),
        {line, number} <-
          File.read!(project_path(path)) |> String.split("\n") |> Enum.with_index(1),
        raw_eval_line?(line),
        do: %{path: path, line: number}
  end

  defp tracked_paths do
    {paths, 0} = System.cmd("git", ["ls-files"], cd: project_root())
    String.split(paths, "\n", trim: true)
  end

  defp eval_scope?(path) do
    String.starts_with?(path, [
      "scripts/",
      "docs/operator/",
      "homebrew/",
      ".github/",
      "rel/overlays/"
    ]) or
      String.contains?(path, "/.github/") or String.contains?(path, "/test/")
  end

  defp raw_eval_line?(line) do
    Regex.match?(
      ~r/\b(?:run_cli|run)\s+eval\b|\ballbert(?:-release)?["']?\s+eval\b|\/allbert["']?\s+eval\b|\|eval\||\$RELEASE_BIN["']?\s+eval\b/,
      line
    )
  end

  defp line_at!(path, line),
    do: project_path(path) |> File.read!() |> String.split("\n") |> Enum.at(line - 1)

  defp digest(value), do: :crypto.hash(:sha256, value) |> Base.encode16(case: :lower)
  defp load_fixture!, do: @fixture |> File.read!() |> Jason.decode!()
  defp project_path(path), do: Path.join(project_root(), path)
  defp project_root, do: Path.expand("../../../../..", __DIR__)
end
