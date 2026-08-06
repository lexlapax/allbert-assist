defmodule AllbertAssist.DevGates.FixtureRegistry do
  @moduledoc """
  Executable fixture-contract sentinels for deterministic historical drift.

  Entries name the smallest real owner-CWD tests that failed when production
  contracts changed. This is development tooling, not a runtime registry.
  """

  @entries [
    %{
      id: "memory_projection_and_schema_floor",
      owner: :core,
      tag: :preflight_fixture_memory,
      expected_tests: 4,
      paths: [
        "apps/allbert_assist/test/mix/tasks/allbert_memory_test.exs",
        "apps/allbert_assist/test/allbert_assist/settings/version_contract_test.exs"
      ]
    },
    %{
      id: "historical_security_release_and_intent_contracts",
      owner: :core,
      tag: :preflight_fixture_historical_contracts,
      expected_tests: 11,
      paths: [
        "apps/allbert_assist/test/allbert_assist/database/sqlite_topology_test.exs",
        "apps/allbert_assist/test/allbert_assist/intent/eval/corpus_completeness_test.exs",
        "apps/allbert_assist/test/allbert_assist/release/promotion_workflow_contract_test.exs",
        "apps/allbert_assist/test/security/active_memory_eval_test.exs",
        "apps/allbert_assist/test/security/security_eval_case_test.exs",
        "apps/allbert_assist/test/security/v053_channel_pack_eval_test.exs",
        "apps/allbert_assist/test/security/v064_sweep_eval_test.exs",
        "apps/allbert_assist/test/security/v065_sweep_eval_test.exs"
      ]
    }
  ]

  def entries, do: @entries

  def fetch!(id) when is_binary(id) do
    Enum.find(@entries, &(&1.id == id)) || Mix.raise("unknown fixture sentinel #{id}")
  end

  def validate!(root, cwd_resolver) when is_function(cwd_resolver, 1) do
    validate_entries!(@entries, root, cwd_resolver)
  end

  @doc false
  def validate_entries!(entries, root, cwd_resolver)
      when is_list(entries) and is_function(cwd_resolver, 1) do
    ids = Enum.map(entries, & &1.id)
    paths = Enum.flat_map(entries, & &1.paths)
    tags = Enum.map(entries, & &1.tag)

    errors =
      []
      |> duplicate_errors(ids, "fixture sentinel id")
      |> duplicate_errors(paths, "fixture sentinel path")
      |> duplicate_errors(tags, "fixture sentinel tag")
      |> then(fn errors ->
        Enum.reduce(entries, errors, fn entry, acc ->
          cwd = cwd_resolver.(entry.owner)

          acc
          |> maybe_add(not File.dir?(cwd), "#{entry.id}: owner CWD missing: #{cwd}")
          |> maybe_add(
            not is_integer(entry.expected_tests) or entry.expected_tests < 1,
            "#{entry.id}: expected_tests must be a positive integer"
          )
          |> then(fn acc ->
            Enum.reduce(entry.paths, acc, fn path, inner ->
              maybe_add(
                inner,
                not File.regular?(Path.join(root, path)),
                "#{entry.id}: path missing: #{path}"
              )
            end)
          end)
        end)
      end)

    if errors == [],
      do: :ok,
      else:
        Mix.raise(
          "fixture sentinel registry invalid:\n" <> Enum.map_join(errors, "\n", &("  - " <> &1))
        )
  end

  def contract_rows do
    Enum.map(@entries, fn entry ->
      %{
        "id" => entry.id,
        "owner" => Atom.to_string(entry.owner),
        "tag" => Atom.to_string(entry.tag),
        "expected_tests" => entry.expected_tests,
        "paths" => entry.paths
      }
    end)
  end

  defp duplicate_errors(errors, values, label) do
    values
    |> Enum.frequencies()
    |> Enum.filter(fn {_value, count} -> count > 1 end)
    |> Enum.reduce(errors, fn {value, _count}, acc -> acc ++ ["duplicate #{label}: #{value}"] end)
  end

  defp maybe_add(errors, true, reason), do: errors ++ [reason]
  defp maybe_add(errors, false, _reason), do: errors
end
