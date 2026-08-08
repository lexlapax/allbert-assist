defmodule AllbertAssist.DevGates.GateBaseline do
  @moduledoc """
  Exact M7 structure proof for the pre-inversion release and path baseline.

  The committed fixture comes from Git object `7ae566f59`; verification is
  read-only and resolves every executable test target through the current
  canonical owner projection.
  """

  alias AllbertAssist.DevGates.GateOwners

  @fixture "apps/allbert_assist/test/fixtures/v1.4/m7_gate_path_baseline.json"
  @base_git_sha "7ae566f59"

  @spec issues(String.t(), map()) :: [String.t()]
  def issues(repository_root, current_definitions)
      when is_binary(repository_root) and is_map(current_definitions) do
    with {:ok, bytes} <- File.read(Path.join(repository_root, @fixture)),
         {:ok, fixture} <- Jason.decode(bytes) do
      fixture_issues(fixture, repository_root, current_definitions)
    else
      {:error, reason} -> ["M7 gate baseline fixture is unreadable: #{inspect(reason)}"]
    end
  end

  @spec verify!(String.t(), map()) :: :ok
  def verify!(repository_root, current_definitions) do
    case issues(repository_root, current_definitions) do
      [] -> :ok
      issues -> raise ArgumentError, "M7 gate baseline drift:\n" <> Enum.join(issues, "\n")
    end
  end

  defp fixture_issues(fixture, repository_root, current_definitions) do
    expected = Map.get(fixture, "definitions", %{})
    current = normalize_current(current_definitions)

    []
    |> add(fixture["schema_version"] != 1, "fixture schema_version is not 1")
    |> add(fixture["base_git_sha"] != @base_git_sha, "fixture base Git SHA changed")
    |> add(
      Map.keys(expected) |> Enum.sort() != Map.keys(current) |> Enum.sort(),
      "release gate set changed"
    )
    |> add(expected != current, definition_drift(expected, current))
    |> Kernel.++(target_issues(expected, repository_root))
    |> Kernel.++(path_disposition_issues(fixture["path_references"], repository_root))
  end

  defp normalize_current(definitions) do
    Map.new(definitions, fn {gate, steps} ->
      {gate,
       Enum.map(steps, fn step ->
         Map.put(step, "timeout", Map.get(step, "timeout", "system_cmd_default"))
       end)}
    end)
  end

  defp definition_drift(expected, current) do
    gate =
      expected
      |> Map.keys()
      |> Enum.sort()
      |> Enum.find(fn gate -> Map.get(expected, gate) != Map.get(current, gate) end)

    "normalized release definition/order drift#{if gate, do: " at #{gate}", else: ""}"
  end

  defp target_issues(definitions, repository_root) do
    records = GateOwners.load!(repository_root)

    Enum.flat_map(definitions, fn {gate, steps} ->
      steps
      |> Enum.with_index()
      |> Enum.flat_map(fn {step, step_index} ->
        cwd = historical_cwd(repository_root, step["cwd"])

        step
        |> test_targets()
        |> Enum.with_index()
        |> Enum.flat_map(fn {target, target_index} ->
          try do
            resolution =
              GateOwners.resolve_test_target!(records, target, cwd, repository_root)

            if File.regular?(Path.join(repository_root, resolution.path)) do
              []
            else
              [target_issue(gate, step, step_index, target, target_index, "not a file")]
            end
          rescue
            error ->
              [
                target_issue(
                  gate,
                  step,
                  step_index,
                  target,
                  target_index,
                  Exception.message(error)
                )
              ]
          end
        end)
      end)
    end)
  end

  defp test_targets(%{"executable" => "mix", "args" => ["test" | arguments]}) do
    Enum.filter(arguments, &test_target?/1)
  end

  defp test_targets(%{"executable" => "sh", "args" => ["-c", script]}) do
    ~r{(?:apps/[^\s]+|plugins/[^\s]+|test/[^\s]+)_test\.exs}
    |> Regex.scan(script)
    |> Enum.map(&hd/1)
  end

  defp test_targets(_step), do: []

  defp test_target?(target) when is_binary(target) do
    (String.starts_with?(target, "test/") or String.starts_with?(target, "apps/") or
       String.starts_with?(target, "plugins/")) and String.contains?(target, "_test.exs")
  end

  defp historical_cwd(root, "core"), do: Path.join(root, "apps/allbert_assist")
  defp historical_cwd(root, "web"), do: Path.join(root, "apps/allbert_assist_web")
  defp historical_cwd(root, "root"), do: root

  defp target_issue(gate, step, step_index, target, target_index, reason) do
    "#{gate} step #{step_index}:#{step["id"]} target #{target_index}:#{target} #{reason}"
  end

  defp path_disposition_issues(references, repository_root) when is_list(references) do
    Enum.flat_map(references, fn reference ->
      file = reference["source_file"]
      literal = reference["literal"]
      disposition = reference["disposition"]
      reason = reference["reason"]

      source =
        case File.read(Path.join(repository_root, file)) do
          {:ok, bytes} -> bytes
          _ -> ""
        end

      cond do
        not is_binary(file) or not is_binary(literal) ->
          ["invalid path-reference carrier"]

        disposition == "owner_manifest_resolved" and
            not (String.contains?(source, literal) and String.contains?(source, "GateOwners")) ->
          ["owner-resolved path disposition drift: #{file}:#{literal}"]

        disposition == "intentionally_fixed" and not (is_binary(reason) and reason != "") ->
          ["fixed path has no reason: #{file}:#{literal}"]

        disposition not in ["owner_manifest_resolved", "intentionally_fixed"] ->
          ["unknown path disposition: #{file}:#{literal}"]

        true ->
          []
      end
    end)
  end

  defp path_disposition_issues(_references, _repository_root),
    do: ["path-reference inventory is missing"]

  defp add(issues, true, issue), do: [issue | issues]
  defp add(issues, false, _issue), do: issues
end
