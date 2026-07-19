defmodule AllbertAssist.DevGates.TestManifest do
  @moduledoc """
  Static per-test manifest and drift check (v1.0.2 M8.9).

  The M8.8 packing audit proved that per-file inventory cannot see per-test
  lane facts: `cli/areas/onboarding_test.exs` carries a describe-level
  `@describetag :external_runtime_serial` under a module-level
  `:app_env_serial`, so its three dual-lane tests execute in two packed
  lanes (operator-preserved multiplicity 2). This module walks every
  inventory record's source text and emits one row per `test "..."` /
  `property "..."` clause — owner, repository path, module, describe
  context, name, primary lane, every lane tag by level
  (module/describe/test), skip/exclusion tags, and the expected execution
  multiplicity (the count of distinct lanes whose `--only` filter selects
  the test). `mix allbert.test inventory --manifest` writes the committed
  CSV; `--check-manifest` diffs a live regeneration against it, so test
  loss or lane drift fails gates as a standing invariant rather than a
  one-off audit artifact.

  Developer-gate infrastructure only: no runtime authority and no Security
  Central participation.
  """

  @manifest_relative "docs/validation/test-manifest.csv"
  @headers [
    :owner,
    :path,
    :module,
    :kind,
    :describe,
    :name,
    :primary_lane,
    :lane_tags,
    :skip_tags,
    :multiplicity
  ]
  @diff_limit 20

  # Same head shape the inventory test_count scan matches, narrowed to a
  # literal double-quoted name — the house style for every real test head
  # (the only unquoted matches in the tree are shell text inside heredocs).
  @test_head ~r/^\s*(test|property)\s+"((?:[^"\\]|\\.)*)"/
  @describe_head ~r/^  describe\s+"((?:[^"\\]|\\.)*)"/
  # Formatted test files close a top-level describe with a two-space `end`;
  # everything nested inside the block closes at four spaces or deeper.
  @describe_end ~r/^  end\s*$/
  @module_head ~r/^defmodule\s+([A-Za-z0-9_.]+)/
  @tag_atom ~r/:([a-z_]+)\b/

  def manifest_relative_path, do: @manifest_relative

  @doc """
  One manifest row per test/property across `records` (inventory records
  carrying `:path`, `:owner`, and `:primary_lane`), whose paths resolve
  against `root`. `lanes` is the known lane-atom list; only those atoms
  count as lane tags. Ordering is deterministic: records in the given
  (sorted) order, tests in source order within each file.
  """
  def rows(records, root, lanes) do
    lane_names = Enum.map(lanes, &Atom.to_string/1)

    Enum.flat_map(records, fn record ->
      file_rows(record, File.read!(Path.join(root, record.path)), lane_names)
    end)
  end

  @doc """
  Manifest rows for one file's source `text` under `record`'s identity.
  Seam for `rows/3` and for fixture-driven tests.
  """
  def file_rows(record, text, lane_names) do
    initial = %{
      module: nil,
      describe: nil,
      module_tags: [],
      describe_tags: [],
      pending_tags: [],
      rows: []
    }

    text
    |> String.split("\n")
    |> Enum.reduce(initial, &scan_line(&2, &1, record, lane_names))
    |> Map.fetch!(:rows)
    |> Enum.reverse()
  end

  @doc "Renders manifest `rows` as the committed CSV (header + one line per row)."
  def csv(rows) do
    lines =
      [Enum.map_join(@headers, ",", &cell/1)] ++
        Enum.map(rows, fn row ->
          Enum.map_join(@headers, ",", fn key -> cell(Map.fetch!(row, key)) end)
        end)

    Enum.join(lines, "\n") <> "\n"
  end

  @doc """
  Compares a live CSV against the committed CSV. Returns `:ok` on an exact
  match, else `{:error, summary}` naming the drifted rows (bounded at
  #{@diff_limit} per direction).
  """
  def check(live_csv, committed_csv) do
    live = String.split(live_csv, "\n", trim: true)
    committed = String.split(committed_csv, "\n", trim: true)

    if live == committed do
      :ok
    else
      {:error, diff_summary(live, committed)}
    end
  end

  defp scan_line(state, line, record, lane_names) do
    case classify_line(state, line) do
      {:module, module} ->
        %{state | module: module}

      {:describe, describe} ->
        %{state | describe: describe, describe_tags: [], pending_tags: []}

      :describe_end ->
        %{state | describe: nil, describe_tags: [], pending_tags: []}

      {:moduletag, expr} ->
        %{state | module_tags: state.module_tags ++ [expr]}

      {:describetag, expr} ->
        %{state | describe_tags: state.describe_tags ++ [expr]}

      {:tag, expr} ->
        %{state | pending_tags: state.pending_tags ++ [expr]}

      {:test, kind, name} ->
        row = row(record, state, kind, name, lane_names)
        %{state | rows: [row | state.rows], pending_tags: []}

      :other ->
        state
    end
  end

  defp classify_line(state, line) do
    classify_structure(state, line) || classify_tag(String.trim(line)) || :other
  end

  defp classify_structure(state, line) do
    cond do
      is_nil(state.module) and Regex.match?(@module_head, line) ->
        [_line, module] = Regex.run(@module_head, line)
        {:module, module}

      Regex.match?(@describe_head, line) ->
        [_line, describe] = Regex.run(@describe_head, line)
        {:describe, describe}

      not is_nil(state.describe) and Regex.match?(@describe_end, line) ->
        :describe_end

      Regex.match?(@test_head, line) ->
        [_line, kind, name] = Regex.run(@test_head, line)
        {:test, kind, name}

      true ->
        nil
    end
  end

  defp classify_tag(trimmed) do
    cond do
      tag_line?(trimmed, "@moduletag") -> {:moduletag, tag_expr(trimmed, "@moduletag")}
      tag_line?(trimmed, "@describetag") -> {:describetag, tag_expr(trimmed, "@describetag")}
      tag_line?(trimmed, "@tag") -> {:tag, tag_expr(trimmed, "@tag")}
      true -> nil
    end
  end

  defp tag_line?(trimmed, prefix), do: String.starts_with?(trimmed, prefix <> " ")

  defp tag_expr(trimmed, prefix), do: trimmed |> String.trim_leading(prefix) |> String.trim()

  defp row(record, state, kind, name, lane_names) do
    module_lanes = lane_tags(state.module_tags, lane_names)
    describe_lanes = lane_tags(state.describe_tags, lane_names)
    test_lanes = lane_tags(state.pending_tags, lane_names)
    primary = to_string(record.primary_lane)

    lane_tags =
      Enum.map(module_lanes, &"module:#{&1}") ++
        Enum.map(describe_lanes, &"describe:#{&1}") ++
        Enum.map(test_lanes, &"test:#{&1}")

    skip_tags =
      (state.module_tags ++ state.describe_tags ++ state.pending_tags)
      |> Enum.filter(&skip_tag?/1)

    # Expected execution multiplicity: each distinct lane whose `--only`
    # filter selects this test runs it once (any-tag-level packed lists).
    multiplicity =
      [primary | module_lanes ++ describe_lanes ++ test_lanes]
      |> Enum.uniq()
      |> length()

    %{
      owner: record.owner,
      path: record.path,
      module: state.module || "unknown",
      kind: kind,
      describe: state.describe || "",
      name: name,
      primary_lane: primary,
      lane_tags: Enum.join(lane_tags, "; "),
      skip_tags: Enum.join(skip_tags, "; "),
      multiplicity: multiplicity
    }
  end

  defp lane_tags(tag_exprs, lane_names) do
    tag_exprs
    |> Enum.flat_map(fn expr ->
      @tag_atom |> Regex.scan(expr) |> Enum.map(fn [_match, tag] -> tag end)
    end)
    |> Enum.filter(&(&1 in lane_names))
    |> Enum.uniq()
  end

  defp skip_tag?(expr), do: expr =~ ~r/^:?skip\b/

  defp diff_summary(live, committed) do
    missing = committed -- live
    added = live -- committed

    reordered_note =
      if missing == [] and added == [] do
        ["same rows in a different order — regenerate with `inventory --manifest`"]
      else
        []
      end

    lines =
      ["live manifest has #{length(live)} lines, committed has #{length(committed)}"] ++
        section("only in committed manifest (lost or changed in the tree)", missing) ++
        section("only in live regeneration (new or changed in the tree)", added) ++
        reordered_note

    Enum.join(lines, "\n")
  end

  defp section(_label, []), do: []

  defp section(label, rows) do
    shown = Enum.take(rows, @diff_limit)
    hidden = length(rows) - length(shown)
    more = if hidden > 0, do: ["  ... #{hidden} more"], else: []

    ["#{label}: #{length(rows)}"] ++ Enum.map(shown, &("  - " <> &1)) ++ more
  end

  defp cell(value) do
    value = value |> to_string() |> String.replace("\n", " ")
    "\"" <> String.replace(value, "\"", "\"\"") <> "\""
  end
end
