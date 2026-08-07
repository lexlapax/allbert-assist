defmodule AllbertAssist.DevGates.ScopeSelector do
  @moduledoc """
  Fail-closed changed-path classification for proportional developer re-runs.

  Rules are exact paths and directory prefixes. Every matching rule contributes
  to the result, so overlapping paths only widen required evidence. This module
  selects work; it never executes tests or waives the active release gate.
  """

  @schema_version 1
  @active_gate "release.v132"
  @rules [
    %{
      id: "documentation",
      class: "docs_only",
      exact: ~w[README.md CHANGELOG.md DEVELOPMENT.md AGENTS.md],
      prefixes: ["docs/"],
      owners: ["docs"],
      lanes: [],
      aggregate_required: false
    },
    %{
      id: "gate_definitions",
      class: "shared_spine",
      exact: [
        "apps/allbert_assist/lib/mix/tasks/allbert.test.ex",
        "apps/allbert_assist/test/mix/tasks/allbert_test_task_test.exs",
        "docs/validation/test-manifest.csv"
      ],
      prefixes: [
        "apps/allbert_assist/lib/allbert_assist/dev_gates/",
        "apps/allbert_assist/test/allbert_assist/dev_gates/"
      ],
      owners: ["core"],
      lanes: ["app_env_serial", "external_runtime_serial"],
      aggregate_required: true
    },
    %{
      id: "settings_spine",
      class: "shared_spine",
      exact: [],
      prefixes: [
        "apps/allbert_assist/lib/allbert_assist/settings/",
        "apps/allbert_assist/test/allbert_assist/settings/"
      ],
      owners: ["core"],
      lanes: ["app_env_serial", "home_fs_serial"],
      aggregate_required: true
    },
    %{
      id: "action_registry_and_permission_spine",
      class: "shared_spine",
      exact: [
        "apps/allbert_assist/lib/allbert_assist/actions/registry.ex",
        "apps/allbert_assist/lib/allbert_assist/actions/runner.ex"
      ],
      prefixes: [
        "apps/allbert_assist/lib/allbert_assist/security/",
        "apps/allbert_assist/lib/allbert_assist/confirmations/"
      ],
      owners: ["core"],
      lanes: ["app_env_serial", "global_process_serial", "security_eval_serial"],
      aggregate_required: true
    },
    %{
      id: "projection_spine",
      class: "shared_spine",
      exact: [],
      prefixes: [
        "apps/allbert_assist/lib/allbert_assist/memory/projection",
        "apps/allbert_assist/lib/allbert_assist/search/projection"
      ],
      owners: ["core"],
      lanes: ["db_serial", "home_fs_serial", "global_process_serial"],
      aggregate_required: true
    },
    %{
      id: "release_workflow",
      class: "release_workflow",
      exact: ["mix.exs", "mix.lock"],
      prefixes: ["scripts/release/", ".github/workflows/", "config/"],
      owners: ["release"],
      lanes: ["external_runtime_serial"],
      aggregate_required: true
    },
    %{
      id: "web",
      class: "product_subsystem",
      exact: [],
      prefixes: ["apps/allbert_assist_web/"],
      owners: ["web"],
      lanes: ["liveview_serial"],
      aggregate_required: false
    },
    %{
      id: "stocksage",
      class: "product_subsystem",
      exact: [],
      prefixes: ["plugins/stocksage/"],
      owners: ["stocksage"],
      lanes: ["db_serial", "app_env_serial"],
      aggregate_required: false
    },
    %{
      id: "artifacts_plugin",
      class: "product_subsystem",
      exact: [],
      prefixes: ["plugins/allbert.artifacts/"],
      owners: ["artifacts"],
      lanes: ["db_serial", "global_process_serial"],
      aggregate_required: false
    },
    %{
      id: "channel_plugins",
      class: "product_subsystem",
      exact: [],
      prefixes: [
        "plugins/allbert.telegram/",
        "plugins/allbert.email/",
        "plugins/allbert.discord/",
        "plugins/allbert.slack/",
        "plugins/allbert.matrix/",
        "plugins/allbert.whatsapp/",
        "plugins/allbert.signal/",
        "plugins/allbert.notes_files/"
      ],
      owners: ["channel_plugins"],
      lanes: ["external_runtime_serial"],
      aggregate_required: false
    },
    %{
      id: "core",
      class: "product_subsystem",
      exact: [],
      prefixes: ["apps/allbert_assist/"],
      owners: ["core"],
      lanes: ["pure_async", "app_env_serial", "home_fs_serial", "global_process_serial"],
      aggregate_required: false
    }
  ]

  def select!(root, base, opts \\ []) when is_binary(base) do
    validate_base_syntax!(base)
    git = Keyword.get(opts, :git_runner, &git!/3)
    head = git.(root, ["rev-parse", "HEAD"], opts) |> String.trim()
    base_sha = git.(root, ["rev-parse", "--verify", "#{base}^{commit}"], opts) |> String.trim()

    case git_status(root, ["merge-base", "--is-ancestor", base_sha, head], opts) do
      {_, 0} ->
        :ok

      {_output, 1} ->
        Mix.raise("scope base is not an ancestor of HEAD: #{base}")

      {output, status} ->
        Mix.raise("unable to validate scope base (#{status}): #{String.trim(output)}")
    end

    merge_base = git.(root, ["merge-base", base_sha, head], opts) |> String.trim()

    changes =
      committed_changes(root, merge_base, head, git, opts) ++
        diff_changes(
          root,
          ["diff", "--cached", "--name-status", "-z", "--find-renames"],
          "staged",
          git,
          opts
        ) ++
        diff_changes(
          root,
          ["diff", "--name-status", "-z", "--find-renames"],
          "unstaged",
          git,
          opts
        ) ++
        untracked_changes(root, git, opts)

    result = classify_changes(changes)

    Map.merge(result, %{
      "schema_version" => @schema_version,
      "base_sha" => base_sha,
      "head_sha" => head,
      "merge_base_sha" => merge_base
    })
  rescue
    error in Mix.Error -> reraise(error, __STACKTRACE__)
  end

  def classify_paths(paths) when is_list(paths) do
    paths
    |> Enum.map(&%{"path" => &1, "source" => "provided", "status" => "M"})
    |> classify_changes()
  end

  def contract_rows do
    Enum.map(@rules, fn rule ->
      %{
        "id" => rule.id,
        "class" => rule.class,
        "exact" => rule.exact,
        "prefixes" => rule.prefixes,
        "owners" => rule.owners,
        "lanes" => rule.lanes,
        "aggregate_required" => rule.aggregate_required
      }
    end)
  end

  defp committed_changes(_root, merge_base, head, _git, _opts) when merge_base == head, do: []

  defp committed_changes(root, merge_base, head, git, opts) do
    diff_changes(
      root,
      ["diff", "--name-status", "-z", "--find-renames", "#{merge_base}..#{head}"],
      "committed",
      git,
      opts
    )
  end

  defp diff_changes(root, args, source, git, opts) do
    root
    |> git.(args, opts)
    |> parse_name_status(source)
  end

  defp untracked_changes(root, git, opts) do
    root
    |> git.(["ls-files", "--others", "--exclude-standard", "-z"], opts)
    |> String.split(<<0>>, trim: true)
    |> Enum.map(&%{"path" => &1, "source" => "untracked", "status" => "?"})
  end

  defp parse_name_status("", _source), do: []

  defp parse_name_status(output, source) do
    output
    |> String.split(<<0>>, trim: true)
    |> parse_name_status_tokens(source, [])
    |> Enum.reverse()
  end

  defp parse_name_status_tokens([], _source, acc), do: acc

  defp parse_name_status_tokens([status, old, new | rest], source, acc)
       when binary_part(status, 0, 1) in ["R", "C"] do
    rows = [
      %{"path" => old, "source" => source, "status" => status},
      %{"path" => new, "source" => source, "status" => status}
    ]

    parse_name_status_tokens(rest, source, Enum.reverse(rows) ++ acc)
  end

  defp parse_name_status_tokens([status, path | rest], source, acc) do
    parse_name_status_tokens(rest, source, [
      %{"path" => path, "source" => source, "status" => status} | acc
    ])
  end

  defp parse_name_status_tokens(tokens, _source, _acc) do
    Mix.raise("unable to parse git name-status output: #{inspect(tokens)}")
  end

  defp classify_changes(changes) do
    rows =
      changes
      |> Enum.uniq_by(&{&1["path"], &1["source"], &1["status"]})
      |> Enum.sort_by(&{&1["path"], &1["source"], &1["status"]})
      |> Enum.map(fn change ->
        matches = matching_rules(change["path"])
        Map.put(change, "matched_rules", Enum.map(matches, & &1.id))
      end)

    matched =
      rows
      |> Enum.flat_map(& &1["matched_rules"])
      |> Enum.uniq()

    rules = Enum.filter(@rules, &(&1.id in matched))
    unknown = rows |> Enum.filter(&(&1["matched_rules"] == [])) |> Enum.map(& &1["path"])
    aggregate? = unknown != [] or Enum.any?(rules, & &1.aggregate_required)

    diagnostics =
      if unknown == [] do
        []
      else
        ["unknown paths fail closed: #{Enum.join(unknown, ", ")}"]
      end

    required_gates =
      if rows == [] do
        []
      else
        rule_gates =
          rules
          |> Enum.flat_map(fn
            %{id: "documentation"} -> ["docs"]
            _rule -> [@active_gate]
          end)

        unknown_gates = if unknown == [], do: [], else: [@active_gate]
        ["preflight" | rule_gates ++ unknown_gates] |> Enum.uniq()
      end

    %{
      "changed_paths" => rows,
      "classes" => rules |> Enum.map(& &1.class) |> Enum.uniq() |> Enum.sort(),
      "matched_rules" => Enum.sort(matched),
      "owners" => rules |> Enum.flat_map(& &1.owners) |> Enum.uniq() |> Enum.sort(),
      "lanes" => rules |> Enum.flat_map(& &1.lanes) |> Enum.uniq() |> Enum.sort(),
      "required_gates" => required_gates,
      "aggregate_required" => aggregate?,
      "diagnostics" => diagnostics
    }
  end

  defp matching_rules(path) do
    Enum.filter(@rules, fn rule ->
      path in rule.exact or Enum.any?(rule.prefixes, &String.starts_with?(path, &1))
    end)
  end

  defp validate_base_syntax!(base) do
    unless Regex.match?(~r/\A[0-9a-fA-F]{7,40}\z/, base) do
      Mix.raise("scope --base must be a 7-40 character hexadecimal commit id")
    end
  end

  defp git!(root, args, _opts) do
    case System.cmd("git", args, cd: root, stderr_to_stdout: true) do
      {output, 0} ->
        output

      {output, status} ->
        Mix.raise("git #{Enum.join(args, " ")} failed (#{status}): #{String.trim(output)}")
    end
  end

  defp git_status(root, args, opts) do
    case Keyword.get(opts, :git_status_runner) do
      fun when is_function(fun, 3) -> fun.(root, args, opts)
      _ -> System.cmd("git", args, cd: root, stderr_to_stdout: true)
    end
  end
end
