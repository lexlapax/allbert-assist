defmodule Mix.Tasks.Allbert.Test do
  @moduledoc """
  Run Allbert's developer-facing test gates.

  ## Usage

      mix allbert.test docs
      mix allbert.test inventory [--output PATH] [--check-tags]
      mix allbert.test focused -- FILE [FILE...]
      mix allbert.test commit
      mix allbert.test prepush [--partitions N]
      mix allbert.test fast-local [--core-lanes] [--stocksage-lanes] [--web-lanes] [--partitions N]
      mix allbert.test partition-smoke [--partitions N]
      mix allbert.test serial-core --lane LANE [--partitions N]
      mix allbert.test release
      mix allbert.test release.v042
      mix allbert.test release.v043
      mix allbert.test release.v044
      mix allbert.test release.v045
      mix allbert.test external-smoke list
      mix allbert.test external-smoke -- browser_research
      mix allbert.test external-smoke -- docker_sandbox
      mix allbert.test external-smoke -- docker_full_gate

  `mix precommit` is a compatibility shortcut for `mix allbert.test commit`;
  release evidence is `mix allbert.test release`.
  """

  use Mix.Task

  alias AllbertAssist.DevGates.PhaseRunner

  @shortdoc "Run Allbert developer test gates"

  @roots [
    "apps/allbert_assist/test",
    "apps/allbert_assist_web/test",
    "plugins/stocksage/test",
    "plugins/allbert.telegram/test",
    "plugins/allbert.email/test"
  ]

  @template_defaults %{
    "AllbertAssist.DataCase" => :db_serial,
    "AllbertAssistWeb.ConnCase" => :liveview_serial,
    "AllbertAssist.SecurityEvalCase" => :security_eval_serial,
    "StockSage.DataCase" => :db_serial
  }

  @lanes ~w[
    pure_async
    db_serial
    db_partition_safe
    app_env_serial
    home_fs_serial
    global_process_serial
    external_runtime_serial
    liveview_serial
    security_eval_serial
  ]a

  @impl true
  def run(["docs"]), do: docs()
  def run(["inventory" | rest]), do: inventory(rest)
  def run(["focused" | rest]), do: focused(rest)
  def run(["commit" | rest]), do: commit(rest)
  def run(["prepush" | rest]), do: prepush(rest)
  def run(["fast-local" | rest]), do: fast_local(rest)
  def run(["partition-smoke" | rest]), do: partition_smoke(rest)
  def run(["serial-core" | rest]), do: serial_core(rest)
  def run(["release"]), do: release()
  def run(["release.v042"]), do: release_v042()
  def run(["release.v043"]), do: release_v043()
  def run(["release.v044"]), do: release_v044()
  def run(["release.v045"]), do: release_v045()
  def run(["external-smoke" | rest]), do: external_smoke(rest)
  def run(_args), do: usage!()

  defp docs do
    run_cmd!("docs", root(), "git", ["diff", "--check"], [])
  end

  defp inventory(args) do
    {opts, rest, invalid} =
      OptionParser.parse(args, strict: [output: :string, check_tags: :boolean])

    reject_invalid!(invalid)
    reject_rest!(rest)

    records = inventory_records()

    if Keyword.get(opts, :check_tags, false) do
      check_lane_tags!(records)
    end

    csv = inventory_csv(records)

    case Keyword.get(opts, :output) do
      nil ->
        Mix.shell().info(csv)

      path ->
        path = Path.expand(path, root())
        File.mkdir_p!(Path.dirname(path))
        File.write!(path, csv)
        Mix.shell().info("wrote #{Path.relative_to(path, root())}")
    end
  end

  defp focused(args) do
    files = args |> reject_separator() |> Enum.reject(&(&1 == ""))

    if files == [] do
      Mix.raise("focused gate requires at least one test file")
    end

    files
    |> group_files()
    |> Enum.each(fn {owner, owner_files} ->
      run_test_files!("focused #{owner}", owner, owner_files, owned_env("focused-#{owner}", 0))
    end)
  end

  defp commit(args) do
    reject_rest!(args)

    case changed_files() do
      {:ok, files} ->
        if files != [] and Enum.all?(files, &docs_path?/1) do
          Mix.shell().info("==> commit gate docs-only")
          docs()
        else
          run_phase_gate!("commit", commit_phases(), evidence?: false, cleanup?: true)
          print_commit_guidance(files)
        end

      {:error, reason} ->
        Mix.shell().info("==> commit gate changed-file inspection unavailable: #{reason}")
        run_phase_gate!("commit", commit_phases(), evidence?: false, cleanup?: true)
        print_commit_guidance([])
    end
  end

  defp prepush(args) do
    {opts, rest, invalid} = OptionParser.parse(args, strict: [partitions: :integer])

    reject_invalid!(invalid)
    reject_rest!(rest)

    partitions = Keyword.get(opts, :partitions, default_partition_count())
    validate_partitions!(partitions)

    run_phase_gate!("prepush", prepush_phases(partitions), evidence?: true, cleanup?: false)
  end

  defp fast_local(args) do
    {opts, rest, invalid} =
      OptionParser.parse(args,
        strict: [
          core_lanes: :boolean,
          stocksage_lanes: :boolean,
          web_lanes: :boolean,
          partitions: :integer
        ]
      )

    reject_invalid!(invalid)
    reject_rest!(rest)

    core_lanes? = Keyword.get(opts, :core_lanes, false)
    stocksage_lanes? = Keyword.get(opts, :stocksage_lanes, false)
    web_lanes? = Keyword.get(opts, :web_lanes, false)
    partitions = Keyword.get(opts, :partitions, default_partition_count())

    if Keyword.has_key?(opts, :partitions) and
         not (core_lanes? or stocksage_lanes? or web_lanes?) do
      Mix.raise("--partitions is only valid with --core-lanes, --stocksage-lanes, or --web-lanes")
    end

    validate_partitions!(partitions)

    run_cmd!(
      "static",
      root(),
      "mix",
      [
        "do",
        "compile",
        "--warnings-as-errors",
        "+",
        "format",
        "--check-formatted",
        "+",
        "credo",
        "--strict"
      ],
      owned_env("fast-local-static", 0)
    )

    async_groups =
      fast_local_records()
      |> Enum.map(& &1.path)
      |> group_files()
      |> Enum.map(fn {owner, files} ->
        %{
          label: "fast-local #{owner} (#{length(files)} files)",
          prepare_label: "fast-local prepare #{owner}",
          owner: owner,
          files: files,
          env: owned_env("fast-local-#{owner}", 0),
          raw?: true
        }
      end)

    Enum.each(async_groups, &prepare_test_group!/1)
    run_parallel_tests!(async_groups)

    if core_lanes? do
      [:db_serial, :app_env_serial, :home_fs_serial, :global_process_serial]
      |> Enum.each(&run_serial_partitions!(:core, &1, partitions))
    end

    if stocksage_lanes? do
      [:db_serial, :app_env_serial, :global_process_serial]
      |> Enum.each(&run_serial_partitions!(:stocksage, &1, partitions))
    end

    if web_lanes? do
      [:liveview_serial]
      |> Enum.each(&run_serial_partitions!(:web, &1, partitions))
    end
  end

  defp partition_smoke(args) do
    {opts, rest, invalid} = OptionParser.parse(args, strict: [partitions: :integer])

    reject_invalid!(invalid)
    reject_rest!(rest)

    partitions = Keyword.get(opts, :partitions, 2)
    validate_partitions!(partitions)

    1..partitions
    |> Enum.map(fn partition ->
      %{
        label: "partition-smoke p#{partition}",
        partition: partition,
        env: owned_env("partition-smoke", partition)
      }
    end)
    |> Task.async_stream(&run_partition_smoke/1, timeout: :infinity, max_concurrency: partitions)
    |> Enum.map(fn
      {:ok, result} -> result
      {:exit, reason} -> {:error, Exception.format_exit(reason)}
    end)
    |> print_parallel_results!()
  end

  defp serial_core(args) do
    {opts, rest, invalid} =
      OptionParser.parse(args, strict: [lane: :string, partitions: :integer])

    reject_invalid!(invalid)
    reject_rest!(rest)

    lane =
      opts
      |> Keyword.get(:lane, nil)
      |> parse_lane!()

    partitions = Keyword.get(opts, :partitions, 1)
    validate_partitions!(partitions)

    if lane in [:security_eval_serial, :external_runtime_serial] and partitions != 1 do
      Mix.raise("#{lane} must run as a single-VM serial or external smoke lane")
    end

    run_serial_partitions!(:core, lane, partitions)
  end

  defp run_serial_partitions!(owner, lane, partitions) do
    1..partitions
    |> Enum.map(fn partition ->
      %{
        label: "serial-#{owner} #{lane} p#{partition}/#{partitions}",
        owner: owner,
        partition: partition,
        partitions: partitions,
        lane: lane,
        env: owned_env("serial-#{owner}-#{lane}", partition)
      }
    end)
    |> Task.async_stream(&run_serial_partition/1,
      timeout: :infinity,
      max_concurrency: partitions
    )
    |> Enum.map(fn
      {:ok, result} -> result
      {:exit, reason} -> {:error, Exception.format_exit(reason)}
    end)
    |> print_parallel_results!()
  end

  defp release do
    run_phase_gate!("release", release_phases(), evidence?: true, cleanup?: false)
  end

  defp commit_phases do
    env = owned_env("commit", 0)

    [
      phase("static_compile", root(), "mix", ["compile", "--warnings-as-errors"], env),
      phase("format", root(), "mix", ["format", "--check-formatted"], env),
      phase("credo", root(), "mix", ["credo", "--strict"], env)
    ]
  end

  defp prepush_phases(partitions) do
    env = owned_env("prepush", 0)

    [
      phase("static_compile", root(), "mix", ["compile", "--warnings-as-errors"], env),
      phase("format", root(), "mix", ["format", "--check-formatted"], env),
      phase("credo", root(), "mix", ["credo", "--strict"], env),
      phase(
        "high_coverage_fast_local",
        root(),
        "mix",
        [
          "allbert.test",
          "fast-local",
          "--core-lanes",
          "--stocksage-lanes",
          "--web-lanes",
          "--partitions",
          to_string(partitions)
        ],
        env
      )
    ]
  end

  defp release_phases do
    env = owned_env("release", 0)

    [
      phase("static_compile", root(), "mix", ["compile", "--warnings-as-errors"], env),
      phase("deps_unused", root(), "mix", ["deps.unlock", "--unused"], env),
      phase("format", root(), "mix", ["format", "--check-formatted"], env),
      phase("credo", root(), "mix", ["credo", "--strict"], env),
      phase("core_tests", app_cwd(:core), "mix", ["test"], env),
      phase("web_tests", app_cwd(:web), "mix", ["test"], env),
      phase(
        "stocksage_tests",
        app_cwd(:core),
        "mix",
        ["test", "../../plugins/stocksage/test/stocksage", "../../plugins/stocksage/test/mix"],
        env
      ),
      phase(
        "channel_plugin_tests",
        app_cwd(:core),
        "mix",
        [
          "test",
          "../../plugins/allbert.telegram/test",
          "../../plugins/allbert.email/test",
          "../../plugins/allbert.notes_files/test"
        ],
        env
      ),
      phase("dialyzer", root(), "mix", ["dialyzer"], env)
    ]
  end

  defp phase(id, cwd, executable, args, env) do
    %{
      id: id,
      cwd: cwd,
      executable: executable,
      args: args,
      env: env
    }
  end

  defp run_phase_gate!(gate, phases, opts) do
    env = phases |> List.first(%{}) |> Map.get(:env, [])

    try do
      PhaseRunner.run_gate!(
        gate,
        phases,
        Keyword.merge(opts, env: env)
      )
    after
      if Keyword.get(opts, :cleanup?, true) do
        cleanup_owned_env(env)
      end
    end
  end

  defp changed_files do
    with {unstaged, 0} <- System.cmd("git", ["diff", "--name-only"], cd: root()),
         {staged, 0} <- System.cmd("git", ["diff", "--cached", "--name-only"], cd: root()) do
      files =
        (String.split(unstaged, "\n", trim: true) ++ String.split(staged, "\n", trim: true))
        |> Enum.uniq()

      {:ok, files}
    else
      {output, status} -> {:error, "git diff exited #{status}: #{String.trim(output)}"}
    end
  end

  defp docs_path?(path) do
    String.starts_with?(path, "docs/") or
      path in ["README.md", "CHANGELOG.md", "DEVELOPMENT.md", "AGENTS.md"] or
      String.ends_with?(path, ".md")
  end

  defp print_commit_guidance(files) do
    Mix.shell().info("commit gate is not release evidence")

    files
    |> Enum.map(&owner/1)
    |> Enum.reject(&(&1 == :unknown))
    |> Enum.uniq()
    |> case do
      [] ->
        Mix.shell().info("next: run focused tests named by the active plan")

      owners ->
        Mix.shell().info("changed owners=#{Enum.map_join(owners, ",", &Atom.to_string/1)}")
        Mix.shell().info("next: run focused tests named by the active plan")
    end

    Mix.shell().info("before sharing: mix allbert.test prepush")
    Mix.shell().info("before release handoff: mix allbert.test release")
  end

  @release_v042_steps [
    %{
      id: "migrate",
      title: "prepare disposable database",
      cwd: :core,
      executable: "mix",
      args: ["ecto.migrate.allbert", "--quiet"],
      coverage: ["schema boot", "release-owned DATABASE_PATH"]
    },
    %{
      id: "core_discovery_connect_eval",
      title: "discovery, connect, trust baseline, panels, and evals",
      cwd: :core,
      executable: "mix",
      args: [
        "test",
        "test/allbert_assist/actions/tools_actions_test.exs",
        "test/allbert_assist/actions/mcp_discovery_actions_test.exs",
        "test/allbert_assist/actions/mcp_connect_actions_test.exs",
        "test/allbert_assist/actions/mcp_actions_test.exs",
        "test/allbert_assist/mcp/client_test.exs",
        "test/allbert_assist/tools/finder_test.exs",
        "test/allbert_assist/tools/discovery_test.exs",
        "test/allbert_assist/tools/discovery_scan_test.exs",
        "test/allbert_assist/workspace/mcp_integration_panels_test.exs",
        "test/mix/tasks/allbert_mcp_test.exs",
        "test/mix/tasks/allbert_tools_test.exs",
        "test/security/v042_discovery_integration_eval_test.exs",
        "test/security/security_eval_case_test.exs"
      ],
      coverage: [
        "find_tools local and remote branches",
        "tool-discovery permission boundary",
        "denied connect writes nothing",
        "approved connect writes settings and live trust baseline",
        "same-baseline doctor pass and changed-baseline doctor failure",
        "scan run-once suggestions",
        "calendar/mail/GitHub read and effect panel nodes",
        "v0.42 security eval inventory"
      ]
    },
    %{
      id: "notes_files_reference_plugin",
      title: "notes/files read and confirmed write reference plugin",
      cwd: :core,
      executable: "mix",
      args: [
        "test",
        "../../plugins/allbert.notes_files/test/allbert_notes_files/actions_test.exs",
        "../../plugins/allbert.notes_files/test/allbert_notes_files/plugin_test.exs"
      ],
      coverage: [
        "search_notes and read_note read-only refs",
        "write_note confirmation before file write",
        "reference plugin surfaces, skills, settings, and memory namespace"
      ]
    },
    %{
      id: "workspace_integration_forms",
      title: "workspace panel forms and Approval Handoff",
      cwd: :web,
      executable: "mix",
      args: ["test", "test/allbert_assist_web/live/workspace_live_test.exs"],
      coverage: [
        "Discovery Suggestions connect affordance",
        "calendar create-event form arguments",
        "mail reply form arguments",
        "GitHub comment form arguments",
        "Approval Handoff UI"
      ]
    }
  ]

  @release_v043_steps [
    %{
      id: "migrate",
      title: "prepare disposable database",
      cwd: :core,
      executable: "mix",
      args: ["ecto.migrate.allbert", "--quiet"],
      coverage: ["schema boot", "release-owned DATABASE_PATH"]
    },
    %{
      id: "browser_actions_and_extractors",
      title: "browser actions, extractors, cache, CLI, and policy tests",
      cwd: :core,
      executable: "mix",
      args: [
        "test",
        "test/allbert_assist/settings_test.exs",
        "test/allbert_assist/plugin/registry_test.exs",
        "test/allbert_assist/actions/resource_refs_test.exs",
        "test/allbert_assist/security/permission_gate_test.exs",
        "test/allbert_assist/external/http_policy_test.exs",
        "test/allbert_assist/actions/browser_actions_test.exs",
        "test/allbert_assist/actions/browser_m3_test.exs",
        "test/allbert_assist/actions/browser_m4_test.exs",
        "test/mix/tasks/allbert_browser_test.exs"
      ],
      coverage: [
        "browser settings schema and permission floors",
        "browser:// Resource Access identity",
        "doctor, start, navigate, extract, screenshot, click, fill, download",
        "bounded HTML/markdown/text/PDF extraction",
        "browser cache and paused sweep job",
        "CLI doctor and session commands",
        "credential URL and private-host preflight denial"
      ]
    },
    %{
      id: "browser_security_eval",
      title: "v0.43 browser security eval inventory and release evals",
      cwd: :core,
      executable: "mix",
      args: [
        "test",
        "test/security/v043_browser_research_eval_test.exs",
        "test/security/security_eval_case_test.exs"
      ],
      coverage: [
        "19 v0.43 browser eval rows",
        "prompt-injection inertness for HTML comments and PDF text",
        "per-domain grant and redirect scope checks",
        "subresource policy denial",
        "fill/download deny-by-default and opt-in confirmation",
        "screenshot credential redaction",
        "ephemeral session close",
        "secret redaction"
      ]
    }
  ]

  @release_v044_steps [
    %{
      id: "migrate",
      title: "prepare disposable database",
      cwd: :core,
      executable: "mix",
      args: ["ecto.migrate.allbert", "--quiet"],
      coverage: ["schema boot", "release-owned DATABASE_PATH"]
    },
    %{
      id: "workflow_loader_actions_cli",
      title: "workflow YAML loader, schema, expander, actions, and CLI",
      cwd: :core,
      executable: "mix",
      args: [
        "test",
        "test/allbert_assist/workflows/loader_test.exs",
        "test/allbert_assist/workflows/schema_test.exs",
        "test/allbert_assist/workflows/validator_test.exs",
        "test/allbert_assist/workflows/expander_test.exs",
        "test/allbert_assist/actions/plan_build_actions_test.exs",
        "test/mix/tasks/allbert_plan_test.exs"
      ],
      coverage: [
        "workflow file discovery and bounded load",
        "schema derivation from action registry",
        "closed expression validation and rejection categories",
        "Plan Preview Contract expansion",
        "start/cancel/list/show Plan/Build actions",
        "mix allbert.plan list/show/cancel"
      ]
    },
    %{
      id: "intent_trace_workspace_panels",
      title: "Plan/Build intent routing, trace output, and workspace panels",
      cwd: :core,
      executable: "mix",
      args: [
        "test",
        "test/allbert_assist/intent/plan_build_routing_test.exs",
        "test/allbert_assist/trace_plan_build_test.exs",
        "test/allbert_assist/workspace/plan_build_panels_test.exs"
      ],
      coverage: [
        "documented intent corpus routing",
        "Plan Preview trace section",
        "Preview and RunProgress workspace panel descriptors"
      ]
    },
    %{
      id: "plan_build_liveview",
      title: "workspace Plan/Build LiveView panels and objective progress",
      cwd: :web,
      executable: "mix",
      args: [
        "test",
        "test/allbert_assist_web/live/plan_build_live_test.exs",
        "test/allbert_assist_web/live/objective_live_test.exs"
      ],
      coverage: [
        "workspace destination renders Plan/Build Preview",
        "workspace destination renders Plan Run Progress",
        "ObjectiveLive embeds RunProgress and cancel control",
        "inline delegate/subagent event visibility"
      ]
    },
    %{
      id: "plan_build_security_eval",
      title: "v0.44 Plan/Build security eval inventory and release evals",
      cwd: :core,
      executable: "mix",
      args: [
        "test",
        "test/security/v044_plan_build_eval_test.exs",
        "test/security/security_eval_case_test.exs"
      ],
      coverage: [
        "16 v0.44 Plan/Build eval rows",
        "workflow YAML rejection categories",
        "preview-not-authority and plan-start confirmation",
        "step permission floor preservation",
        "cooperative cancellation",
        "delegate-agent authority boundary",
        "secret redaction"
      ]
    }
  ]

  @release_v045_steps [
    %{
      id: "migrate",
      title: "prepare disposable database",
      cwd: :core,
      executable: "mix",
      args: ["ecto.migrate.allbert", "--quiet"],
      coverage: ["schema boot", "release-owned DATABASE_PATH"]
    },
    %{
      id: "marketplace_substrate",
      title: "settings, permission, operation classes, registry, and URI substrate",
      cwd: :core,
      executable: "mix",
      args: [
        "test",
        "test/allbert_assist/settings_test.exs",
        "test/allbert_assist/security/permission_gate_test.exs",
        "test/allbert_assist/actions/resource_refs_test.exs",
        "test/allbert_assist/actions/registry_test.exs"
      ],
      coverage: [
        "marketplace.* settings fragment and schema_version",
        ":marketplace_install permission floor",
        "marketplace operation/origin/scope classes",
        "marketplace://entry URI normalization",
        "registered marketplace action capabilities"
      ]
    },
    %{
      id: "marketplace_catalog_install_cli",
      title: "catalog, bundles, install, rollback, doctor, template metadata, and CLI",
      cwd: :core,
      executable: "mix",
      args: [
        "test",
        "test/allbert_assist/marketplace/catalog_install_test.exs",
        "test/allbert_assist/marketplace_test.exs",
        "test/allbert_assist/marketplace/templates_test.exs",
        "test/mix/tasks/allbert_marketplace_test.exs"
      ],
      coverage: [
        "shipped catalog parse and bundle hash verification",
        "disabled/untrusted install and rollback for skill/template",
        "plugin_index install rejection",
        "marketplace doctor success and failure modes",
        "workspace:create template metadata listing",
        "CLI list/show/install/installed/rollback/verify/mirror/doctor"
      ]
    },
    %{
      id: "marketplace_surface_intent",
      title: "marketplace workspace surface and intent routing",
      cwd: :core,
      executable: "mix",
      args: [
        "test",
        "test/allbert_assist/marketplace/surface_provider_test.exs",
        "test/allbert_assist/intent/marketplace_routing_test.exs"
      ],
      coverage: [
        "Marketplace Catalog surface provider",
        "workspace:marketplace destination mapping",
        "per-kind inspect/verify/install/rollback affordances",
        "Marketplace Lite phrase corpus intent routing"
      ]
    },
    %{
      id: "marketplace_workspace_liveview",
      title: "workspace marketplace and create LiveView render paths",
      cwd: :web,
      executable: "mix",
      args: [
        "test",
        "test/allbert_assist_web/live/workspace_live_test.exs:153",
        "test/allbert_assist_web/live/workspace_live_test.exs:736"
      ],
      coverage: [
        "workspace Marketplace Catalog panel render",
        "panel action event dispatch allowlist",
        "workspace:create installed marketplace template metadata"
      ]
    },
    %{
      id: "marketplace_security_eval",
      title: "v0.45 marketplace security eval inventory and release evals",
      cwd: :core,
      executable: "mix",
      args: [
        "test",
        "test/security/v045_marketplace_eval_test.exs",
        "test/security/security_eval_case_test.exs"
      ],
      coverage: [
        "20 v0.45 Marketplace Lite eval rows",
        "disabled/untrusted install invariants",
        "hash/schema/path/install-target fail-closed checks",
        "workflow YAML forward-pin and plugin_index code denial",
        "template metadata non-execution",
        "doctor orphan/tamper detection",
        "secret redaction"
      ]
    }
  ]

  defp release_v042 do
    env = owned_env("release-v042", 0)
    home = env_value(env, "ALLBERT_HOME")
    database = env_value(env, "DATABASE_PATH")
    evidence_dir = Path.join(home, "release_evidence/v042")
    File.mkdir_p!(evidence_dir)

    started_at = DateTime.utc_now()
    results = Enum.map(@release_v042_steps, &run_release_v042_step(&1, env))
    secret_scan = release_v042_secret_scan(home)

    status =
      if Enum.all?(results, &(&1.status == "passed")) and secret_scan.status == "passed" do
        "passed"
      else
        "failed"
      end

    evidence = %{
      gate: "mix allbert.test release.v042",
      version: "v0.42",
      status: status,
      generated_at: DateTime.utc_now() |> DateTime.to_iso8601(),
      started_at: DateTime.to_iso8601(started_at),
      allbert_home: home,
      database_path: database,
      evidence_dir: evidence_dir,
      external_network: "disabled; tests use Req.Test/local fixtures",
      steps: results,
      secret_scan: secret_scan
    }

    evidence_path =
      Path.join(evidence_dir, "release-v042-#{DateTime.to_unix(started_at)}.json")

    File.write!(evidence_path, Jason.encode!(evidence, pretty: true))
    Mix.shell().info("release.v042 evidence: #{evidence_path}")

    if status != "passed" do
      Mix.raise("release.v042 failed; evidence: #{evidence_path}")
    end
  end

  defp release_v043 do
    env = owned_env("release-v043", 0)
    home = env_value(env, "ALLBERT_HOME")
    database = env_value(env, "DATABASE_PATH")
    evidence_dir = Path.join(home, "release_evidence/v043")
    File.mkdir_p!(evidence_dir)

    started_at = DateTime.utc_now()
    results = Enum.map(@release_v043_steps, &run_release_v043_step(&1, env))
    secret_scan = release_v043_secret_scan(home)

    status =
      if Enum.all?(results, &(&1.status == "passed")) and secret_scan.status == "passed" do
        "passed"
      else
        "failed"
      end

    evidence = %{
      gate: "mix allbert.test release.v043",
      version: "v0.43",
      status: status,
      generated_at: DateTime.utc_now() |> DateTime.to_iso8601(),
      started_at: DateTime.to_iso8601(started_at),
      allbert_home: home,
      database_path: database,
      evidence_dir: evidence_dir,
      external_network: "disabled; tests use the browser stub driver and local fixtures",
      steps: results,
      secret_scan: secret_scan
    }

    evidence_path =
      Path.join(evidence_dir, "release-v043-#{DateTime.to_unix(started_at)}.json")

    File.write!(evidence_path, Jason.encode!(evidence, pretty: true))
    Mix.shell().info("release.v043 evidence: #{evidence_path}")

    if status != "passed" do
      Mix.raise("release.v043 failed; evidence: #{evidence_path}")
    end
  end

  defp release_v044 do
    env = owned_env("release-v044", 0)
    home = env_value(env, "ALLBERT_HOME")
    database = env_value(env, "DATABASE_PATH")
    evidence_dir = Path.join(home, "release_evidence/v044")
    File.mkdir_p!(evidence_dir)

    started_at = DateTime.utc_now()
    results = Enum.map(@release_v044_steps, &run_release_v044_step(&1, env))
    secret_scan = release_v044_secret_scan(home)

    status =
      if Enum.all?(results, &(&1.status == "passed")) and secret_scan.status == "passed" do
        "passed"
      else
        "failed"
      end

    evidence = %{
      gate: "mix allbert.test release.v044",
      version: "v0.44",
      status: status,
      generated_at: DateTime.utc_now() |> DateTime.to_iso8601(),
      started_at: DateTime.to_iso8601(started_at),
      allbert_home: home,
      database_path: database,
      evidence_dir: evidence_dir,
      external_network: "disabled; tests use fixture workflows and local runtime only",
      steps: results,
      secret_scan: secret_scan
    }

    evidence_path =
      Path.join(evidence_dir, "release-v044-#{DateTime.to_unix(started_at)}.json")

    File.write!(evidence_path, Jason.encode!(evidence, pretty: true))
    Mix.shell().info("release.v044 evidence: #{evidence_path}")

    if status != "passed" do
      Mix.raise("release.v044 failed; evidence: #{evidence_path}")
    end
  end

  defp release_v045 do
    env = owned_env("release-v045", 0)
    home = env_value(env, "ALLBERT_HOME")
    database = env_value(env, "DATABASE_PATH")
    evidence_dir = Path.join(home, "release_evidence/v045")
    File.mkdir_p!(evidence_dir)

    started_at = DateTime.utc_now()
    results = Enum.map(@release_v045_steps, &run_release_v045_step(&1, env))
    secret_scan = release_v045_secret_scan(home)

    status =
      if Enum.all?(results, &(&1.status == "passed")) and secret_scan.status == "passed" do
        "passed"
      else
        "failed"
      end

    evidence = %{
      gate: "mix allbert.test release.v045",
      version: "v0.45",
      status: status,
      generated_at: DateTime.utc_now() |> DateTime.to_iso8601(),
      started_at: DateTime.to_iso8601(started_at),
      allbert_home: home,
      database_path: database,
      evidence_dir: evidence_dir,
      external_network: "disabled; tests use shipped catalog fixtures and local runtime only",
      steps: results,
      secret_scan: secret_scan
    }

    evidence_path =
      Path.join(evidence_dir, "release-v045-#{DateTime.to_unix(started_at)}.json")

    File.write!(evidence_path, Jason.encode!(evidence, pretty: true))
    Mix.shell().info("release.v045 evidence: #{evidence_path}")

    if status != "passed" do
      Mix.raise("release.v045 failed; evidence: #{evidence_path}")
    end
  end

  defp run_release_v045_step(step, env) do
    started = System.monotonic_time(:millisecond)
    cwd = release_step_cwd(step.cwd)

    {output, exit_status} =
      System.cmd(step.executable, step.args,
        cd: cwd,
        env: env,
        stderr_to_stdout: true
      )

    duration_ms = System.monotonic_time(:millisecond) - started
    print_output("release.v045 #{step.id}", output)

    %{
      id: step.id,
      title: step.title,
      status: if(exit_status == 0, do: "passed", else: "failed"),
      exit_status: exit_status,
      duration_ms: duration_ms,
      cwd: Path.relative_to(cwd, root()),
      command: shell_join([step.executable | step.args]),
      coverage: step.coverage,
      output_sha256: sha256(output),
      redacted_output_tail: output |> redact_release_output() |> tail(12_000)
    }
  end

  defp run_release_v044_step(step, env) do
    started = System.monotonic_time(:millisecond)
    cwd = release_step_cwd(step.cwd)

    {output, exit_status} =
      System.cmd(step.executable, step.args,
        cd: cwd,
        env: env,
        stderr_to_stdout: true
      )

    duration_ms = System.monotonic_time(:millisecond) - started
    print_output("release.v044 #{step.id}", output)

    %{
      id: step.id,
      title: step.title,
      status: if(exit_status == 0, do: "passed", else: "failed"),
      exit_status: exit_status,
      duration_ms: duration_ms,
      cwd: Path.relative_to(cwd, root()),
      command: shell_join([step.executable | step.args]),
      coverage: step.coverage,
      output_sha256: sha256(output),
      redacted_output_tail: output |> redact_release_output() |> tail(12_000)
    }
  end

  defp run_release_v043_step(step, env) do
    started = System.monotonic_time(:millisecond)
    cwd = release_step_cwd(step.cwd)

    {output, exit_status} =
      System.cmd(step.executable, step.args,
        cd: cwd,
        env: env,
        stderr_to_stdout: true
      )

    duration_ms = System.monotonic_time(:millisecond) - started
    print_output("release.v043 #{step.id}", output)

    %{
      id: step.id,
      title: step.title,
      status: if(exit_status == 0, do: "passed", else: "failed"),
      exit_status: exit_status,
      duration_ms: duration_ms,
      cwd: Path.relative_to(cwd, root()),
      command: shell_join([step.executable | step.args]),
      coverage: step.coverage,
      output_sha256: sha256(output),
      redacted_output_tail: output |> redact_release_output() |> tail(12_000)
    }
  end

  defp run_release_v042_step(step, env) do
    started = System.monotonic_time(:millisecond)
    cwd = release_step_cwd(step.cwd)

    {output, exit_status} =
      System.cmd(step.executable, step.args,
        cd: cwd,
        env: env,
        stderr_to_stdout: true
      )

    duration_ms = System.monotonic_time(:millisecond) - started
    print_output("release.v042 #{step.id}", output)

    %{
      id: step.id,
      title: step.title,
      status: if(exit_status == 0, do: "passed", else: "failed"),
      exit_status: exit_status,
      duration_ms: duration_ms,
      cwd: Path.relative_to(cwd, root()),
      command: shell_join([step.executable | step.args]),
      coverage: step.coverage,
      output_sha256: sha256(output),
      redacted_output_tail: output |> redact_release_output() |> tail(12_000)
    }
  end

  defp release_step_cwd(:core), do: app_cwd(:core)
  defp release_step_cwd(:web), do: app_cwd(:web)

  defp release_v042_secret_scan(home) do
    Enum.each(
      [
        Path.join(home, "settings"),
        Path.join(home, "memory/traces")
      ],
      &File.mkdir_p!/1
    )

    roots =
      [
        Path.join(home, "settings"),
        Path.join(home, "memory/traces"),
        Path.join(home, "traces")
      ]
      |> Enum.filter(&File.exists?/1)

    files =
      roots
      |> Enum.flat_map(&Path.wildcard(Path.join(&1, "**/*")))
      |> Enum.filter(&File.regular?/1)

    findings = release_v042_secret_findings(files, home)

    result = %{
      status: if(findings == [], do: "passed", else: "failed"),
      scanned_roots: Enum.map(roots, &Path.relative_to(&1, home)),
      scanned_file_count: length(files),
      findings: findings
    }

    print_output("release.v042 secret_scan", Jason.encode!(result, pretty: true))
    result
  end

  defp release_v043_secret_scan(home) do
    Enum.each(
      [
        Path.join(home, "settings"),
        Path.join(home, "memory/traces")
      ],
      &File.mkdir_p!/1
    )

    roots =
      [
        Path.join(home, "settings"),
        Path.join(home, "memory/traces"),
        Path.join(home, "traces")
      ]
      |> Enum.filter(&File.exists?/1)

    files =
      roots
      |> Enum.flat_map(&Path.wildcard(Path.join(&1, "**/*")))
      |> Enum.filter(&File.regular?/1)

    findings = release_v042_secret_findings(files, home)

    result = %{
      status: if(findings == [], do: "passed", else: "failed"),
      scanned_roots: Enum.map(roots, &Path.relative_to(&1, home)),
      scanned_file_count: length(files),
      findings: findings
    }

    print_output("release.v043 secret_scan", Jason.encode!(result, pretty: true))
    result
  end

  defp release_v044_secret_scan(home) do
    Enum.each(
      [
        Path.join(home, "settings"),
        Path.join(home, "memory/traces")
      ],
      &File.mkdir_p!/1
    )

    roots =
      [
        Path.join(home, "settings"),
        Path.join(home, "memory/traces"),
        Path.join(home, "traces")
      ]
      |> Enum.filter(&File.exists?/1)

    files =
      roots
      |> Enum.flat_map(&Path.wildcard(Path.join(&1, "**/*")))
      |> Enum.filter(&File.regular?/1)

    findings = release_v042_secret_findings(files, home)

    result = %{
      status: if(findings == [], do: "passed", else: "failed"),
      scanned_roots: Enum.map(roots, &Path.relative_to(&1, home)),
      scanned_file_count: length(files),
      findings: findings
    }

    print_output("release.v044 secret_scan", Jason.encode!(result, pretty: true))
    result
  end

  defp release_v045_secret_scan(home) do
    Enum.each(
      [
        Path.join(home, "settings"),
        Path.join(home, "memory/traces")
      ],
      &File.mkdir_p!/1
    )

    roots =
      [
        Path.join(home, "settings"),
        Path.join(home, "memory/traces"),
        Path.join(home, "traces")
      ]
      |> Enum.filter(&File.exists?/1)

    files =
      roots
      |> Enum.flat_map(&Path.wildcard(Path.join(&1, "**/*")))
      |> Enum.filter(&File.regular?/1)

    findings = release_v042_secret_findings(files, home)

    result = %{
      status: if(findings == [], do: "passed", else: "failed"),
      scanned_roots: Enum.map(roots, &Path.relative_to(&1, home)),
      scanned_file_count: length(files),
      findings: findings
    }

    print_output("release.v045 secret_scan", Jason.encode!(result, pretty: true))
    result
  end

  defp secret_patterns do
    [
      {"openai_like_key", ~r/\bsk-[A-Za-z0-9_-]{20,}\b/},
      {"github_like_token", ~r/\bgh[pousr]_[A-Za-z0-9_]{20,}\b/},
      {"slack_like_token", ~r/\bxox[baprs]-[A-Za-z0-9-]{20,}\b/},
      {"aws_access_key", ~r/\bAKIA[0-9A-Z]{16}\b/},
      {"private_key_block", ~r/-----BEGIN [A-Z ]*PRIVATE KEY-----/},
      {
        "raw_secret_assignment",
        ~r/(token|api[_-]?key|password|secret|bearer)\s*[:=]\s*(?!\[REDACTED\]|secret:\/\/)[^\s"',}]{8,}/i
      }
    ]
  end

  defp release_v042_secret_findings(files, home) do
    Enum.flat_map(files, &release_v042_secret_file_findings(&1, home))
  end

  defp release_v042_secret_file_findings(file, home) do
    content = File.read!(file)

    secret_patterns()
    |> Enum.filter(fn {_name, pattern} -> Regex.match?(pattern, content) end)
    |> Enum.map(fn {name, _pattern} -> %{file: Path.relative_to(file, home), pattern: name} end)
  end

  defp redact_release_output(output) do
    output
    |> String.replace(~r/secret:\/\/[^\s"')]+/i, "secret://[REDACTED]")
    |> String.replace(
      ~r/(token|api[_-]?key|password|secret|bearer)(["'\s:=]+)([^"'\s,}]+)/i,
      "\\1\\2[REDACTED]"
    )
  end

  defp tail(text, max_length) do
    if String.length(text) > max_length do
      "[truncated]\n" <> String.slice(text, -max_length, max_length)
    else
      text
    end
  end

  defp sha256(value) do
    :crypto.hash(:sha256, value)
    |> Base.encode16(case: :lower)
  end

  defp shell_join(parts) do
    Enum.map_join(parts, " ", &shell_quote/1)
  end

  defp shell_quote(part) do
    part = to_string(part)

    if String.match?(part, ~r|^[A-Za-z0-9_@%+=:,./-]+$|) do
      part
    else
      "'" <> String.replace(part, "'", "'\"'\"'") <> "'"
    end
  end

  defp external_smoke(args) do
    args
    |> reject_separator()
    |> run_external_smoke()
  end

  defp run_external_smoke(["list"]) do
    Mix.shell().info("external smokes are opt-in and remain serial:")
    Mix.shell().info("- browser_research")
    Mix.shell().info("- docker_sandbox")
    Mix.shell().info("- docker_full_gate")
  end

  defp run_external_smoke(["browser_research"]) do
    run_cmd!(
      "external-smoke browser_research",
      app_cwd(:core),
      "mix",
      ["test", "test/external/browser_research_smoke_test.exs"],
      [{"ALLBERT_BROWSER_EXTERNAL_SMOKE", "1"} | owned_env("external-smoke-browser-research", 0)]
    )
  end

  defp run_external_smoke(["docker_sandbox"]) do
    run_cmd!(
      "external-smoke docker_sandbox",
      app_cwd(:core),
      "mix",
      ["test", "test/allbert_assist/sandbox_test.exs", "--only", "docker_sandbox"],
      [{"ALLBERT_DOCKER_SANDBOX_TEST", "1"} | owned_env("external-smoke-docker-sandbox", 0)]
    )
  end

  defp run_external_smoke(["docker_full_gate"]) do
    run_cmd!(
      "external-smoke docker_full_gate",
      app_cwd(:core),
      "mix",
      ["test", "test/allbert_assist/sandbox_test.exs", "--only", "docker_full_gate"],
      [{"ALLBERT_DOCKER_FULL_GATE_TEST", "1"} | owned_env("external-smoke-docker-full-gate", 0)]
    )
  end

  defp run_external_smoke(args) do
    Mix.raise(
      "unknown external smoke #{Enum.join(args, " ")}; run `mix allbert.test external-smoke list`"
    )
  end

  defp run_parallel_tests!(groups) do
    groups
    |> Task.async_stream(&run_test_group/1,
      timeout: :infinity,
      max_concurrency: max(1, length(groups))
    )
    |> Enum.map(fn
      {:ok, result} -> result
      {:exit, reason} -> {:error, Exception.format_exit(reason)}
    end)
    |> print_parallel_results!()
  end

  defp run_test_group(%{label: label, owner: owner, files: files, env: env} = group) do
    capture_test_files(label, owner, files, env, Map.get(group, :raw?, false))
  end

  defp prepare_test_group!(%{prepare_label: label, env: env}) do
    run_cmd!(
      label,
      app_cwd(:core),
      "mix",
      ["ecto.migrate.allbert", "--quiet"],
      env,
      cleanup?: false
    )
  end

  defp run_test_files!(label, owner, files, env) do
    {output, status} = test_files_command(owner, files, env, false)
    print_output(label, output)

    if status != 0 do
      Mix.raise("#{label} failed with status #{status}")
    end
  end

  defp capture_test_files(label, owner, files, env, raw?) do
    {output, status} = test_files_command(owner, files, env, raw?)

    if status == 0 do
      {:ok, label, output}
    else
      {:error, label, status, output}
    end
  end

  defp test_files_command(owner, files, env, raw?) do
    try do
      cwd = app_cwd(owner)
      relative_files = Enum.map(files, &relative_test_path(&1, owner))
      task = if raw?, do: "allbert.test.raw", else: "test"
      System.cmd("mix", [task | relative_files], cd: cwd, env: env, stderr_to_stdout: true)
    after
      cleanup_owned_env(env)
    end
  end

  defp run_partition_smoke(%{label: label, env: env, partition: partition}) do
    env = [{"MIX_TEST_PARTITION", to_string(partition)} | env]

    output =
      with {migrate_output, 0} <-
             System.cmd(
               "mix",
               ["ecto.migrate.allbert", "--quiet"],
               cd: app_cwd(:core),
               env: env,
               stderr_to_stdout: true
             ),
           database_path when is_binary(database_path) <- env_value(env, "DATABASE_PATH"),
           home when is_binary(home) <- env_value(env, "ALLBERT_HOME"),
           true <- File.exists?(database_path),
           true <- String.starts_with?(database_path, home) do
        {:ok, label,
         migrate_output <>
           "partition home=#{home}\npartition database=#{database_path}\npartition smoke ok\n"}
      else
        {output, status} ->
          {:error, label, status, output}

        false ->
          {:error, label, 1, "partition smoke did not create owned database under ALLBERT_HOME\n"}
      end

    cleanup_owned_env(env)
    output
  end

  defp run_serial_partition(%{
         label: label,
         owner: owner,
         env: env,
         lane: lane,
         partitions: partitions,
         partition: partition
       }) do
    env = [{"MIX_TEST_PARTITION", to_string(partition)} | env]
    test_paths = serial_lane_paths(owner, lane)
    validate_serial_lane_paths!(owner, test_paths)

    output =
      with {migrate_output, 0} <-
             System.cmd(
               "mix",
               ["ecto.migrate.allbert", "--quiet"],
               cd: app_cwd(:core),
               env: env,
               stderr_to_stdout: true
             ),
           {test_output, status} <-
             System.cmd(
               "mix",
               [
                 "allbert.test.raw",
                 "--partitions",
                 to_string(partitions),
                 "--only",
                 Atom.to_string(lane),
                 "--max-cases",
                 "1"
               ] ++ test_paths,
               cd: app_cwd(owner),
               env: env,
               stderr_to_stdout: true
             ) do
        cond do
          status == 0 ->
            {:ok, label, migrate_output <> test_output}

          empty_partition_output?(test_output, test_paths) ->
            {:ok, label, migrate_output <> test_output}

          true ->
            {:error, label, status, migrate_output <> test_output}
        end
      else
        {output, status} -> {:error, label, status, output}
      end

    cleanup_owned_env(env)
    output
  end

  defp empty_partition_output?(output, test_paths) do
    empty_only_filter? =
      String.contains?(output, "All tests have been excluded.") and
        String.contains?(output, "The --only option was given") and
        String.contains?(output, "no test was executed")

    empty_explicit_partition? =
      test_paths != [] and
        String.contains?(output, "Paths given to \"mix test\" did not match any directory/file:")

    empty_only_filter? or empty_explicit_partition?
  end

  defp serial_lane_paths(:core, _lane), do: []

  defp serial_lane_paths(:stocksage, lane) do
    inventory_records()
    |> Enum.filter(&(&1.owner == :stocksage and &1.primary_lane == lane))
    |> Enum.map(&relative_test_path(&1.path, :stocksage))
  end

  defp serial_lane_paths(:web, lane) do
    inventory_records()
    |> Enum.filter(&(&1.owner == :web and &1.primary_lane == lane))
    |> Enum.map(&relative_test_path(&1.path, :web))
  end

  defp validate_serial_lane_paths!(owner, paths) do
    Enum.each(paths, fn path ->
      unless File.exists?(Path.expand(path, app_cwd(owner))) do
        Mix.raise("serial lane path does not exist: #{path}")
      end
    end)
  end

  defp print_parallel_results!(results) do
    failures =
      Enum.filter(results, fn
        {:ok, label, output} ->
          print_output(label, output)
          false

        {:error, label, status, output} ->
          print_output(label, output)
          Mix.shell().error("#{label} failed with status #{status}")
          true

        {:error, reason} ->
          Mix.shell().error(reason)
          true
      end)

    if failures != [] do
      Mix.raise("one or more parallel test gates failed")
    end
  end

  defp run_cmd!(label, cwd, executable, args, env, opts \\ []) do
    {output, status} = System.cmd(executable, args, cd: cwd, env: env, stderr_to_stdout: true)
    print_output(label, output)

    if Keyword.get(opts, :cleanup?, true) do
      cleanup_owned_env(env)
    end

    if status != 0 do
      cleanup_owned_env(env)
      Mix.raise("#{label} failed with status #{status}")
    end
  end

  defp print_output(label, output) do
    Mix.shell().info("==> #{label}")

    output
    |> String.trim_trailing()
    |> case do
      "" -> :ok
      text -> Mix.shell().info(text)
    end
  end

  defp fast_local_records do
    Enum.filter(inventory_records(), &(&1.primary_lane == :pure_async))
  end

  defp inventory_csv(records) do
    headers = [
      :path,
      :owner,
      :template,
      :async,
      :tags,
      :resource_classes,
      :primary_lane,
      :migration_action,
      :template_default?
    ]

    rows =
      records
      |> Enum.map(fn record ->
        Enum.map_join(headers, ",", fn key -> csv(Map.fetch!(record, key)) end)
      end)

    Enum.join([Enum.map_join(headers, ",", &csv/1)] ++ rows, "\n") <> "\n"
  end

  defp inventory_records do
    @roots
    |> Enum.flat_map(&Path.wildcard(Path.join(root(), Path.join(&1, "**/*_test.exs"))))
    |> Enum.map(&Path.relative_to(&1, root()))
    |> Enum.sort()
    |> Enum.map(&inventory_record/1)
  end

  defp inventory_record(path) do
    text = File.read!(Path.join(root(), path))
    {template, async} = template_and_async(text)
    tags = tags(text)
    resource_classes = resource_classes(path, text, template)
    primary_lane = primary_lane(path, async, template, resource_classes)

    %{
      path: path,
      owner: owner(path),
      template: template,
      async: async,
      tags: Enum.join(tags, "; "),
      resource_classes: Enum.map_join(resource_classes, ";", &Atom.to_string/1),
      primary_lane: primary_lane,
      migration_action: migration_action(primary_lane, async),
      template_default?: if(Map.has_key?(@template_defaults, template), do: "yes", else: "no")
    }
  end

  defp check_lane_tags!(records) do
    issues =
      records
      |> Enum.flat_map(&lane_reconciliation_issue/1)

    if issues != [] do
      Mix.raise("""
      lane reconciliation failed:
      #{Enum.map_join(issues, "\n", &"  - #{&1}")}
      """)
    end

    Mix.shell().info(
      "lane reconciliation ok: #{length(records)} files, zero unclassified, zero double-counts"
    )
  end

  defp lane_reconciliation_issue(%{path: path, template: template, primary_lane: expected}) do
    text = File.read!(Path.join(root(), path))
    actual = actual_primary_lane_tags(text, template)

    cond do
      actual == [expected] ->
        []

      actual == [] ->
        ["#{path}: expected @moduletag :#{expected}, found no primary lane tag"]

      length(actual) > 1 ->
        [
          "#{path}: expected one primary lane tag :#{expected}, found #{Enum.map_join(actual, ", ", &":#{&1}")}"
        ]

      true ->
        ["#{path}: expected primary lane :#{expected}, found :#{hd(actual)}"]
    end
  end

  defp actual_primary_lane_tags(text, template) do
    template_tags =
      case Map.fetch(@template_defaults, template) do
        {:ok, default} -> [use_line_lane(text) || default]
        :error -> []
      end

    (template_tags ++ explicit_primary_lane_tags(text))
    |> Enum.uniq()
  end

  defp explicit_primary_lane_tags(text) do
    ~r/@moduletag\s+:([a-z_]+)\b/
    |> Regex.scan(text)
    |> Enum.map(fn [_, tag] -> parse_lane_tag(tag) end)
    |> Enum.reject(&is_nil/1)
  end

  defp use_line_lane(text) do
    with line when is_binary(line) <- top_level_use_line(text),
         [_, lane] <- Regex.run(~r/lane:\s*:([a-z_]+)\b/, line) do
      parse_lane_tag(lane)
    else
      _other -> nil
    end
  end

  defp parse_lane_tag(tag) do
    Enum.find(@lanes, &(Atom.to_string(&1) == tag))
  end

  defp template_and_async(text) do
    case top_level_use_line(text) do
      nil ->
        {"unknown", "unspecified"}

      line ->
        template_and_async_from_line(line)
    end
  end

  defp template_and_async_from_line(line) do
    case Regex.run(~r/use\s+([A-Za-z0-9_.]+)\s*,\s*async:\s*(true|false)/, line) do
      [_, template, async] ->
        {template, async}

      nil ->
        case Regex.run(~r/use\s+([A-Za-z0-9_.]+)/, line) do
          [_, template] -> {template, "unspecified"}
          nil -> {"unknown", "unspecified"}
        end
    end
  end

  defp top_level_use_line(text) do
    text
    |> String.split("\n")
    |> Enum.find(&String.match?(&1, ~r/^  use\s+[A-Za-z0-9_.]+/))
  end

  defp tags(text) do
    ~r/@(?:module)?tag\s+([^\n]+)/
    |> Regex.scan(text)
    |> Enum.map(fn [_, tag] -> String.trim(tag) end)
  end

  defp resource_classes(path, text, template) do
    [
      {:db, db_resource?(text, template)},
      {:security_eval, security_eval_resource?(path, template)},
      {:liveview, liveview_resource?(path, text, template)},
      {:app_env, app_env_resource?(text)},
      {:home_fs, home_fs_resource?(text)},
      {:global_process, global_process_resource?(text)},
      {:external_runtime, external_runtime_resource?(text)}
    ]
    |> Enum.filter(fn {_class, present?} -> present? end)
    |> Enum.map(fn {class, _present?} -> class end)
  end

  defp db_resource?(text, template),
    do: template =~ "DataCase" or text =~ "Repo" or text =~ "Ecto."

  defp security_eval_resource?(path, template) do
    String.contains?(path, "/test/security/") or template =~ "SecurityEvalCase"
  end

  defp liveview_resource?(path, text, template) do
    owner(path) == :web and
      (template =~ "ConnCase" or String.contains?(path, "/live/") or text =~ "live(" or
         text =~ "live_isolated")
  end

  defp app_env_resource?(text) do
    text =~ "Application.put_env" or text =~ "Application.delete_env" or text =~ "System.put_env" or
      text =~ "System.delete_env"
  end

  defp home_fs_resource?(text) do
    text =~ "ALLBERT_HOME" or text =~ "ALLBERT_HOME_DIR" or text =~ "DATABASE_PATH" or
      text =~ "File.rm_rf" or text =~ "System.tmp_dir" or text =~ "tmp"
  end

  defp global_process_resource?(text) do
    text =~ "start_supervised" or text =~ "GenServer" or text =~ "Agent" or
      text =~ "Supervisor" or
      text =~ "Registry" or text =~ "PubSub" or text =~ "Process.register"
  end

  defp external_runtime_resource?(text) do
    text =~ "System.cmd" or text =~ "Port." or text =~ "docker" or text =~ "MCP" or
      text =~ "Req.Test" or
      text =~ "TraderBridge" or text =~ "bridge"
  end

  defp primary_lane(_path, async, template, classes) do
    resource_lane(classes) ||
      template_lane(template) ||
      async_lane(async) ||
      :global_process_serial
  end

  defp resource_lane(classes) do
    [
      security_eval: :security_eval_serial,
      external_runtime: :external_runtime_serial,
      liveview: :liveview_serial,
      db: :db_serial,
      app_env: :app_env_serial,
      home_fs: :home_fs_serial,
      global_process: :global_process_serial
    ]
    |> Enum.find_value(fn {class, lane} ->
      if class in classes, do: lane
    end)
  end

  defp template_lane(template), do: Map.get(@template_defaults, template)
  defp async_lane("true"), do: :pure_async
  defp async_lane(_async), do: nil

  defp migration_action(:pure_async, "true"), do: "already_async"
  defp migration_action(:pure_async, _async), do: "pure_async_candidate"
  defp migration_action(:db_serial, _async), do: "needs_partition_database"

  defp migration_action(lane, _async)
       when lane in [:app_env_serial, :home_fs_serial, :global_process_serial, :liveview_serial],
       do: "needs_partition_isolation"

  defp migration_action(:external_runtime_serial, _async), do: "external_smoke_or_serial"
  defp migration_action(:security_eval_serial, _async), do: "must_remain_serial"

  defp csv(value) do
    value = value |> to_string() |> String.replace("\n", " ")
    "\"" <> String.replace(value, "\"", "\"\"") <> "\""
  end

  defp group_files(files) do
    files
    |> Enum.group_by(&owner/1)
    |> Enum.reject(fn {_owner, grouped} -> grouped == [] end)
  end

  defp owner(path) do
    cond do
      String.starts_with?(path, "apps/allbert_assist_web/") -> :web
      String.starts_with?(path, "apps/allbert_assist/") -> :core
      String.starts_with?(path, "plugins/stocksage/") -> :stocksage
      String.starts_with?(path, "plugins/allbert.telegram/") -> :telegram
      String.starts_with?(path, "plugins/allbert.email/") -> :email
      String.starts_with?(path, "plugins/allbert.notes_files/") -> :notes_files
      true -> :unknown
    end
  end

  defp app_cwd(owner) when owner in [:core, :stocksage, :telegram, :email, :notes_files] do
    Path.join(root(), "apps/allbert_assist")
  end

  defp app_cwd(:web), do: Path.join(root(), "apps/allbert_assist_web")

  defp relative_test_path(path, :core),
    do: String.replace_prefix(path, "apps/allbert_assist/", "")

  defp relative_test_path(path, :web),
    do: String.replace_prefix(path, "apps/allbert_assist_web/", "")

  defp relative_test_path(path, _owner),
    do: Path.relative_to(Path.join(root(), path), app_cwd(:core))

  defp owned_env(lane, partition) do
    root_path =
      Path.join([
        System.tmp_dir!(),
        "allbert_test_gates",
        safe_segment(lane),
        "p#{partition}-#{System.unique_integer([:positive])}"
      ])

    home = Path.join(root_path, "home")
    database = Path.join([home, "db", "allbert_test.db"])
    File.mkdir_p!(Path.dirname(database))

    [
      {"MIX_ENV", "test"},
      {"ALLBERT_HOME", home},
      {"ALLBERT_HOME_DIR", home},
      {"DATABASE_PATH", database},
      {"ALLBERT_TEST_GATE_ROOT", root_path}
    ]
  end

  defp cleanup_owned_env(env) do
    if System.get_env("ALLBERT_TEST_KEEP_TMP") not in ["1", "true"] do
      case env_value(env, "ALLBERT_TEST_GATE_ROOT") do
        nil -> :ok
        path -> File.rm_rf(path)
      end
    end
  end

  defp env_value(env, key) do
    env
    |> Enum.find_value(fn
      {^key, value} -> value
      _other -> nil
    end)
  end

  defp safe_segment(value) do
    value
    |> to_string()
    |> String.replace(~r/[^A-Za-z0-9_.-]+/, "-")
  end

  defp parse_lane!(nil), do: Mix.raise("serial-core requires --lane")

  defp parse_lane!(lane) do
    case Enum.find(@lanes, &(Atom.to_string(&1) == lane)) do
      nil -> Mix.raise("unknown lane #{lane}; expected one of #{Enum.join(@lanes, ", ")}")
      lane -> lane
    end
  end

  defp validate_partitions!(partitions) when is_integer(partitions) and partitions > 0, do: :ok
  defp validate_partitions!(_partitions), do: Mix.raise("--partitions must be a positive integer")

  defp default_partition_count do
    System.schedulers_online()
    |> min(4)
    |> max(1)
  end

  defp reject_invalid!([]), do: :ok
  defp reject_invalid!(invalid), do: Mix.raise("invalid option(s): #{inspect(invalid)}")

  defp reject_rest!([]), do: :ok
  defp reject_rest!(rest), do: Mix.raise("unexpected argument(s): #{Enum.join(rest, " ")}")

  defp reject_separator(["--" | rest]), do: rest
  defp reject_separator(rest), do: rest

  defp root do
    Path.expand("../../../../..", __DIR__)
  end

  @spec usage!() :: no_return()
  defp usage! do
    Mix.raise("""
    Usage:
      mix allbert.test docs
      mix allbert.test inventory [--output PATH] [--check-tags]
      mix allbert.test focused -- FILE [FILE...]
      mix allbert.test commit
      mix allbert.test prepush [--partitions N]
      mix allbert.test fast-local [--core-lanes] [--stocksage-lanes] [--web-lanes] [--partitions N]
      mix allbert.test partition-smoke [--partitions N]
      mix allbert.test serial-core --lane LANE [--partitions N]
      mix allbert.test release
      mix allbert.test release.v042
      mix allbert.test release.v043
      mix allbert.test release.v044
      mix allbert.test release.v045
      mix allbert.test external-smoke list
      mix allbert.test external-smoke -- browser_research
      mix allbert.test external-smoke -- docker_sandbox
      mix allbert.test external-smoke -- docker_full_gate

    `mix precommit` is a compatibility shortcut for `mix allbert.test commit`;
    release evidence is `mix allbert.test release`.
    """)
  end
end
