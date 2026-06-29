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
      mix allbert.test param-contract-sweep
      mix allbert.test release
      mix allbert.test release.v042
      mix allbert.test release.v043
      mix allbert.test release.v044
      mix allbert.test release.v045
      mix allbert.test release.v046
      mix allbert.test release.v047
      mix allbert.test release.v047b
      mix allbert.test release.v048
      mix allbert.test release.v049
      mix allbert.test release.v050
      mix allbert.test release.v050b
      mix allbert.test release.v051
      mix allbert.test release.v052
      mix allbert.test release.v053
      mix allbert.test release.v054
      mix allbert.test release.v055
      mix allbert.test release.v0551
      mix allbert.test release.v056
      mix allbert.test release.v057
      mix allbert.test release.v058
      mix allbert.test release.v059
      mix allbert.test external-smoke list
      mix allbert.test external-smoke -- browser_research
      mix allbert.test external-smoke -- browser_research_delegate
      mix allbert.test external-smoke -- docker_sandbox
      mix allbert.test external-smoke -- docker_full_gate
      mix allbert.test external-smoke -- telegram
      mix allbert.test external-smoke -- email
      mix allbert.test external-smoke -- inbound_telegram
      mix allbert.test external-smoke -- inbound_email
      mix allbert.test external-smoke -- matrix
      mix allbert.test external-smoke -- inbound_matrix
      mix allbert.test external-smoke -- whatsapp
      mix allbert.test external-smoke -- signal
      mix allbert.test external-smoke -- discord
      mix allbert.test external-smoke -- slack
      mix allbert.test external-smoke -- inbound_discord
      mix allbert.test external-smoke -- inbound_slack

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
    "plugins/allbert.email/test",
    "plugins/allbert.discord/test",
    "plugins/allbert.slack/test",
    "plugins/allbert.matrix/test",
    "plugins/allbert.whatsapp/test",
    "plugins/allbert.signal/test"
  ]

  @template_defaults %{
    "AllbertAssist.DataCase" => :db_serial,
    "AllbertAssistWeb.ConnCase" => :liveview_serial,
    "AllbertAssist.SecurityEvalCase" => :security_eval_serial,
    "StockSage.DataCase" => :db_serial
  }

  @owner_prefixes [
    {"apps/allbert_assist_web/", :web},
    {"apps/allbert_assist/", :core},
    {"plugins/stocksage/", :stocksage},
    {"plugins/allbert.telegram/", :telegram},
    {"plugins/allbert.email/", :email},
    {"plugins/allbert.discord/", :discord},
    {"plugins/allbert.slack/", :slack},
    {"plugins/allbert.matrix/", :matrix},
    {"plugins/allbert.whatsapp/", :whatsapp},
    {"plugins/allbert.signal/", :signal},
    {"plugins/allbert.notes_files/", :notes_files}
  ]

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
  def run(["param-contract-sweep"]), do: param_contract_sweep()
  def run(["release"]), do: release()
  def run(["release.v042"]), do: release_v042()
  def run(["release.v043"]), do: release_v043()
  def run(["release.v044"]), do: release_v044()
  def run(["release.v045"]), do: release_v045()
  def run(["release.v046"]), do: release_v046()
  def run(["release.v047"]), do: release_v047()
  def run(["release.v047b"]), do: release_v047b()
  def run(["release.v048"]), do: release_v048()
  def run(["release.v049"]), do: release_v049()
  def run(["release.v050"]), do: release_v050()
  def run(["release.v050b"]), do: release_v050b()
  def run(["release.v051"]), do: release_v051()
  def run(["release.v052"]), do: release_v052()
  def run(["release.v053"]), do: release_v053()
  def run(["release.v054"]), do: release_v054()
  def run(["release.v055"]), do: release_v055()
  def run(["release.v0551"]), do: release_v0551()
  def run(["release.v056"]), do: release_v056()
  def run(["release.v057"]), do: release_v057()
  def run(["release.v058"]), do: release_v058()
  def run(["release.v059"]), do: release_v059()
  def run(["external-smoke" | rest]), do: external_smoke(rest)
  def run(_args), do: usage!()

  defp docs do
    run_cmd!("docs", root(), "git", ["diff", "--check"], [])
    :ok
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

  defp param_contract_sweep do
    env = owned_env("param-contract-sweep", 0)

    run_cmd!(
      "param-contract-sweep",
      root(),
      "mix",
      [
        "test",
        "apps/allbert_assist/test/allbert_assist/actions/param_contract_test.exs",
        "apps/allbert_assist/test/security/v059_sweep_eval_test.exs",
        "--only",
        "param_contract"
      ],
      env
    )
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
    partitions = default_partition_count()

    [
      phase("static_compile", root(), "mix", ["compile", "--warnings-as-errors"], env),
      phase("deps_unused", root(), "mix", ["deps.unlock", "--unused"], env),
      phase("format", root(), "mix", ["format", "--check-formatted"], env),
      phase("credo", root(), "mix", ["credo", "--strict"], env),
      # Core partition-safe lanes (pure_async + db/app_env/home_fs/global_process)
      # run in ISOLATED partitions, exactly as prepush does. This is the flakiness
      # root-cause fix: tests that mutate global singletons (App.Registry, Settings
      # Central, PluginRegistry) — intent/engine_test, skills/registry_test,
      # browser_actions_test — run serially inside an isolated home/DB instead of
      # racing in one concurrent `mix test`. async_groups also covers every owner's
      # pure_async files.
      phase(
        "high_coverage_fast_local",
        root(),
        "mix",
        ["allbert.test", "fast-local", "--core-lanes", "--partitions", to_string(partitions)],
        env
      ),
      # external_runtime_serial / security_eval_serial are not partition-safe
      # (serial_core/1 forces a single VM); run each as a single-VM serial lane.
      phase(
        "core_external_runtime_serial",
        root(),
        "mix",
        ["allbert.test", "serial-core", "--lane", "external_runtime_serial"],
        env
      ),
      phase(
        "core_security_eval_serial",
        root(),
        "mix",
        ["allbert.test", "serial-core", "--lane", "security_eval_serial"],
        env
      ),
      # web / stocksage / channel-plugin suites keep their existing plain `mix test`
      # coverage. These owners are not churn sources; the web LiveView timeout
      # flakes are addressed by the enlarged test pool_size.
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
          "../../plugins/allbert.discord/test",
          "../../plugins/allbert.slack/test",
          "../../plugins/allbert.matrix/test",
          "../../plugins/allbert.whatsapp/test",
          "../../plugins/allbert.signal/test",
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
    case Application.get_env(:allbert_assist, :gate_changed_files) do
      fun when is_function(fun, 0) -> fun.()
      files when is_list(files) -> {:ok, files}
      nil -> changed_files_from_git()
    end
  end

  defp changed_files_from_git do
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

  @release_v046_steps [
    %{
      id: "migrate",
      title: "prepare disposable database",
      cwd: :core,
      executable: "mix",
      args: ["ecto.migrate.allbert", "--quiet"],
      coverage: ["schema boot", "release-owned DATABASE_PATH"]
    },
    %{
      id: "delegate_research_core",
      title: "delegate action contract, research runtime, and CLI",
      cwd: :core,
      executable: "mix",
      args: [
        "test",
        "test/allbert_assist/actions/objectives/delegate_agent_test.exs",
        "test/allbert_assist/actions/research_delegate_test.exs",
        "test/mix/tasks/allbert_research_test.exs"
      ],
      coverage: [
        "delegate_agent command allowlist and metadata dispatch",
        "research.specialist advisory metadata and browser orchestration",
        "CLI objective creation, completed observation, blocked confirmation handoff"
      ]
    },
    %{
      id: "intent_plan_build_research",
      title: "research intent descriptors and Plan/Build workflow fixture",
      cwd: :core,
      executable: "mix",
      args: [
        "test",
        "test/allbert_assist/intent/research_descriptor_test.exs",
        "test/allbert_assist/workflows/expander_test.exs"
      ],
      coverage: [
        "locked research phrase corpus routes to inert research descriptors",
        "browser handoff no longer owns v0.46 research phrases",
        "research_delegate workflow fixture expands to delegate_agent step"
      ]
    },
    %{
      id: "research_workspace_web",
      title: "workspace Plan/Build inline delegate rendering",
      cwd: :web,
      executable: "mix",
      args: ["test", "test/allbert_assist_web/live/plan_build_live_test.exs"],
      coverage: [
        "Plan/Build progress renders research.specialist child events inline",
        "existing Plan/Build panels remain renderable"
      ]
    },
    %{
      id: "research_security_eval",
      title: "v0.46 research delegate security eval inventory and release evals",
      cwd: :core,
      executable: "mix",
      args: [
        "test",
        "test/security/v046_research_delegate_eval_test.exs",
        "test/security/v043_browser_research_eval_test.exs",
        "test/security/security_eval_case_test.exs"
      ],
      coverage: [
        "9 v0.46 research delegate eval rows",
        "navigation confirmation and browser grant scope inheritance",
        "advisory output and no memory auto-promotion",
        "max_sources cap and browser session cleanup",
        "delegate-agent isolation and objective-path command allowlist",
        "v0.43 browser security floor regression"
      ]
    }
  ]

  @release_v047_steps [
    %{
      id: "migrate",
      title: "prepare disposable database",
      cwd: :core,
      executable: "mix",
      args: ["ecto.migrate.allbert", "--quiet"],
      coverage: ["schema boot", "release-owned DATABASE_PATH"]
    },
    %{
      id: "self_improvement_core",
      title: "trace index, discovery, drafts, promotion actions, and CLI",
      cwd: :core,
      executable: "mix",
      args: [
        "test",
        "test/allbert_assist/self_improvement/trace_index_test.exs",
        "test/allbert_assist/actions/self_improvement_actions_test.exs",
        "test/allbert_assist/actions/self_improvement_draft_actions_test.exs",
        "test/allbert_assist/actions/self_improvement_promotion_actions_test.exs",
        "test/allbert_assist/drafts/store_test.exs",
        "test/allbert_assist/intent/self_improvement_routing_test.exs",
        "test/mix/tasks/allbert_self_improvement_test.exs"
      ],
      coverage: [
        "self_improvement settings and trace-index redaction",
        "read-only discover_patterns action and intent phrase corpus",
        "unified draft-store kind coverage",
        "skill/workflow/memory draft-only behavior",
        "confirmation-gated promotion writes live artifacts only on approval",
        "self-improvement CLI list/inspect/discard surfaces"
      ]
    },
    %{
      id: "self_improvement_surface",
      title: "passive discovery suggestion workspace surface",
      cwd: :core,
      executable: "mix",
      args: [
        "test",
        "test/allbert_assist/tools/discovery_test.exs",
        "test/allbert_assist/workspace/discovery_suggestions_test.exs"
      ],
      coverage: [
        "generalized v0.42 suggestion lifecycle for self-improvement rows",
        "passive workspace rendering without MCP Connect authority"
      ]
    },
    %{
      id: "self_improvement_security_eval",
      title: "v0.47 operator-supervised self-improvement security evals",
      cwd: :core,
      executable: "mix",
      args: [
        "test",
        "test/security/v047_self_improvement_eval_test.exs",
        "test/security/security_eval_case_test.exs"
      ],
      coverage: [
        "7 v0.47 operator-supervised self-improvement eval rows",
        "read-only trace scan and advisory suggestions",
        "disabled/untrusted and draft-only facades",
        "redacted trace-index samples",
        "promotion confirmation required and denial writes nothing"
      ]
    }
  ]

  @release_v047b_steps [
    %{
      id: "migrate",
      title: "prepare disposable database",
      cwd: :core,
      executable: "mix",
      args: ["ecto.migrate.allbert", "--quiet"],
      coverage: ["schema boot", "release-owned DATABASE_PATH"]
    },
    %{
      id: "self_improvement_handoff_core",
      title: "handoff draft kinds, promotion actions, registry, and CLI-adjacent surfaces",
      cwd: :core,
      executable: "mix",
      args: [
        "test",
        "test/allbert_assist/drafts/store_test.exs",
        "test/allbert_assist/actions/self_improvement_draft_actions_test.exs",
        "test/allbert_assist/actions/self_improvement_promotion_actions_test.exs",
        "test/allbert_assist/tools/discovery_test.exs",
        "test/allbert_assist/actions/registry_test.exs"
      ],
      coverage: [
        "template-backed, marketplace-backed, delegate-plugin, capability-gap, and objective draft kinds",
        "template and capability-gap promotion to inert v0.37 dynamic drafts",
        "objective promotion confirmation",
        "registered self-improvement handoff actions and suggestion kinds"
      ]
    },
    %{
      id: "self_improvement_dynamic_gate",
      title: "dynamic code handoff gate and loader confirmation boundary",
      cwd: :core,
      executable: "mix",
      args: [
        "test",
        "test/allbert_assist/dynamic_plugins/codegen_test.exs:392",
        "test/allbert_assist/dynamic_plugins/loader_test.exs"
      ],
      coverage: [
        "code-bearing draft gate path remains v0.36/v0.37",
        "ungated dynamic drafts cannot request integration confirmation",
        "gate-passed drafts require confirmation before live integration",
        "rollback remains available for integrated dynamic actions"
      ]
    },
    %{
      id: "self_improvement_handoff_security_eval",
      title: "v0.47b operator-supervised self-improvement handoff security evals",
      cwd: :core,
      executable: "mix",
      args: [
        "test",
        "test/security/v047b_self_improvement_eval_test.exs",
        "test/security/security_eval_case_test.exs"
      ],
      coverage: [
        "7 v0.47b operator-supervised self-improvement eval rows",
        "marketplace/template/delegate handoff drafts remain inert",
        "capability-gap dynamic draft handoff requires gate evidence",
        "gate-passed dynamic integration still requires operator confirmation",
        "marketplace actions remain separately confirmation-gated"
      ]
    }
  ]

  @release_v048_steps [
    %{
      id: "migrate",
      title: "prepare disposable database",
      cwd: :core,
      executable: "mix",
      args: ["ecto.migrate.allbert", "--quiet"],
      coverage: ["schema boot", "release-owned DATABASE_PATH"]
    },
    %{
      id: "provider_capability_core",
      title: "provider capability metadata, preferences, doctors, and audio policy",
      cwd: :core,
      executable: "mix",
      args: [
        "test",
        "test/allbert_assist/settings/provider_catalog_test.exs",
        "test/allbert_assist/settings/model_preferences_test.exs",
        "test/allbert_assist/actions/voice_provider_doctor_test.exs",
        "test/allbert_assist/resources/resource_uri_test.exs",
        "test/allbert_assist/resources/operation_class_test.exs",
        "test/allbert_assist/security/permission_gate_test.exs",
        "test/allbert_assist/runtime/redactor_test.exs",
        "test/allbert_assist/voice/provider_adapter_test.exs",
        "test/allbert_assist/voice/transcode_test.exs",
        "test/allbert_assist/voice/local_runtime_test.exs",
        "test/allbert_assist/actions/voice_local_runtime_test.exs"
      ],
      coverage: [
        "capability-aware provider catalog and ranked preference fallback",
        "voice adapter behaviour, real local/remote fixture paths, and fail-closed bundled-local stub",
        "Allbert-owned local voice runtime router/auth/backend contract and lifecycle actions",
        "ADR 0047 voice doctor fields",
        "mic:// audio resource identity and voice operation classes",
        "voice permission floors and remote-upload confirmation posture",
        "audio redaction and bounded transcode specs"
      ]
    },
    %{
      id: "voice_actions_cli_channel",
      title: "registered voice actions, CLI file STT/TTS, and Telegram voice notes",
      cwd: :core,
      executable: "mix",
      args: [
        "test",
        "test/allbert_assist/actions/transcribe_voice_test.exs",
        "test/allbert_assist/actions/synthesize_voice_test.exs",
        "test/allbert_assist/actions/registry_test.exs",
        "test/mix/tasks/allbert_ask_test.exs",
        "test/allbert_assist/channels/telegram_test.exs"
      ],
      coverage: [
        "transcribe_voice and synthesize_voice action routing with fixture providers",
        "stable action registry metadata",
        "mix allbert.ask --voice fixture transcription",
        "Telegram getFile/download voice-note ingestion through shared STT action"
      ]
    },
    %{
      id: "workspace_voice",
      title: "workspace microphone confirmation, upload, and transcript handoff",
      cwd: :web,
      executable: "mix",
      args: ["test", "test/allbert_assist_web/live/workspace_live_test.exs"],
      coverage: [
        "workspace capture confirmation state",
        "approved LiveView upload to transcribe_voice",
        "denial writes no audio resource"
      ]
    },
    %{
      id: "voice_security_eval",
      title: "v0.48 voice modality security eval inventory and release evals",
      cwd: :core,
      executable: "mix",
      args: [
        "test",
        "test/security/v048_voice_modality_eval_test.exs",
        "test/security/security_eval_case_test.exs",
        "test/mix/tasks/allbert_test_task_test.exs"
      ],
      coverage: [
        "16 v0.48 voice modality eval rows",
        "release.v048 task usage registration",
        "provider capability metadata has no authority",
        "file, microphone, retention, redaction, and transcode bounds",
        "remote STT/TTS upload confirmation posture",
        "TTS usage/cost metadata display-only",
        "Telegram channel boundary delegates STT to registered actions"
      ]
    }
  ]

  @release_v049_steps [
    %{
      id: "migrate",
      title: "prepare disposable database",
      cwd: :core,
      executable: "mix",
      args: ["ecto.migrate.allbert", "--quiet"],
      coverage: ["schema boot", "release-owned DATABASE_PATH"]
    },
    %{
      id: "vision_image_policy_core",
      title: "image resources, provider profiles, bounds, permissions, and redaction",
      cwd: :core,
      executable: "mix",
      args: [
        "test",
        "test/allbert_assist/settings/provider_catalog_test.exs",
        "test/allbert_assist/settings/model_preferences_test.exs",
        "test/allbert_assist/settings_test.exs",
        "test/allbert_assist/resources/resource_uri_test.exs",
        "test/allbert_assist/resources/operation_class_test.exs",
        "test/allbert_assist/resources/image_metadata_test.exs",
        "test/allbert_assist/resources/image_bounds_test.exs",
        "test/allbert_assist/security/permission_gate_test.exs",
        "test/allbert_assist/runtime/redactor_test.exs"
      ],
      coverage: [
        "vision_input and image_generation provider profile metadata",
        "image:// and screen:// resource identity",
        "vision/image settings defaults and safe write keys",
        "server-side image metadata parsing and bounds",
        "image permission floors and metadata-only redaction"
      ]
    },
    %{
      id: "vision_input_flow",
      title: "vision input through direct_answer and fake multimodal provider",
      cwd: :core,
      executable: "mix",
      args: [
        "test",
        "test/allbert_assist/actions/intent/direct_answer_test.exs",
        "test/allbert_assist/runtime/trace_test.exs"
      ],
      coverage: [
        "vision_input capability resolution through the text call path",
        "image metadata attachment and transient cleanup",
        "vision-disabled fallback",
        "trace redaction for image input metadata"
      ]
    },
    %{
      id: "browser_screenshot_vision_bridge",
      title: "browser screenshot cache refs through the vision input path",
      cwd: :core,
      executable: "mix",
      args: [
        "test",
        "test/allbert_assist/actions/browser_actions_test.exs"
      ],
      coverage: [
        "browser_screenshot writes a bounded cache artifact",
        "analyze_browser_screenshot resolves only cache://browser refs",
        "existing screenshot refs feed direct_answer image_inputs",
        "screen:// provenance stays inert and redacted"
      ]
    },
    %{
      id: "image_generation_action",
      title: "registered image generation action and confirmation resume",
      cwd: :core,
      executable: "mix",
      args: [
        "test",
        "test/allbert_assist/actions/generate_image_test.exs",
        "test/allbert_assist/actions/registry_test.exs"
      ],
      coverage: [
        "fake image provider fixture path",
        "remote image generation confirmation floor",
        "approved remote confirmation resume",
        "single retryable provider fallback",
        "internal resumable action registry metadata"
      ]
    },
    %{
      id: "workspace_image_input",
      title: "workspace image upload controls and vision handoff",
      cwd: :web,
      executable: "mix",
      args: ["test", "test/allbert_assist_web/live/workspace_live_test.exs"],
      coverage: [
        "workspace image upload disabled when vision is off",
        "approved LiveView image upload writes bounded image metadata",
        "composer image controls remain media resources, not generated UI code"
      ]
    },
    %{
      id: "vision_security_eval",
      title: "v0.49 vision and image-generation security eval inventory and release evals",
      cwd: :core,
      executable: "mix",
      args: [
        "test",
        "test/security/v049_vision_modality_eval_test.exs",
        "test/security/security_eval_case_test.exs",
        "test/mix/tasks/allbert_test_task_test.exs"
      ],
      coverage: [
        "8 v0.49 vision modality eval rows",
        "release.v049 task usage registration",
        "vision input bounds and trace redaction",
        "browser screenshot refs bridge into vision without autonomous capture",
        "image_generation remote confirmation posture",
        "generated image cost/usage metadata display-only",
        "screen resource identity is inert and operator-supplied only"
      ]
    }
  ]

  @release_v050_steps [
    %{
      id: "migrate",
      title: "prepare disposable database",
      cwd: :core,
      executable: "mix",
      args: ["ecto.migrate.allbert", "--quiet"],
      coverage: ["schema boot", "release-owned DATABASE_PATH"]
    },
    %{
      id: "artifact_store_core",
      title: "artifact store roots, identity, bounds, permissions, and redaction",
      cwd: :core,
      executable: "mix",
      args: [
        "test",
        "test/allbert_assist/paths_test.exs",
        "test/allbert_assist/runtime/paths_test.exs",
        "test/allbert_assist/artifacts/store_test.exs",
        "test/allbert_assist/artifacts/metadata_index_test.exs",
        "test/allbert_assist/artifacts/bounds_test.exs",
        "test/allbert_assist/settings_test.exs",
        "test/allbert_assist/resources/resource_uri_test.exs",
        "test/allbert_assist/resources/operation_class_test.exs",
        "test/allbert_assist/security/permission_gate_test.exs",
        "test/allbert_assist/runtime/redactor_test.exs"
      ],
      coverage: [
        "Allbert Home artifact/media roots",
        "artifact://sha256 identity and artifact_store origin kind",
        "CAS object writes, dedup, metadata sidecars, and bounds",
        "artifact permission floors and redaction surface",
        "artifacts.* Settings Central fragment"
      ]
    },
    %{
      id: "artifact_actions_provenance_gc",
      title: "artifact actions, thread links, registry metadata, and GC",
      cwd: :core,
      executable: "mix",
      args: [
        "test",
        "test/allbert_assist/actions/artifact_actions_test.exs",
        "test/allbert_assist/actions/registry_test.exs",
        "test/allbert_assist/artifacts/thread_links_test.exs",
        "test/allbert_assist/artifacts/gc_test.exs"
      ],
      coverage: [
        "put/get/list/delete/artifact_threads/artifact_doctor through Actions.Runner",
        "delete confirmation and approved resume",
        "message/thread provenance links and reverse lookup",
        "supervised mark-and-sweep GC"
      ]
    },
    %{
      id: "artifact_retained_media_sensor",
      title: "retained media backfill and supervised ingestion sensor",
      cwd: :core,
      executable: "mix",
      args: [
        "test",
        "test/allbert_assist/artifacts/backfill_test.exs",
        "test/allbert_assist/artifacts/ingestion_sensor_test.exs",
        "test/allbert_assist/actions/transcribe_voice_test.exs",
        "test/allbert_assist/actions/generate_image_test.exs"
      ],
      coverage: [
        "retained audio/image/generated-image backfill into CAS",
        "Browser cache exclusion",
        "supervised Jido.Sensor.Runtime dispatch target",
        "retained generated-image writes through put_artifact"
      ]
    },
    %{
      id: "artifact_workspace_retained_media",
      title: "workspace retained voice and image ingestion",
      cwd: :web,
      executable: "mix",
      args: ["test", "test/allbert_assist_web/live/workspace_live_test.exs"],
      coverage: [
        "workspace retained voice upload stores through Artifacts Central",
        "workspace retained image upload stores through Artifacts Central",
        "transient scratch paths remain unchanged"
      ]
    },
    %{
      id: "artifact_security_eval",
      title: "v0.50 artifact-store security eval inventory and release evals",
      cwd: :core,
      executable: "mix",
      args: [
        "test",
        "test/security/v050_artifact_store_eval_test.exs",
        "test/security/security_eval_case_test.exs",
        "test/mix/tasks/allbert_test_task_test.exs"
      ],
      coverage: [
        "8 v0.50 artifact-store eval rows",
        "release.v050 task usage registration",
        "content-address identity is inert",
        "bytes and paths remain redacted",
        "retention default-off, bounds, delete confirmation, sensor advisory-only, and thread-link no-authority posture"
      ]
    }
  ]

  @release_v050b_steps [
    %{
      id: "migrate",
      title: "prepare disposable database",
      cwd: :core,
      executable: "mix",
      args: ["ecto.migrate.allbert", "--quiet"],
      coverage: ["schema boot", "release-owned DATABASE_PATH"]
    },
    %{
      id: "artifact_browser_smoke_seed",
      title: "deterministic browser-validation artifact fixture",
      cwd: :core,
      executable: "mix",
      args: ["run", "../../scripts/v050b_artifacts_browser_smoke.exs", "--seed-only"],
      coverage: [
        "deterministic artifact fixture through core put_artifact",
        "printed fixture SHA and thread id for Chrome validation",
        "release evidence captures real URLs without placeholders"
      ]
    },
    %{
      id: "artifact_browser_plugin_cli",
      title: "Artifacts Browser plugin contract, panel hydration, and CLI",
      cwd: :core,
      executable: "mix",
      args: [
        "test",
        "../../plugins/allbert.artifacts/test/allbert_artifacts/plugin_test.exs",
        "../../plugins/allbert.artifacts/test/allbert_artifacts/app_panels_test.exs",
        "../../plugins/allbert.artifacts/test/mix/tasks/allbert_artifacts_test.exs"
      ],
      coverage: [
        "plugin/app grants no authority",
        "workspace panel reads metadata through core actions",
        "CLI list/show/threads/doctor/rm and filters stay redacted"
      ]
    },
    %{
      id: "artifact_browser_web",
      title: "Artifacts Browser detail route and workspace filter plumbing",
      cwd: :web,
      executable: "mix",
      args: [
        "test",
        "test/allbert_assist_web/live/artifacts_live_test.exs",
        "test/allbert_assist_web/live/workspace_live_test.exs"
      ],
      coverage: [
        "/apps/artifacts/:sha validates sha before store reads",
        "detail page renders metadata, provenance, retention, and delete confirmation request",
        "workspace query params hydrate Artifacts Browser filters"
      ]
    },
    %{
      id: "artifact_browser_security_eval",
      title: "v0.50b artifact-browser security eval inventory and release evals",
      cwd: :core,
      executable: "mix",
      args: [
        "test",
        "test/security/v050b_artifacts_browser_eval_test.exs",
        "test/security/security_eval_case_test.exs",
        "test/mix/tasks/allbert_test_task_test.exs"
      ],
      coverage: [
        "4 v0.50b artifact-browser eval rows",
        "release.v050b task usage registration",
        "read-only action boundary, metadata-only rendering, no authority grant, and delete confirmation posture"
      ]
    }
  ]

  @release_v051_steps [
    %{
      id: "migrate",
      title: "prepare disposable database",
      cwd: :core,
      executable: "mix",
      args: ["ecto.migrate.allbert", "--quiet"],
      coverage: ["schema boot", "release-owned DATABASE_PATH"]
    },
    %{
      id: "public_protocol_foundations",
      title: "public protocol trust tier, settings, exposure, auth, rate-limit, and readback",
      cwd: :core,
      executable: "mix",
      args: [
        "test",
        "test/allbert_assist/security/public_surface_policy_test.exs",
        "test/allbert_assist/settings/public_surface_schema_test.exs",
        "test/allbert_assist/public_protocol/exposure_filter_test.exs",
        "test/allbert_assist/public_protocol/token_auth_test.exs",
        "test/allbert_assist/public_protocol/rate_limiter_test.exs",
        "test/allbert_assist/public_protocol/result_readback_test.exs",
        "test/allbert_assist/public_protocol/stdio_guard_test.exs"
      ],
      coverage: [
        "inbound public-surface permission/floor",
        "Settings Central public-surface schema",
        "deny-before-allow exposure filter",
        "token auth and rate limiting",
        "client-scoped poll-by-id readback"
      ]
    },
    %{
      id: "mcp_stdio_core",
      title: "MCP stdio server, resources, readback, and CLI",
      cwd: :core,
      executable: "mix",
      args: [
        "test",
        "test/allbert_assist/public_protocol/mcp_stdio_server_test.exs",
        "test/allbert_assist/public_protocol/http_ingress_test.exs",
        "test/mix/tasks/allbert_mcp_server_test.exs"
      ],
      coverage: [
        "MCP stdio JSON-RPC server subset",
        "tool/resource allowlists",
        "MCP HTTP ingress helper contract",
        "MCP CLI status/tools/resources"
      ]
    },
    %{
      id: "mcp_http_web",
      title: "MCP HTTP controller and shared public API ingress",
      cwd: :web,
      executable: "mix",
      args: ["test", "test/allbert_assist_web/public_protocol/mcp_http_controller_test.exs"],
      coverage: [
        "POST /mcp JSON-only subset",
        "token auth, rate-limit, body cap, secure headers",
        "Origin/session/protocol-version handling"
      ]
    },
    %{
      id: "openai_compatible_api",
      title: "OpenAI-compatible text-only API shim",
      cwd: :core,
      executable: "mix",
      args: ["test", "test/allbert_assist/public_protocol/openai_mapping_test.exs"],
      coverage: [
        "text-only Chat Completions mapping",
        "model allowlist through Settings Central",
        "tools/media/unknown-field rejection"
      ]
    },
    %{
      id: "openai_compatible_web",
      title: "OpenAI-compatible HTTP controller",
      cwd: :web,
      executable: "mix",
      args: ["test", "test/allbert_assist_web/public_protocol/openai_controller_test.exs"],
      coverage: [
        "GET /v1/models",
        "POST /v1/chat/completions",
        "streaming event-stream facade",
        "OpenAI-shaped auth/rate/validation errors"
      ]
    },
    %{
      id: "acp_stdio_core",
      title: "ACP stdio server and CLI",
      cwd: :core,
      executable: "mix",
      args: [
        "test",
        "test/allbert_assist/public_protocol/acp_mapping_test.exs",
        "test/allbert_assist/public_protocol/acp_stdio_server_test.exs",
        "test/mix/tasks/allbert_acp_server_test.exs"
      ],
      coverage: [
        "ACP v1 stdio JSON-RPC subset",
        "text-only prompt mapping",
        "cwd/mcpServers/permissionMode non-authority",
        "advisory permission request behavior"
      ]
    },
    %{
      id: "public_protocol_security_eval",
      title: "v0.51 public-protocol security eval inventory and release evals",
      cwd: :core,
      executable: "mix",
      args: [
        "test",
        "test/security/v051_public_protocol_eval_test.exs",
        "test/security/security_eval_case_test.exs",
        "test/mix/tasks/allbert_test_task_test.exs"
      ],
      coverage: [
        "34 v0.51 public-protocol eval rows",
        "release.v051 task usage registration",
        "empty exposure defaults, no self-approval, HTTP ingress, readback scope, MCP/OpenAI/ACP subset contracts"
      ]
    }
  ]

  @release_v052_steps [
    %{
      id: "migrate",
      title: "prepare disposable database",
      cwd: :core,
      executable: "mix",
      args: ["ecto.migrate.allbert", "--quiet"],
      coverage: ["schema boot", "release-owned DATABASE_PATH"]
    },
    %{
      id: "channel_pack_contracts",
      title: "channel primitives, inbound trust tier, plugin descriptors, and thread substrate",
      cwd: :core,
      executable: "mix",
      args: [
        "test",
        "test/allbert_assist/security/channel_inbound_policy_test.exs",
        "test/allbert_assist/channels_test.exs",
        "test/allbert_assist/plugin/validator_test.exs",
        "test/allbert_assist/approval/handoff_test.exs",
        "test/allbert_assist/conversations/channel_thread_test.exs"
      ],
      coverage: [
        "channel_message_inbound confirmation floor",
        "registered channel descriptors with approval primitives and threading",
        "provider-thread ref uniqueness, message refs, identity links, and echo detection"
      ]
    },
    %{
      id: "discord_slack_channel_plugins",
      title: "Discord and Slack plugin adapters, parsers, renderers, and clients",
      cwd: :core,
      executable: "mix",
      args: [
        "test",
        "test/allbert_assist/channels/discord_test.exs",
        "test/allbert_assist/channels/slack_test.exs"
      ],
      coverage: [
        "Discord Gateway and Slack Socket Mode parser normalization",
        "allowlist and identity-map rejection before runtime",
        "confirmation callback scoping, threaded reply placement, and token redaction"
      ]
    },
    %{
      id: "cross_channel_history_cli",
      title: "cross-channel unified history and operator CLI surfaces",
      cwd: :core,
      executable: "mix",
      args: [
        "test",
        "test/allbert_assist/conversations/unified_history_test.exs",
        "test/mix/tasks/allbert_channels_test.exs",
        "test/mix/tasks/allbert_conversations_test.exs"
      ],
      coverage: [
        "redacted unified history across provider message refs",
        "same-user cross-channel resume with explicit identity links",
        "operator CLI status, show, and resume commands"
      ]
    },
    %{
      id: "workspace_continuity_web",
      title: "workspace unified-history continuity strip",
      cwd: :web,
      executable: "mix",
      args: ["test", "test/allbert_assist_web/live/workspace_live_test.exs"],
      coverage: [
        "LiveView renders redacted cross-channel continuity without owning channel authority",
        "workspace UI keeps stable layout across provider channel chips"
      ]
    },
    %{
      id: "channel_pack_security_eval",
      title: "v0.52 channel-pack security eval inventory and release evals",
      cwd: :core,
      executable: "mix",
      args: [
        "test",
        "test/security/v052_channel_pack_eval_test.exs",
        "test/security/security_eval_case_test.exs",
        "test/mix/tasks/allbert_test_task_test.exs"
      ],
      coverage: [
        "28 v0.52 channel-pack eval rows",
        "release.v052 and per-provider (discord/slack/inbound_discord/inbound_slack) external-smoke task usage registration",
        "identity/allowlist, inbound permission enforcement, callback scope, token redaction, threading authority, and unified-history redaction"
      ]
    }
  ]

  @release_v053_steps [
    %{
      id: "migrate",
      title: "prepare disposable database",
      cwd: :core,
      executable: "mix",
      args: ["ecto.migrate.allbert", "--quiet"],
      coverage: ["schema boot", "release-owned DATABASE_PATH"]
    },
    %{
      id: "telegram_email_channel_plugins",
      title: "Telegram/email retro-validation adapters, MIME, callbacks, and doctors",
      cwd: :core,
      executable: "mix",
      args: [
        "test",
        "test/allbert_assist/channels/telegram_test.exs",
        "test/allbert_assist/channels/email_test.exs",
        "test/allbert_assist/actions/channels/telegram_doctor_test.exs",
        "test/allbert_assist/actions/channels/email_doctor_test.exs"
      ],
      coverage: [
        "Telegram callback_data provider limit and fallback commands",
        "email MIME encoded-word, quoted-printable, and base64 body decoding",
        "provider doctor redacted envelopes and persisted state"
      ]
    },
    %{
      id: "capability_release_gate",
      title: "M11 capability release availability declarations and runtime gates",
      cwd: :core,
      executable: "mix",
      args: [
        "test",
        "test/allbert_assist/capabilities/release_availability_test.exs",
        "test/allbert_assist/plugin/validator_test.exs",
        "test/allbert_assist/actions/runner_test.exs",
        "test/allbert_assist/actions/channels/send_channel_message_test.exs"
      ],
      coverage: [
        "undeclared capabilities default to released",
        "plugin-owned YAML/callback declarations normalize and enforce ownership",
        "explicit action/channel release blocks stop before runtime/provider dispatch",
        "declared unavailable channels do not affect Discord/Slack or other released surfaces"
      ]
    },
    %{
      id: "channel_cli_and_smoke_registration",
      title: "channel CLI doctors and independent external-smoke selectors",
      cwd: :core,
      executable: "mix",
      args: [
        "test",
        "test/mix/tasks/allbert_channels_test.exs",
        "test/mix/tasks/allbert_test_task_test.exs"
      ],
      coverage: [
        "Telegram/email/Matrix/WhatsApp/Signal doctor CLI commands",
        "external-smoke -- telegram, -- inbound_telegram, -- email, -- inbound_email, -- matrix, -- inbound_matrix, -- whatsapp, -- signal usage registration",
        "Discord/Slack independent selectors stay listed"
      ]
    },
    %{
      id: "matrix_channel_plugin",
      title: "Matrix plugin fixture sync, threaded send, doctor, and CLI",
      cwd: :core,
      executable: "mix",
      args: [
        "test",
        "test/allbert_assist/channels/matrix_test.exs",
        "test/allbert_assist/actions/channels/matrix_doctor_test.exs",
        "test/external/matrix_smoke_test.exs"
      ],
      coverage: [
        "Matrix Client-Server bearer auth request shapes",
        "fixture /sync text delivery and threaded m.room.message reply refs",
        "matrix doctor redacted envelope",
        "external-smoke -- matrix skip-clean scaffold"
      ]
    },
    %{
      id: "whatsapp_channel_plugin",
      title: "WhatsApp plugin webhook fixture, reply-chain send, doctor, and CLI",
      cwd: :core,
      executable: "mix",
      args: [
        "test",
        "test/allbert_assist/channels/whatsapp_test.exs",
        "test/allbert_assist/actions/channels/whatsapp_doctor_test.exs",
        "test/external/whatsapp_smoke_test.exs",
        "../../plugins/allbert.whatsapp/test"
      ],
      coverage: [
        "WhatsApp Cloud API bearer-auth request shapes",
        "signed-webhook adapter consumption with simulated text and button replies",
        "reply-chain quote TTL degradation",
        "phone and token redaction",
        "external-smoke -- whatsapp skip-clean scaffold"
      ]
    },
    %{
      id: "signal_channel_plugin",
      title: "Signal plugin daemon stub, reply-by-timestamp, doctor, and CLI",
      cwd: :core,
      executable: "mix",
      args: [
        "test",
        "test/allbert_assist/channels/signal_test.exs",
        "test/allbert_assist/actions/channels/signal_doctor_test.exs",
        "test/external/signal_smoke_test.exs",
        "../../plugins/allbert.signal/test"
      ],
      coverage: [
        "Signal signal-cli JSON-RPC request shapes",
        "stubbed daemon inbound delivery and timestamp quote params",
        "ACI-keyed identity and e2ee_origin trust stamping",
        "local control endpoint and key custody permission checks",
        "external-smoke -- signal skip-clean scaffold"
      ]
    },
    %{
      id: "channel_pack_v053_eval",
      title: "v0.53 channel-pack security eval inventory and tests",
      cwd: :core,
      executable: "mix",
      args: [
        "test",
        "test/security/v053_channel_pack_eval_test.exs",
        "test/security/security_eval_case_test.exs"
      ],
      coverage: [
        "key custody no-leak and audited fetch rows",
        "Signal local control, socket mode, keyfile custody, and ACI identity rows",
        "WhatsApp webhook signature verification and bad-signature denial rows",
        "trust-class stamping, descriptor validation, Matrix encrypted-room exclusion, and inbound policy floor rows",
        "E2EE unified-history exclusion/opt-in, downgrade confirmation, reply timestamp, quote TTL, provider-thread, and identity-link rows",
        "Channel Pack 1 email/Telegram remediation regression rows"
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

  defp release_v046 do
    env = owned_env("release-v046", 0)
    home = env_value(env, "ALLBERT_HOME")
    database = env_value(env, "DATABASE_PATH")
    evidence_dir = Path.join(home, "release_evidence/v046")
    File.mkdir_p!(evidence_dir)
    cleanup_release_v046_evidence!(evidence_dir)

    started_at = DateTime.utc_now()
    results = Enum.map(@release_v046_steps, &run_release_v046_step(&1, env))
    secret_scan = release_v046_secret_scan(home)

    status =
      if Enum.all?(results, &(&1.status == "passed")) and secret_scan.status == "passed" do
        "passed"
      else
        "failed"
      end

    evidence = %{
      gate: "mix allbert.test release.v046",
      version: "v0.46",
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
      Path.join(evidence_dir, "release-v046-#{DateTime.to_unix(started_at)}.json")

    File.write!(evidence_path, Jason.encode!(evidence, pretty: true))
    Mix.shell().info("release.v046 evidence: #{evidence_path}")

    if status != "passed" do
      Mix.raise("release.v046 failed; evidence: #{evidence_path}")
    end
  end

  defp release_v047 do
    env = owned_env("release-v047", 0)
    home = env_value(env, "ALLBERT_HOME")
    database = env_value(env, "DATABASE_PATH")
    evidence_dir = Path.join(home, "release_evidence/v047")
    File.mkdir_p!(evidence_dir)
    cleanup_release_v047_evidence!(evidence_dir)

    started_at = DateTime.utc_now()
    results = Enum.map(@release_v047_steps, &run_release_v047_step(&1, env))
    secret_scan = release_v047_secret_scan(home)

    status =
      if Enum.all?(results, &(&1.status == "passed")) and secret_scan.status == "passed" do
        "passed"
      else
        "failed"
      end

    evidence = %{
      gate: "mix allbert.test release.v047",
      version: "v0.47",
      status: status,
      generated_at: DateTime.utc_now() |> DateTime.to_iso8601(),
      started_at: DateTime.to_iso8601(started_at),
      allbert_home: home,
      database_path: database,
      evidence_dir: evidence_dir,
      external_network: "disabled; tests use fixture traces and local runtime only",
      steps: results,
      secret_scan: secret_scan
    }

    evidence_path =
      Path.join(evidence_dir, "release-v047-#{DateTime.to_unix(started_at)}.json")

    File.write!(evidence_path, Jason.encode!(evidence, pretty: true))
    Mix.shell().info("release.v047 evidence: #{evidence_path}")

    if status != "passed" do
      Mix.raise("release.v047 failed; evidence: #{evidence_path}")
    end
  end

  defp release_v047b do
    env = owned_env("release-v047b", 0)
    home = env_value(env, "ALLBERT_HOME")
    database = env_value(env, "DATABASE_PATH")
    evidence_dir = Path.join(home, "release_evidence/v047b")
    File.mkdir_p!(evidence_dir)
    cleanup_release_v047b_evidence!(evidence_dir)

    started_at = DateTime.utc_now()
    results = Enum.map(@release_v047b_steps, &run_release_v047b_step(&1, env))
    secret_scan = release_v047b_secret_scan(home)

    status =
      if Enum.all?(results, &(&1.status == "passed")) and secret_scan.status == "passed" do
        "passed"
      else
        "failed"
      end

    evidence = %{
      gate: "mix allbert.test release.v047b",
      version: "v0.47b",
      status: status,
      generated_at: DateTime.utc_now() |> DateTime.to_iso8601(),
      started_at: DateTime.to_iso8601(started_at),
      allbert_home: home,
      database_path: database,
      evidence_dir: evidence_dir,
      external_network:
        "disabled; tests use fixture traces, catalogs, templates, and local runtime only",
      steps: results,
      secret_scan: secret_scan
    }

    evidence_path =
      Path.join(evidence_dir, "release-v047b-#{DateTime.to_unix(started_at)}.json")

    File.write!(evidence_path, Jason.encode!(evidence, pretty: true))
    Mix.shell().info("release.v047b evidence: #{evidence_path}")

    if status != "passed" do
      Mix.raise("release.v047b failed; evidence: #{evidence_path}")
    end
  end

  defp release_v048 do
    env = owned_env("release-v048", 0)
    home = env_value(env, "ALLBERT_HOME")
    database = env_value(env, "DATABASE_PATH")
    evidence_dir = Path.join(home, "release_evidence/v048")
    File.mkdir_p!(evidence_dir)
    cleanup_release_v048_evidence!(evidence_dir)

    started_at = DateTime.utc_now()
    results = Enum.map(@release_v048_steps, &run_release_v048_step(&1, env))
    secret_scan = release_v048_secret_scan(home)

    status =
      if Enum.all?(results, &(&1.status == "passed")) and secret_scan.status == "passed" do
        "passed"
      else
        "failed"
      end

    evidence = %{
      gate: "mix allbert.test release.v048",
      version: "v0.48",
      status: status,
      generated_at: DateTime.utc_now() |> DateTime.to_iso8601(),
      started_at: DateTime.to_iso8601(started_at),
      allbert_home: home,
      database_path: database,
      evidence_dir: evidence_dir,
      external_network:
        "disabled; tests use fixture STT/TTS providers, Req.Test provider fixtures, and local files",
      steps: results,
      secret_scan: secret_scan
    }

    evidence_path =
      Path.join(evidence_dir, "release-v048-#{DateTime.to_unix(started_at)}.json")

    File.write!(evidence_path, Jason.encode!(evidence, pretty: true))
    Mix.shell().info("release.v048 evidence: #{evidence_path}")

    if status != "passed" do
      Mix.raise("release.v048 failed; evidence: #{evidence_path}")
    end
  end

  defp release_v049 do
    env = owned_env("release-v049", 0)
    home = env_value(env, "ALLBERT_HOME")
    database = env_value(env, "DATABASE_PATH")
    evidence_dir = Path.join(home, "release_evidence/v049")
    File.mkdir_p!(evidence_dir)
    cleanup_release_v049_evidence!(evidence_dir)

    started_at = DateTime.utc_now()
    results = Enum.map(@release_v049_steps, &run_release_v049_step(&1, env))
    secret_scan = release_v049_secret_scan(home)

    status =
      if Enum.all?(results, &(&1.status == "passed")) and secret_scan.status == "passed" do
        "passed"
      else
        "failed"
      end

    evidence = %{
      gate: "mix allbert.test release.v049",
      version: "v0.49",
      status: status,
      generated_at: DateTime.utc_now() |> DateTime.to_iso8601(),
      started_at: DateTime.to_iso8601(started_at),
      allbert_home: home,
      database_path: database,
      evidence_dir: evidence_dir,
      external_network:
        "disabled; tests use fake vision/image providers, Req.Test provider fixtures, and local image files",
      steps: results,
      secret_scan: secret_scan
    }

    evidence_path =
      Path.join(evidence_dir, "release-v049-#{DateTime.to_unix(started_at)}.json")

    File.write!(evidence_path, Jason.encode!(evidence, pretty: true))
    Mix.shell().info("release.v049 evidence: #{evidence_path}")

    if status != "passed" do
      Mix.raise("release.v049 failed; evidence: #{evidence_path}")
    end
  end

  defp release_v050 do
    env = owned_env("release-v050", 0)
    home = env_value(env, "ALLBERT_HOME")
    database = env_value(env, "DATABASE_PATH")
    evidence_dir = Path.join(home, "release_evidence/v050")
    File.mkdir_p!(evidence_dir)
    cleanup_release_v050_evidence!(evidence_dir)

    started_at = DateTime.utc_now()
    results = Enum.map(@release_v050_steps, &run_release_v050_step(&1, env))
    secret_scan = release_v050_secret_scan(home)

    status =
      if Enum.all?(results, &(&1.status == "passed")) and secret_scan.status == "passed" do
        "passed"
      else
        "failed"
      end

    evidence = %{
      gate: "mix allbert.test release.v050",
      version: "v0.50",
      status: status,
      generated_at: DateTime.utc_now() |> DateTime.to_iso8601(),
      started_at: DateTime.to_iso8601(started_at),
      allbert_home: home,
      database_path: database,
      evidence_dir: evidence_dir,
      external_network: "disabled; tests use local artifact fixtures only",
      steps: results,
      secret_scan: secret_scan
    }

    evidence_path =
      Path.join(evidence_dir, "release-v050-#{DateTime.to_unix(started_at)}.json")

    File.write!(evidence_path, Jason.encode!(evidence, pretty: true))
    Mix.shell().info("release.v050 evidence: #{evidence_path}")

    if status != "passed" do
      Mix.raise("release.v050 failed; evidence: #{evidence_path}")
    end
  end

  defp release_v050b do
    env = owned_env("release-v050b", 0)
    home = env_value(env, "ALLBERT_HOME")
    database = env_value(env, "DATABASE_PATH")
    evidence_dir = Path.join(home, "release_evidence/v050b")
    File.mkdir_p!(evidence_dir)
    cleanup_release_v050b_evidence!(evidence_dir)

    started_at = DateTime.utc_now()
    results = Enum.map(@release_v050b_steps, &run_release_v050b_step(&1, env))
    secret_scan = release_v050b_secret_scan(home)

    status =
      if Enum.all?(results, &(&1.status == "passed")) and secret_scan.status == "passed" do
        "passed"
      else
        "failed"
      end

    evidence = %{
      gate: "mix allbert.test release.v050b",
      version: "v0.50b",
      status: status,
      generated_at: DateTime.utc_now() |> DateTime.to_iso8601(),
      started_at: DateTime.to_iso8601(started_at),
      allbert_home: home,
      database_path: database,
      evidence_dir: evidence_dir,
      external_network: "disabled; tests use local artifact fixtures only",
      browser_validation_fixture: release_v050b_browser_fixture(results),
      steps: results,
      secret_scan: secret_scan
    }

    evidence_path =
      Path.join(evidence_dir, "release-v050b-#{DateTime.to_unix(started_at)}.json")

    File.write!(evidence_path, Jason.encode!(evidence, pretty: true))
    Mix.shell().info("release.v050b evidence: #{evidence_path}")

    if status != "passed" do
      Mix.raise("release.v050b failed; evidence: #{evidence_path}")
    end
  end

  defp release_v051 do
    env = owned_env("release-v051", 0)
    home = env_value(env, "ALLBERT_HOME")
    database = env_value(env, "DATABASE_PATH")
    evidence_dir = Path.join(home, "release_evidence/v051")
    File.mkdir_p!(evidence_dir)
    cleanup_release_v051_evidence!(evidence_dir)

    started_at = DateTime.utc_now()
    results = Enum.map(@release_v051_steps, &run_release_v051_step(&1, env))
    secret_scan = release_v051_secret_scan(home)

    status =
      if Enum.all?(results, &(&1.status == "passed")) and secret_scan.status == "passed" do
        "passed"
      else
        "failed"
      end

    evidence = %{
      gate: "mix allbert.test release.v051",
      version: "v0.51",
      status: status,
      generated_at: DateTime.utc_now() |> DateTime.to_iso8601(),
      started_at: DateTime.to_iso8601(started_at),
      allbert_home: home,
      database_path: database,
      evidence_dir: evidence_dir,
      external_network:
        "disabled; tests use local public-protocol fixtures and no live external clients",
      steps: results,
      secret_scan: secret_scan
    }

    evidence_path =
      Path.join(evidence_dir, "release-v051-#{DateTime.to_unix(started_at)}.json")

    File.write!(evidence_path, Jason.encode!(evidence, pretty: true))
    Mix.shell().info("release.v051 evidence: #{evidence_path}")

    if status != "passed" do
      Mix.raise("release.v051 failed; evidence: #{evidence_path}")
    end
  end

  defp release_v052 do
    env = owned_env("release-v052", 0)
    home = env_value(env, "ALLBERT_HOME")
    database = env_value(env, "DATABASE_PATH")
    evidence_dir = Path.join(home, "release_evidence/v052")
    File.mkdir_p!(evidence_dir)
    cleanup_release_v052_evidence!(evidence_dir)

    started_at = DateTime.utc_now()
    results = Enum.map(@release_v052_steps, &run_release_v052_step(&1, env))
    secret_scan = release_v052_secret_scan(home)

    status =
      if Enum.all?(results, &(&1.status == "passed")) and secret_scan.status == "passed" do
        "passed"
      else
        "failed"
      end

    evidence = %{
      gate: "mix allbert.test release.v052",
      version: "v0.52",
      status: status,
      generated_at: DateTime.utc_now() |> DateTime.to_iso8601(),
      started_at: DateTime.to_iso8601(started_at),
      allbert_home: home,
      database_path: database,
      evidence_dir: evidence_dir,
      external_network:
        "disabled; tests use local channel fixtures, Req.Test HTTP fixtures, and no live Slack/Discord clients",
      required_external_smokes: [
        "mix allbert.test external-smoke -- discord",
        "mix allbert.test external-smoke -- inbound_discord",
        "mix allbert.test external-smoke -- slack",
        "mix allbert.test external-smoke -- inbound_slack"
      ],
      steps: results,
      secret_scan: secret_scan
    }

    evidence_path =
      Path.join(evidence_dir, "release-v052-#{DateTime.to_unix(started_at)}.json")

    File.write!(evidence_path, Jason.encode!(evidence, pretty: true))
    Mix.shell().info("release.v052 evidence: #{evidence_path}")

    if status != "passed" do
      Mix.raise("release.v052 failed; evidence: #{evidence_path}")
    end
  end

  defp release_v053 do
    env = owned_env("release-v053", 0)
    home = env_value(env, "ALLBERT_HOME")
    database = env_value(env, "DATABASE_PATH")
    evidence_dir = Path.join(home, "release_evidence/v053")
    File.mkdir_p!(evidence_dir)
    cleanup_release_v053_evidence!(evidence_dir)

    started_at = DateTime.utc_now()
    results = Enum.map(@release_v053_steps, &run_release_v053_step(&1, env))
    secret_scan = release_v053_secret_scan(home)

    status =
      if Enum.all?(results, &(&1.status == "passed")) and secret_scan.status == "passed" do
        "passed"
      else
        "failed"
      end

    evidence = %{
      gate: "mix allbert.test release.v053",
      version: "v0.53",
      status: status,
      generated_at: DateTime.utc_now() |> DateTime.to_iso8601(),
      started_at: DateTime.to_iso8601(started_at),
      allbert_home: home,
      database_path: database,
      evidence_dir: evidence_dir,
      external_network:
        "disabled; tests use local channel fixtures, Req.Test HTTP fixtures, stubbed signal-cli JSON-RPC, and no live Telegram/email/Matrix/WhatsApp/Signal providers",
      required_external_smokes: [
        "mix allbert.test external-smoke -- telegram",
        "mix allbert.test external-smoke -- inbound_telegram",
        "mix allbert.test external-smoke -- email",
        "mix allbert.test external-smoke -- inbound_email",
        "mix allbert.test external-smoke -- matrix",
        "mix allbert.test external-smoke -- whatsapp",
        "mix allbert.test external-smoke -- signal"
      ],
      steps: results,
      secret_scan: secret_scan
    }

    evidence_path =
      Path.join(evidence_dir, "release-v053-#{DateTime.to_unix(started_at)}.json")

    File.write!(evidence_path, Jason.encode!(evidence, pretty: true))
    Mix.shell().info("release.v053 evidence: #{evidence_path}")

    if status != "passed" do
      Mix.raise("release.v053 failed; evidence: #{evidence_path}")
    end
  end

  @release_v054_steps [
    %{
      id: "migrate",
      title: "prepare disposable database",
      cwd: :core,
      executable: "mix",
      args: ["ecto.migrate.allbert", "--quiet"],
      coverage: ["schema boot", "release-owned DATABASE_PATH"]
    },
    %{
      id: "router_unit",
      title: "two-stage intent router unit suite",
      cwd: :core,
      executable: "mix",
      args: [
        "test",
        "test/allbert_assist/intent/router_test.exs",
        "test/allbert_assist/intent/router_embedding_test.exs",
        "test/allbert_assist/intent/router_prefilter_test.exs",
        "test/allbert_assist/intent/router_disambiguator_test.exs",
        "test/allbert_assist/intent/router_clarify_resolver_test.exs",
        "test/allbert_assist/intent/router_pending_store_test.exs",
        "test/allbert_assist/intent/conversation_context_test.exs"
      ],
      coverage: [
        "router dispatch/outcome + strategy override",
        "local embedding + utterance index + doctor",
        "Stage 1 prefilter shortlist + margin + fallback",
        "Stage 2 constrained disambiguation + confidence gate + escalation (local by default)",
        "clarify resolver bind/no-match",
        "pending-clarification TTL + cross-user isolation",
        "bounded/redacted multi-turn context"
      ]
    },
    %{
      id: "intent_agent_router",
      title: "router integration in the intent flow (execute/clarify/none, no dead-end)",
      cwd: :core,
      executable: "mix",
      args: ["test", "test/allbert_assist/intent/intent_agent_router_test.exs"],
      coverage: [
        "clarify renders a channel-answerable question + persists pending state",
        "none declines gracefully",
        "app-handoff dead-end removed"
      ]
    },
    %{
      id: "registry_contract",
      title: "action registry exposure/order contract",
      cwd: :core,
      executable: "mix",
      args: ["test", "test/allbert_assist/actions/registry_test.exs"],
      coverage: [
        "stable runtime action order",
        "agent/internal exposure split",
        "v0.54 promoted action surface",
        "canonical capability metadata"
      ]
    },
    %{
      id: "v054_eval",
      title: ":v054 router, descriptor lifecycle, outbound, and security eval",
      cwd: :core,
      executable: "mix",
      args: ["test", "test/security/v054_intent_router_eval_test.exs"],
      coverage: [
        "shortlist-constrained selection / authority-unchanged",
        "low-confidence clarifies; escalation local-by-default (no egress)",
        "create-vs-search descriptor regression",
        "clarify is channel-answerable (no dead-end)",
        "descriptor YAML lifecycle foundation + inert review tier",
        "outbound compose permissions + confirmation/resume posture",
        "shipped default is two_stage_local"
      ]
    }
  ]

  defp release_v054 do
    env = owned_env("release-v054", 0)
    home = env_value(env, "ALLBERT_HOME")
    database = env_value(env, "DATABASE_PATH")
    evidence_dir = Path.join(home, "release_evidence/v054")
    File.mkdir_p!(evidence_dir)

    started_at = DateTime.utc_now()
    results = Enum.map(@release_v054_steps, &run_release_v054_step(&1, env))
    secret_scan = release_channel_pack_secret_scan(home, "release.v054")

    status =
      if Enum.all?(results, &(&1.status == "passed")) and secret_scan.status == "passed" do
        "passed"
      else
        "failed"
      end

    evidence = %{
      gate: "mix allbert.test release.v054",
      version: "v0.54",
      status: status,
      generated_at: DateTime.utc_now() |> DateTime.to_iso8601(),
      started_at: DateTime.to_iso8601(started_at),
      allbert_home: home,
      database_path: database,
      evidence_dir: evidence_dir,
      external_network:
        "disabled; the local two-stage router defers to the deterministic ladder under the test override, and embedding/LLM selection use local fakes",
      notes:
        "the shipped intent.router_strategy default is two_stage_local; live local-model routing is exercised by the operator manual-validation punchlist in docs/plans/v0.54-request-flow.md",
      steps: results,
      secret_scan: secret_scan
    }

    evidence_path = Path.join(evidence_dir, "release-v054-#{DateTime.to_unix(started_at)}.json")
    File.write!(evidence_path, Jason.encode!(evidence, pretty: true))
    Mix.shell().info("release.v054 evidence: #{evidence_path}")

    if status != "passed" do
      Mix.raise("release.v054 failed; evidence: #{evidence_path}")
    end
  end

  defp run_release_v054_step(step, env) do
    started = System.monotonic_time(:millisecond)
    cwd = release_step_cwd(step.cwd)

    {output, exit_status} =
      System.cmd(step.executable, step.args, cd: cwd, env: env, stderr_to_stdout: true)

    duration_ms = System.monotonic_time(:millisecond) - started
    print_output("release.v054 #{step.id}", output)

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

  @release_v055_steps [
    %{
      id: "migrate",
      title: "prepare disposable database",
      cwd: :core,
      executable: "mix",
      args: ["ecto.migrate.allbert", "--quiet"],
      coverage: ["schema boot", "release-owned DATABASE_PATH"]
    },
    %{
      id: "channel_parity",
      title: "descriptor-derived channel parity matrix and CLI",
      cwd: :core,
      executable: "mix",
      args: [
        "test",
        "test/mix/tasks/allbert_channels_test.exs"
      ],
      coverage: [
        "ChannelParity verifies all registered descriptors include list fallback",
        "Matrix generic outbound reports implemented",
        "TUI descriptor appears as terminal typed_command/list rich threading"
      ]
    },
    %{
      id: "tui_channel",
      title: "TUI adapter, renderer, approval callback, and split payload units",
      cwd: :core,
      executable: "mix",
      args: [
        "test",
        "test/allbert_assist/channels/tui_test.exs",
        "test/allbert_assist/runtime_test.exs"
      ],
      coverage: [
        "terminal input identity mapping, dedupe, and event persistence",
        "typed approval commands resolve only same-channel confirmations",
        "surface payload renders while model payload persists cleanly"
      ]
    },
    %{
      id: "v055_eval",
      title: ":v055 channel parity and TUI security eval inventory",
      cwd: :core,
      executable: "mix",
      args: ["test", "test/security/v055_tui_channel_eval_test.exs"],
      coverage: [
        "12 v0.55 eval rows wired into EvalInventory",
        "TUI no-authority, identity, dedupe, redaction, and crash isolation",
        "approval primitive rendering and typed confirmation resolution",
        "split-payload contract and Owl runtime dependency"
      ]
    }
  ]

  defp release_v055 do
    env = owned_env("release-v055", 0)
    home = env_value(env, "ALLBERT_HOME")
    database = env_value(env, "DATABASE_PATH")
    evidence_dir = Path.join(home, "release_evidence/v055")
    File.mkdir_p!(evidence_dir)

    started_at = DateTime.utc_now()
    results = Enum.map(@release_v055_steps, &run_release_v055_step(&1, env))
    secret_scan = release_channel_pack_secret_scan(home, "release.v055")

    status =
      if Enum.all?(results, &(&1.status == "passed")) and secret_scan.status == "passed" do
        "passed"
      else
        "failed"
      end

    evidence = %{
      gate: "mix allbert.test release.v055",
      version: "v0.55",
      status: status,
      generated_at: DateTime.utc_now() |> DateTime.to_iso8601(),
      started_at: DateTime.to_iso8601(started_at),
      allbert_home: home,
      database_path: database,
      evidence_dir: evidence_dir,
      external_network:
        "disabled; channel parity, TUI input, approval callbacks, and split payload rendering run against local fixtures",
      notes:
        "live terminal interaction and Matrix provider delivery remain covered by the v0.55 operator-validation punchlist in docs/plans/v0.55-request-flow.md before tag",
      steps: results,
      secret_scan: secret_scan
    }

    evidence_path = Path.join(evidence_dir, "release-v055-#{DateTime.to_unix(started_at)}.json")
    File.write!(evidence_path, Jason.encode!(evidence, pretty: true))
    Mix.shell().info("release.v055 evidence: #{evidence_path}")

    if status != "passed" do
      Mix.raise("release.v055 failed; evidence: #{evidence_path}")
    end
  end

  defp run_release_v055_step(step, env) do
    started = System.monotonic_time(:millisecond)
    cwd = release_step_cwd(step.cwd)

    {output, exit_status} =
      System.cmd(step.executable, step.args, cd: cwd, env: env, stderr_to_stdout: true)

    duration_ms = System.monotonic_time(:millisecond) - started
    print_output("release.v055 #{step.id}", output)

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

  @release_v0551_steps [
    %{
      id: "migrate",
      title: "prepare disposable database",
      cwd: :core,
      executable: "mix",
      args: ["ecto.migrate.allbert", "--quiet"],
      coverage: ["schema boot", "release-owned DATABASE_PATH"]
    },
    %{
      id: "operator_console_units",
      title: "slash parser, inspection actions, and channel status units",
      cwd: :core,
      executable: "mix",
      args: [
        "test",
        "test/allbert_assist/channels/tui_test.exs",
        "test/mix/tasks/allbert_channels_test.exs",
        "test/allbert_assist/actions/registry_test.exs"
      ],
      coverage: [
        "TUI slash parser handles canonical, unknown, and malformed commands",
        "operator inspection actions execute only as internal read-only actions",
        "mix allbert.channels status uses the shared operator inspection facade"
      ]
    },
    %{
      id: "v0551_eval",
      title: ":v0551 operator console security eval inventory",
      cwd: :core,
      executable: "mix",
      args: [
        "test",
        "test/security/v0551_operator_console_eval_test.exs",
        "test/security/security_eval_case_test.exs"
      ],
      coverage: [
        "v0.55.1 eval rows are wired into EvalInventory",
        "warm slash inspection commands avoid model turns and channel-event writes",
        "warm /channels and cold mix allbert.channels status share one redacted report",
        "operator inspection actions stay absent from intent descriptors and model candidates"
      ]
    }
  ]

  defp release_v0551 do
    env = owned_env("release-v0551", 0)
    home = env_value(env, "ALLBERT_HOME")
    database = env_value(env, "DATABASE_PATH")
    evidence_dir = Path.join(home, "release_evidence/v0551")
    File.mkdir_p!(evidence_dir)

    started_at = DateTime.utc_now()
    results = Enum.map(@release_v0551_steps, &run_release_v0551_step(&1, env))
    secret_scan = release_channel_pack_secret_scan(home, "release.v0551")

    status =
      if Enum.all?(results, &(&1.status == "passed")) and secret_scan.status == "passed" do
        "passed"
      else
        "failed"
      end

    evidence = %{
      gate: "mix allbert.test release.v0551",
      version: "v0.55.1",
      status: status,
      generated_at: DateTime.utc_now() |> DateTime.to_iso8601(),
      started_at: DateTime.to_iso8601(started_at),
      allbert_home: home,
      database_path: database,
      evidence_dir: evidence_dir,
      external_network:
        "disabled; operator console commands, warm TUI inspection, and channel status run against local fixtures",
      notes:
        "live warm TUI operator validation remains covered by the v0.55b M5 punchlist in docs/plans/v0.55b-request-flow.md before v0.55.1 closeout",
      steps: results,
      secret_scan: secret_scan
    }

    evidence_path = Path.join(evidence_dir, "release-v0551-#{DateTime.to_unix(started_at)}.json")
    File.write!(evidence_path, Jason.encode!(evidence, pretty: true))
    Mix.shell().info("release.v0551 evidence: #{evidence_path}")

    if status != "passed" do
      Mix.raise("release.v0551 failed; evidence: #{evidence_path}")
    end
  end

  defp run_release_v0551_step(step, env) do
    started = System.monotonic_time(:millisecond)
    cwd = release_step_cwd(step.cwd)

    {output, exit_status} =
      System.cmd(step.executable, step.args, cd: cwd, env: env, stderr_to_stdout: true)

    duration_ms = System.monotonic_time(:millisecond) - started
    print_output("release.v0551 #{step.id}", output)

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

  @release_v056_steps [
    %{
      id: "migrate",
      title: "prepare disposable database",
      cwd: :core,
      executable: "mix",
      args: ["ecto.migrate.allbert", "--quiet"],
      coverage: ["schema boot", "release-owned DATABASE_PATH"]
    },
    %{
      id: "intent_eval_cli_gate",
      title: "deterministic routing corpus and by-surface report",
      cwd: :core,
      executable: "mix",
      args: ["allbert.intent", "eval", "run", "--by-surface"],
      coverage: [
        "routing-accuracy corpus replays deterministically",
        "negative-route, slot, clarify-vs-execute, and by-surface summaries are visible",
        "the routing gate uses committed baseline thresholds"
      ]
    },
    %{
      id: "intent_eval_lifecycle_units",
      title: "descriptor lifecycle, learning, gate, and corpus units",
      cwd: :core,
      executable: "mix",
      args: [
        "test",
        "test/allbert_assist/intent/eval/corpus_completeness_test.exs",
        "test/allbert_assist/intent/eval/corpus_test.exs",
        "test/allbert_assist/intent/eval/runner_test.exs",
        "test/allbert_assist/intent/eval/scorer_test.exs",
        "test/allbert_assist/intent/eval/gate_test.exs",
        "test/allbert_assist/intent/eval/cross_surface_test.exs",
        "test/allbert_assist/intent/optimizer_model_generation_test.exs",
        "test/allbert_assist/intent/learning/miner_test.exs",
        "test/allbert_assist/actions/intent/operator_mutation_actions_test.exs",
        "test/allbert_assist/intent/router_index_reindex_test.exs",
        "test/allbert_assist/actions/intent/operator_read_actions_test.exs"
      ],
      coverage: [
        "descriptor generation stays advisory and redacted",
        "learned-review proposals remain inert until explicit promotion",
        "promotion uses the blocking routing gate and mutates nothing on failure",
        "registration signals can rebuild the index without making internal actions routable"
      ]
    },
    %{
      id: "model_tui_operator_reads",
      title: "model doctor, CLI parity, and warm-TUI read affordance units",
      cwd: :core,
      executable: "mix",
      args: [
        "test",
        "test/allbert_assist/actions/settings_actions_test.exs",
        "test/allbert_assist/channels/tui_intents_models_test.exs",
        "test/allbert_assist/channels/tui_test.exs",
        "test/mix/tasks/allbert_intent_test.exs",
        "test/mix/tasks/allbert_settings_test.exs",
        "test/mix/tasks/allbert_tui_test.exs"
      ],
      coverage: [
        "model doctor reports redacted Settings Central recommendations",
        "mix allbert.intent and mix allbert.settings reuse action DTOs",
        "/intents and /models are slash-only reads backed by Actions.Runner.run/3"
      ]
    },
    %{
      id: "v056_eval",
      title: ":v056 intent routing security eval inventory",
      cwd: :core,
      executable: "mix",
      args: [
        "test",
        "test/security/v056_intent_eval_test.exs",
        "test/security/security_eval_case_test.exs"
      ],
      coverage: [
        "v0.56 eval rows are wired into EvalInventory",
        "operator read/mutation actions stay internal and non-routable",
        "model recommendations and generated descriptors grant no authority",
        "release evidence checks redaction, rollback, and gate failure behavior"
      ]
    }
  ]

  defp release_v056 do
    env = owned_env("release-v056", 0)
    home = env_value(env, "ALLBERT_HOME")
    database = env_value(env, "DATABASE_PATH")
    evidence_dir = Path.join(home, "release_evidence/v056")
    File.mkdir_p!(evidence_dir)

    started_at = DateTime.utc_now()
    results = Enum.map(@release_v056_steps, &run_release_v056_step(&1, env))
    secret_scan = release_channel_pack_secret_scan(home, "release.v056")

    status =
      if Enum.all?(results, &(&1.status == "passed")) and secret_scan.status == "passed" do
        "passed"
      else
        "failed"
      end

    evidence = %{
      gate: "mix allbert.test release.v056",
      version: "v0.56",
      status: status,
      generated_at: DateTime.utc_now() |> DateTime.to_iso8601(),
      started_at: DateTime.to_iso8601(started_at),
      allbert_home: home,
      database_path: database,
      evidence_dir: evidence_dir,
      external_network:
        "disabled; deterministic corpus, descriptor lifecycle, model doctor, and TUI read-affordance units run against local fixtures and Req.Test",
      notes:
        "live Ollama preflight and one warm mix allbert.tui operator validation remain covered by v0.56 M14 before closeout",
      steps: results,
      secret_scan: secret_scan
    }

    evidence_path = Path.join(evidence_dir, "release-v056-#{DateTime.to_unix(started_at)}.json")
    File.write!(evidence_path, Jason.encode!(evidence, pretty: true))
    Mix.shell().info("release.v056 evidence: #{evidence_path}")

    if status != "passed" do
      Mix.raise("release.v056 failed; evidence: #{evidence_path}")
    end
  end

  defp run_release_v056_step(step, env) do
    started = System.monotonic_time(:millisecond)
    cwd = release_step_cwd(step.cwd)

    {output, exit_status} =
      System.cmd(step.executable, step.args, cd: cwd, env: env, stderr_to_stdout: true)

    duration_ms = System.monotonic_time(:millisecond) - started
    print_output("release.v056 #{step.id}", output)

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

  @release_v057_steps [
    %{
      id: "migrate",
      title: "prepare disposable database",
      cwd: :core,
      executable: "mix",
      args: ["ecto.migrate.allbert", "--quiet"],
      coverage: ["schema boot", "release-owned DATABASE_PATH"]
    },
    %{
      id: "coding_m0_m9_units",
      title: "Pi-mode coding contracts, tools, streaming, trust, TUI, and remediation units",
      cwd: :core,
      executable: "mix",
      args: [
        "test",
        "test/allbert_assist/coding/m0_contracts_test.exs",
        "test/allbert_assist/coding/m1_read_search_actions_test.exs",
        "test/allbert_assist/coding/m2_write_edit_actions_test.exs",
        "test/allbert_assist/coding/m3_bash_action_test.exs",
        "test/allbert_assist/coding/m4_stream_rendering_test.exs",
        "test/allbert_assist/coding/m5_async_turn_test.exs",
        "test/allbert_assist/coding/m6_cancel_steer_test.exs",
        "test/allbert_assist/coding/m7_trust_approval_test.exs",
        "test/allbert_assist/coding/m8_session_slash_test.exs",
        "test/allbert_assist/coding/m9_streaming_turn_test.exs",
        "test/allbert_assist/channels/tui_test.exs",
        "test/mix/tasks/allbert_tui_test.exs",
        "test/mix/tasks/allbert_test_task_test.exs"
      ],
      coverage: [
        "coding actions resolve through Actions.Runner.run/3 and stay cwd-jailed",
        "write/edit/bash effects remain confirmation-gated with clean model payloads",
        "stream events, live provider streams, provider cancel, async turns, cancellation, and queued steering stay supervised",
        "local-coding trust tier, approval modes, grants, and slash/session controls preserve Security Central authority"
      ]
    },
    %{
      id: "v057_eval",
      title: ":v057 Pi-mode coding security eval inventory",
      cwd: :core,
      executable: "mix",
      args: [
        "test",
        "test/security/v057_coding_eval_test.exs",
        "test/security/security_eval_case_test.exs"
      ],
      coverage: [
        "v0.57 eval rows are wired into EvalInventory",
        "coding tools remain policy-bounded registered actions",
        "split payloads do not leak TUI diff context into model payloads",
        "slash commands are non-routable session controls and grant no authority"
      ]
    }
  ]

  defp release_v057 do
    env = owned_env("release-v057", 0)
    home = env_value(env, "ALLBERT_HOME")
    database = env_value(env, "DATABASE_PATH")
    evidence_dir = Path.join(home, "release_evidence/v057")
    File.mkdir_p!(evidence_dir)

    started_at = DateTime.utc_now()
    results = Enum.map(@release_v057_steps, &run_release_v057_step(&1, env))
    secret_scan = release_channel_pack_secret_scan(home, "release.v057")

    status =
      if Enum.all?(results, &(&1.status == "passed")) and secret_scan.status == "passed" do
        "passed"
      else
        "failed"
      end

    evidence = %{
      gate: "mix allbert.test release.v057",
      version: "v0.57",
      status: status,
      generated_at: DateTime.utc_now() |> DateTime.to_iso8601(),
      started_at: DateTime.to_iso8601(started_at),
      allbert_home: home,
      database_path: database,
      evidence_dir: evidence_dir,
      external_network:
        "disabled; deterministic Pi-mode coding units and security evals run against local fixtures only",
      notes:
        "warm mix allbert.tui operator validation remains required by the v0.57 request flow before release closeout",
      steps: results,
      secret_scan: secret_scan
    }

    evidence_path = Path.join(evidence_dir, "release-v057-#{DateTime.to_unix(started_at)}.json")
    File.write!(evidence_path, Jason.encode!(evidence, pretty: true))
    Mix.shell().info("release.v057 evidence: #{evidence_path}")

    if status != "passed" do
      Mix.raise("release.v057 failed; evidence: #{evidence_path}")
    end
  end

  defp run_release_v057_step(step, env) do
    started = System.monotonic_time(:millisecond)
    cwd = release_step_cwd(step.cwd)

    {output, exit_status} =
      System.cmd(step.executable, step.args, cd: cwd, env: env, stderr_to_stdout: true)

    duration_ms = System.monotonic_time(:millisecond) - started
    print_output("release.v057 #{step.id}", output)

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

  @release_v058_steps [
    %{
      id: "migrate",
      title: "prepare disposable database",
      cwd: :core,
      executable: "mix",
      args: ["ecto.migrate.allbert", "--quiet"],
      coverage: ["schema boot", "release-owned DATABASE_PATH"]
    },
    %{
      id: "surface_contract_units",
      title: "surface renderer, event/audit, catalog, invocation, and identity units",
      cwd: :core,
      executable: "mix",
      args: [
        "test",
        "test/allbert_assist/surface/renderer_test.exs",
        "test/allbert_assist/surface/event_recorder_test.exs",
        "test/allbert_assist/surface/catalog_test.exs",
        "test/allbert_assist/workspace/catalog_test.exs",
        "test/allbert_assist/actions/helper_test.exs",
        "test/allbert_assist/surfaces/context_builder_test.exs",
        "test/allbert_assist/public_protocol/result_readback_test.exs",
        "test/allbert_assist/public_protocol/mcp_stdio_server_test.exs"
      ],
      coverage: [
        "one Surface.Renderer drives surface payload selection and redaction",
        "surface events/audits record surface_id and terminal runtime status",
        "catalog-owned workspace components and destinations stay uniform",
        "shared invocation/context helpers preserve identity and action-backed reads",
        "public protocol readback uses the same redacted DTO shape"
      ]
    },
    %{
      id: "settings_enforcement_units",
      title: "Settings Central guard and operator-tunable schema units",
      cwd: :root,
      executable: "mix",
      args: [
        "test",
        "apps/allbert_assist/test/allbert_assist/settings/settings_central_no_bypass_check_test.exs",
        "apps/allbert_assist/test/allbert_assist/settings/public_surface_schema_test.exs",
        "apps/allbert_assist/test/allbert_assist/actions/settings_actions_test.exs",
        "apps/allbert_assist/test/allbert_assist/actions/channels/list_channels_test.exs"
      ],
      coverage: [
        "operator-tunable config bypasses are caught by the Credo guard",
        "new v0.58 keys are schema-backed and safe-write validated",
        "settings/channel operator reports are surface-policy bounded"
      ]
    },
    %{
      id: "web_catalog_design_units",
      title: "web catalog, design-system, accessibility, responsive, and shell units",
      cwd: :web,
      executable: "mix",
      args: [
        "test",
        "test/allbert_assist_web/workspace/design_system_tokens_test.exs",
        "test/allbert_assist_web/workspace/components/patterns_test.exs",
        "test/allbert_assist_web/workspace/accessibility_test.exs",
        "test/allbert_assist_web/workspace/responsive_test.exs",
        "test/allbert_assist_web/workspace/renderer_test.exs",
        "test/allbert_assist_web/live/workspace_live_test.exs:84",
        "test/allbert_assist_web/live/workspace_live_test.exs:491",
        "test/allbert_assist_web/live/workspace_live_test.exs:685",
        "test/allbert_assist_web/live/workspace_live_test.exs:1122",
        "test/allbert_assist_web/live/workspace_live_test.exs:1143",
        "test/allbert_assist_web/live/workspace_live_test.exs:2176"
      ],
      coverage: [
        "global tokens, component variants, and shared modal pattern stay enforced",
        "chat-primary shell, Conversations label, launcher, canvas drawer, and mobile states render",
        "ephemerals render as dialogs and fragments enter through the catalog shell",
        "operator panels render through the web renderer without raw endpoint/secret exposure"
      ]
    },
    %{
      id: "operator_panel_policy_units",
      title: "v0.56 operator DTO panels and surface-policy units",
      cwd: :core,
      executable: "mix",
      args: [
        "test",
        "test/allbert_assist/actions/intent/operator_read_actions_test.exs",
        "test/allbert_assist/actions/intent/operator_mutation_actions_test.exs",
        "test/allbert_assist/actions/surface_policy_actions_test.exs",
        "test/mix/tasks/allbert_intent_test.exs",
        "test/allbert_assist/actions/registry_test.exs"
      ],
      coverage: [
        "Intents panel DTOs reuse v0.56 registered operator actions",
        "promotion affordances remain gated and non-routable",
        "mix allbert.intent reports rejected gate outcomes without crashing",
        "Models and surface-policy DTOs redact secrets and grant no public authority",
        "surface_policy read/update actions stay internal registered actions"
      ]
    },
    %{
      id: "redundancy_helper_units",
      title: "shared helper consolidation regression units",
      cwd: :core,
      executable: "mix",
      args: [
        "test",
        "test/allbert_assist/helper_modules_test.exs",
        "test/allbert_assist/mcp/registry/official_test.exs",
        "test/allbert_assist/mcp/registry/pulse_mcp_test.exs",
        "test/allbert_assist/tools/discovery_test.exs",
        "test/allbert_assist/tools/mcp_registry_source_test.exs",
        "test/allbert_assist/tools/finder_test.exs",
        "test/allbert_assist/actions/mcp_connect_actions_test.exs",
        "test/allbert_assist/workflows/expander_test.exs",
        "test/allbert_assist/actions/plan_build_actions_test.exs"
      ],
      coverage: [
        "shared mixed-key, stringify, limit, and setting helpers preserve prior behavior",
        "MCP registry/connect/discovery, workflow expansion, and Plan-Build callers stay stable"
      ]
    },
    %{
      id: "v058_eval",
      title: ":v058 surface consistency security eval inventory",
      cwd: :core,
      executable: "mix",
      args: [
        "test",
        "test/security/v058_surface_consistency_eval_test.exs",
        "test/security/security_eval_case_test.exs",
        "test/mix/tasks/allbert_test_task_test.exs"
      ],
      coverage: [
        "v0.58 eval rows are wired into EvalInventory",
        "release.v058 is visible in the Mix task usage",
        "surface, settings, web, panel-policy, and helper consolidation rows remain complete"
      ]
    }
  ]

  defp release_v058 do
    env = owned_env("release-v058", 0)
    home = env_value(env, "ALLBERT_HOME")
    database = env_value(env, "DATABASE_PATH")
    evidence_dir = Path.join(home, "release_evidence/v058")
    File.mkdir_p!(evidence_dir)

    started_at = DateTime.utc_now()
    results = Enum.map(@release_v058_steps, &run_release_v058_step(&1, env))
    secret_scan = release_channel_pack_secret_scan(home, "release.v058")

    status =
      if Enum.all?(results, &(&1.status == "passed")) and secret_scan.status == "passed" do
        "passed"
      else
        "failed"
      end

    evidence = %{
      gate: "mix allbert.test release.v058",
      version: "v0.58",
      status: status,
      generated_at: DateTime.utc_now() |> DateTime.to_iso8601(),
      started_at: DateTime.to_iso8601(started_at),
      allbert_home: home,
      database_path: database,
      evidence_dir: evidence_dir,
      external_network:
        "disabled; deterministic surface, settings, web catalog, operator-panel, surface-policy, and helper-consolidation units run against local fixtures only",
      notes:
        "browser-control/manual operator validation remains required by the v0.58 request flow before closeout",
      steps: results,
      secret_scan: secret_scan
    }

    evidence_path = Path.join(evidence_dir, "release-v058-#{DateTime.to_unix(started_at)}.json")
    File.write!(evidence_path, Jason.encode!(evidence, pretty: true))
    Mix.shell().info("release.v058 evidence: #{evidence_path}")

    if status != "passed" do
      Mix.raise("release.v058 failed; evidence: #{evidence_path}")
    end
  end

  defp run_release_v058_step(step, env) do
    started = System.monotonic_time(:millisecond)
    cwd = release_step_cwd(step.cwd)

    {output, exit_status} =
      System.cmd(step.executable, step.args, cd: cwd, env: env, stderr_to_stdout: true)

    duration_ms = System.monotonic_time(:millisecond) - started
    print_output("release.v058 #{step.id}", output)

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

  @release_v059_steps [
    %{
      id: "migrate",
      title: "prepare disposable database",
      cwd: :core,
      executable: "mix",
      args: ["ecto.migrate.allbert", "--quiet"],
      coverage: ["schema boot", "release-owned DATABASE_PATH"]
    },
    %{
      id: "portability_export_import_units",
      title: "Home export, dry-run import, rollback, and secret-ref units",
      cwd: :core,
      executable: "mix",
      args: [
        "test",
        "test/allbert_assist/portability/export_import_test.exs",
        "test/mix/tasks/allbert_home_test.exs"
      ],
      coverage: [
        "versioned export envelope is redacted",
        "dry-run import writes diagnostics outside the target Home",
        "target Home remains byte-identical",
        "secret references round-trip without values"
      ]
    },
    %{
      id: "settings_version_boot_units",
      title: "Settings version contract and boot-check units",
      cwd: :core,
      executable: "mix",
      args: [
        "test",
        "test/allbert_assist/settings/version_contract_test.exs",
        "test/allbert_assist/actions/security_actions_test.exs",
        "test/mix/tasks/allbert_security_test.exs"
      ],
      coverage: [
        "registered fragments report schema_version=1",
        "additive-only schema diffs are enforced",
        "forward or invalid stored versions fail closed",
        "security status exposes the version-contract boot check without secret refs"
      ]
    },
    %{
      id: "perf_csp_baseline",
      title: "operator perf thresholds and web CSP target",
      cwd: :web,
      executable: "mix",
      args: [
        "test",
        "test/allbert_assist_web/perf_csp_baseline_test.exs",
        "--only",
        "perf_csp_baseline"
      ],
      coverage: [
        "export/import thresholds use max(2s, baseline * 1.25)",
        "boot-check overhead uses max(50ms, baseline * 1.10)",
        "landing and workspace CSP forbid remote wildcards and unsafe-inline"
      ]
    },
    %{
      id: "param_contract_sweep",
      title: "Runner param-contract sweep over shipped catalog",
      cwd: :root,
      executable: "mix",
      args: ["allbert.test", "param-contract-sweep"],
      coverage: [
        "schema-known string keys normalize without atom creation",
        "unknown keys fail redacted before action bodies run",
        "empty-schema and JSON-schema dispositions are explicit",
        "shipped catalog reports unsupported=0"
      ]
    },
    %{
      id: "v059_security_sweep",
      title: "post-M7 v0.59 security and handoff eval rows",
      cwd: :root,
      executable: "mix",
      args: [
        "test",
        "apps/allbert_assist/test/security/v059_sweep_eval_test.exs",
        "apps/allbert_assist/test/security/security_eval_case_test.exs"
      ],
      coverage: [
        "cross-surface v0.40-v0.51 hardening rows remain green",
        "param-contract inventory rows stay wired after Runner enforcement",
        "RC substrate handoff has no v0.61/v0.63/v1.0 drift"
      ]
    },
    %{
      id: "docs_gate",
      title: "docs gate and release-planning whitespace check",
      cwd: :root,
      executable: "mix",
      args: ["allbert.test", "docs"],
      coverage: [
        "git diff --check is clean",
        "docs gate is visible in release evidence"
      ]
    }
  ]

  defp release_v059 do
    env = owned_env("release-v059", 0)
    home = env_value(env, "ALLBERT_HOME")
    database = env_value(env, "DATABASE_PATH")
    evidence_dir = Path.join(home, "release_evidence/v059")
    File.mkdir_p!(evidence_dir)

    started_at = DateTime.utc_now()
    results = Enum.map(@release_v059_steps, &run_release_v059_step(&1, env))
    seed_release_v059_secret_scan_fixture(home)
    secret_scan = release_channel_pack_secret_scan(home, "release.v059")

    status =
      if Enum.all?(results, &(&1.status == "passed")) and secret_scan.status == "passed" do
        "passed"
      else
        "failed"
      end

    evidence = %{
      gate: "mix allbert.test release.v059",
      version: "v0.59",
      status: status,
      generated_at: DateTime.utc_now() |> DateTime.to_iso8601(),
      started_at: DateTime.to_iso8601(started_at),
      allbert_home: home,
      database_path: database,
      evidence_dir: evidence_dir,
      external_network:
        "disabled; deterministic portability, settings-version, perf/CSP, param-contract, and security-sweep units run against local fixtures only",
      notes:
        "post-implementation audit and then manual operator validation remain required before v0.59 closeout",
      steps: results,
      secret_scan: secret_scan
    }

    evidence_path = Path.join(evidence_dir, "release-v059-#{DateTime.to_unix(started_at)}.json")
    File.write!(evidence_path, Jason.encode!(evidence, pretty: true))
    Mix.shell().info("release.v059 evidence: #{evidence_path}")

    if status != "passed" do
      Mix.raise("release.v059 failed; evidence: #{evidence_path}")
    end
  end

  defp run_release_v059_step(step, env) do
    started = System.monotonic_time(:millisecond)
    cwd = release_step_cwd(step.cwd)

    {output, exit_status} =
      System.cmd(step.executable, step.args, cd: cwd, env: env, stderr_to_stdout: true)

    duration_ms = System.monotonic_time(:millisecond) - started
    print_output("release.v059 #{step.id}", output)

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

  defp cleanup_release_v046_evidence!(evidence_dir) do
    evidence_dir
    |> Path.join("release-v046-*.json")
    |> Path.wildcard()
    |> Enum.each(&File.rm!/1)
  end

  defp cleanup_release_v047_evidence!(evidence_dir) do
    evidence_dir
    |> Path.join("release-v047-*.json")
    |> Path.wildcard()
    |> Enum.each(&File.rm!/1)
  end

  defp cleanup_release_v047b_evidence!(evidence_dir) do
    evidence_dir
    |> Path.join("release-v047b-*.json")
    |> Path.wildcard()
    |> Enum.each(&File.rm!/1)
  end

  defp cleanup_release_v048_evidence!(evidence_dir) do
    evidence_dir
    |> Path.join("release-v048-*.json")
    |> Path.wildcard()
    |> Enum.each(&File.rm!/1)
  end

  defp cleanup_release_v049_evidence!(evidence_dir) do
    evidence_dir
    |> Path.join("release-v049-*.json")
    |> Path.wildcard()
    |> Enum.each(&File.rm!/1)
  end

  defp cleanup_release_v050_evidence!(evidence_dir) do
    evidence_dir
    |> Path.join("release-v050-*.json")
    |> Path.wildcard()
    |> Enum.each(&File.rm!/1)
  end

  defp cleanup_release_v050b_evidence!(evidence_dir) do
    evidence_dir
    |> Path.join("release-v050b-*.json")
    |> Path.wildcard()
    |> Enum.each(&File.rm!/1)
  end

  defp cleanup_release_v051_evidence!(evidence_dir) do
    evidence_dir
    |> Path.join("release-v051-*.json")
    |> Path.wildcard()
    |> Enum.each(&File.rm!/1)
  end

  defp cleanup_release_v052_evidence!(evidence_dir) do
    evidence_dir
    |> Path.join("release-v052-*.json")
    |> Path.wildcard()
    |> Enum.each(&File.rm!/1)
  end

  defp cleanup_release_v053_evidence!(evidence_dir) do
    evidence_dir
    |> Path.join("release-v053-*.json")
    |> Path.wildcard()
    |> Enum.each(&File.rm!/1)
  end

  defp run_release_v051_step(step, env) do
    started = System.monotonic_time(:millisecond)
    cwd = release_step_cwd(step.cwd)

    {output, exit_status} =
      System.cmd(step.executable, step.args,
        cd: cwd,
        env: env,
        stderr_to_stdout: true
      )

    duration_ms = System.monotonic_time(:millisecond) - started
    print_output("release.v051 #{step.id}", output)

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

  defp run_release_v052_step(step, env) do
    started = System.monotonic_time(:millisecond)
    cwd = release_step_cwd(step.cwd)

    {output, exit_status} =
      System.cmd(step.executable, step.args,
        cd: cwd,
        env: env,
        stderr_to_stdout: true
      )

    duration_ms = System.monotonic_time(:millisecond) - started
    print_output("release.v052 #{step.id}", output)

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

  defp run_release_v053_step(step, env) do
    started = System.monotonic_time(:millisecond)
    cwd = release_step_cwd(step.cwd)

    {output, exit_status} =
      System.cmd(step.executable, step.args,
        cd: cwd,
        env: env,
        stderr_to_stdout: true
      )

    duration_ms = System.monotonic_time(:millisecond) - started
    print_output("release.v053 #{step.id}", output)

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

  defp run_release_v050b_step(step, env) do
    started = System.monotonic_time(:millisecond)
    cwd = release_step_cwd(step.cwd)

    {output, exit_status} =
      System.cmd(step.executable, step.args,
        cd: cwd,
        env: env,
        stderr_to_stdout: true
      )

    duration_ms = System.monotonic_time(:millisecond) - started
    print_output("release.v050b #{step.id}", output)

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

  defp run_release_v050_step(step, env) do
    started = System.monotonic_time(:millisecond)
    cwd = release_step_cwd(step.cwd)

    {output, exit_status} =
      System.cmd(step.executable, step.args,
        cd: cwd,
        env: env,
        stderr_to_stdout: true
      )

    duration_ms = System.monotonic_time(:millisecond) - started
    print_output("release.v050 #{step.id}", output)

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

  defp run_release_v049_step(step, env) do
    started = System.monotonic_time(:millisecond)
    cwd = release_step_cwd(step.cwd)

    {output, exit_status} =
      System.cmd(step.executable, step.args,
        cd: cwd,
        env: env,
        stderr_to_stdout: true
      )

    duration_ms = System.monotonic_time(:millisecond) - started
    print_output("release.v049 #{step.id}", output)

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

  defp run_release_v048_step(step, env) do
    started = System.monotonic_time(:millisecond)
    cwd = release_step_cwd(step.cwd)

    {output, exit_status} =
      System.cmd(step.executable, step.args,
        cd: cwd,
        env: env,
        stderr_to_stdout: true
      )

    duration_ms = System.monotonic_time(:millisecond) - started
    print_output("release.v048 #{step.id}", output)

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

  defp run_release_v047b_step(step, env) do
    started = System.monotonic_time(:millisecond)
    cwd = release_step_cwd(step.cwd)

    {output, exit_status} =
      System.cmd(step.executable, step.args,
        cd: cwd,
        env: env,
        stderr_to_stdout: true
      )

    duration_ms = System.monotonic_time(:millisecond) - started
    print_output("release.v047b #{step.id}", output)

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

  defp run_release_v047_step(step, env) do
    started = System.monotonic_time(:millisecond)
    cwd = release_step_cwd(step.cwd)

    {output, exit_status} =
      System.cmd(step.executable, step.args,
        cd: cwd,
        env: env,
        stderr_to_stdout: true
      )

    duration_ms = System.monotonic_time(:millisecond) - started
    print_output("release.v047 #{step.id}", output)

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

  defp run_release_v046_step(step, env) do
    started = System.monotonic_time(:millisecond)
    cwd = release_step_cwd(step.cwd)

    {output, exit_status} =
      System.cmd(step.executable, step.args,
        cd: cwd,
        env: env,
        stderr_to_stdout: true
      )

    duration_ms = System.monotonic_time(:millisecond) - started
    print_output("release.v046 #{step.id}", output)

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

  defp seed_release_v059_secret_scan_fixture(home) do
    fixture_path = Path.join([home, "traces", "release-v059-secret-scan-fixture.txt"])

    fixture_path
    |> Path.dirname()
    |> File.mkdir_p!()

    File.write!(
      fixture_path,
      [
        "release.v059 secret-scan fixture\n",
        "scan_probe=non_empty_file_set\n",
        "redaction=[REDACTED]\n"
      ]
    )
  end

  defp release_step_cwd(:core), do: app_cwd(:core)
  defp release_step_cwd(:web), do: app_cwd(:web)
  defp release_step_cwd(:root), do: root()

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

  defp release_v046_secret_scan(home) do
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

    print_output("release.v046 secret_scan", Jason.encode!(result, pretty: true))
    result
  end

  defp release_v047_secret_scan(home) do
    Enum.each(
      [
        Path.join(home, "settings"),
        Path.join(home, "memory/traces"),
        Path.join(home, "drafts"),
        Path.join(home, "workflows"),
        Path.join(home, "skills")
      ],
      &File.mkdir_p!/1
    )

    roots =
      [
        Path.join(home, "settings"),
        Path.join(home, "memory/traces"),
        Path.join(home, "drafts"),
        Path.join(home, "workflows"),
        Path.join(home, "skills"),
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

    print_output("release.v047 secret_scan", Jason.encode!(result, pretty: true))
    result
  end

  defp release_v047b_secret_scan(home) do
    Enum.each(
      [
        Path.join(home, "settings"),
        Path.join(home, "memory/traces"),
        Path.join(home, "drafts"),
        Path.join(home, "dynamic_plugins/drafts"),
        Path.join(home, "marketplace"),
        Path.join(home, "confirmations"),
        Path.join(home, "traces")
      ],
      &File.mkdir_p!/1
    )

    roots =
      [
        Path.join(home, "settings"),
        Path.join(home, "memory/traces"),
        Path.join(home, "drafts"),
        Path.join(home, "dynamic_plugins/drafts"),
        Path.join(home, "marketplace"),
        Path.join(home, "confirmations"),
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

    print_output("release.v047b secret_scan", Jason.encode!(result, pretty: true))
    result
  end

  defp release_v048_secret_scan(home) do
    Enum.each(
      [
        Path.join(home, "settings"),
        Path.join(home, "memory/traces"),
        Path.join(home, "confirmations"),
        Path.join(home, "traces"),
        Path.join(home, "tmp/voice-captures"),
        Path.join(home, "tmp/telegram-voice"),
        Path.join(home, "tmp/voice-synthesis")
      ],
      &File.mkdir_p!/1
    )

    roots =
      [
        Path.join(home, "settings"),
        Path.join(home, "memory/traces"),
        Path.join(home, "confirmations"),
        Path.join(home, "traces"),
        Path.join(home, "tmp/voice-captures"),
        Path.join(home, "tmp/telegram-voice"),
        Path.join(home, "tmp/voice-synthesis")
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

    print_output("release.v048 secret_scan", Jason.encode!(result, pretty: true))
    result
  end

  defp release_v049_secret_scan(home) do
    Enum.each(
      [
        Path.join(home, "settings"),
        Path.join(home, "memory/traces"),
        Path.join(home, "confirmations"),
        Path.join(home, "traces"),
        Path.join(home, "cache/browser"),
        Path.join(home, "tmp/image-inputs"),
        Path.join(home, "tmp/generated-images"),
        Path.join(home, "images"),
        Path.join(home, "generated_images")
      ],
      &File.mkdir_p!/1
    )

    roots =
      [
        Path.join(home, "settings"),
        Path.join(home, "memory/traces"),
        Path.join(home, "confirmations"),
        Path.join(home, "traces"),
        Path.join(home, "cache/browser"),
        Path.join(home, "tmp/image-inputs"),
        Path.join(home, "tmp/generated-images"),
        Path.join(home, "images"),
        Path.join(home, "generated_images")
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

    print_output("release.v049 secret_scan", Jason.encode!(result, pretty: true))
    result
  end

  defp release_v050_secret_scan(home) do
    Enum.each(
      [
        Path.join(home, "settings"),
        Path.join(home, "memory/traces"),
        Path.join(home, "confirmations"),
        Path.join(home, "traces"),
        Path.join(home, "artifacts"),
        Path.join(home, "audio"),
        Path.join(home, "images"),
        Path.join(home, "generated_images"),
        Path.join(home, "tmp/voice-captures"),
        Path.join(home, "tmp/image-inputs"),
        Path.join(home, "tmp/generated-images"),
        Path.join(home, "cache/browser")
      ],
      &File.mkdir_p!/1
    )

    roots =
      [
        Path.join(home, "settings"),
        Path.join(home, "memory/traces"),
        Path.join(home, "confirmations"),
        Path.join(home, "traces"),
        Path.join(home, "artifacts"),
        Path.join(home, "audio"),
        Path.join(home, "images"),
        Path.join(home, "generated_images"),
        Path.join(home, "tmp/voice-captures"),
        Path.join(home, "tmp/image-inputs"),
        Path.join(home, "tmp/generated-images"),
        Path.join(home, "cache/browser")
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

    print_output("release.v050 secret_scan", Jason.encode!(result, pretty: true))
    result
  end

  defp release_v050b_secret_scan(home) do
    Enum.each(
      [
        Path.join(home, "settings"),
        Path.join(home, "memory/traces"),
        Path.join(home, "confirmations"),
        Path.join(home, "traces"),
        Path.join(home, "artifacts"),
        Path.join(home, "audio"),
        Path.join(home, "images"),
        Path.join(home, "generated_images"),
        Path.join(home, "tmp/voice-captures"),
        Path.join(home, "tmp/image-inputs"),
        Path.join(home, "tmp/generated-images"),
        Path.join(home, "cache/browser")
      ],
      &File.mkdir_p!/1
    )

    roots =
      [
        Path.join(home, "settings"),
        Path.join(home, "memory/traces"),
        Path.join(home, "confirmations"),
        Path.join(home, "traces"),
        Path.join(home, "artifacts"),
        Path.join(home, "audio"),
        Path.join(home, "images"),
        Path.join(home, "generated_images"),
        Path.join(home, "tmp/voice-captures"),
        Path.join(home, "tmp/image-inputs"),
        Path.join(home, "tmp/generated-images"),
        Path.join(home, "cache/browser")
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

    print_output("release.v050b secret_scan", Jason.encode!(result, pretty: true))
    result
  end

  defp release_v051_secret_scan(home) do
    Enum.each(
      [
        Path.join(home, "settings"),
        Path.join(home, "memory/traces"),
        Path.join(home, "confirmations"),
        Path.join(home, "traces"),
        Path.join(home, "artifacts"),
        Path.join(home, "audio"),
        Path.join(home, "images"),
        Path.join(home, "generated_images"),
        Path.join(home, "tmp/voice-captures"),
        Path.join(home, "tmp/image-inputs"),
        Path.join(home, "tmp/generated-images"),
        Path.join(home, "cache/browser")
      ],
      &File.mkdir_p!/1
    )

    roots =
      [
        Path.join(home, "settings"),
        Path.join(home, "memory/traces"),
        Path.join(home, "confirmations"),
        Path.join(home, "traces"),
        Path.join(home, "artifacts"),
        Path.join(home, "audio"),
        Path.join(home, "images"),
        Path.join(home, "generated_images"),
        Path.join(home, "tmp/voice-captures"),
        Path.join(home, "tmp/image-inputs"),
        Path.join(home, "tmp/generated-images"),
        Path.join(home, "cache/browser")
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

    print_output("release.v051 secret_scan", Jason.encode!(result, pretty: true))
    result
  end

  defp release_v052_secret_scan(home) do
    release_channel_pack_secret_scan(home, "release.v052")
  end

  defp release_v053_secret_scan(home) do
    release_channel_pack_secret_scan(home, "release.v053")
  end

  defp release_channel_pack_secret_scan(home, label) do
    Enum.each(
      [
        Path.join(home, "settings"),
        Path.join(home, "memory/traces"),
        Path.join(home, "confirmations"),
        Path.join(home, "traces"),
        Path.join(home, "artifacts"),
        Path.join(home, "audio"),
        Path.join(home, "images"),
        Path.join(home, "generated_images"),
        Path.join(home, "tmp/voice-captures"),
        Path.join(home, "tmp/image-inputs"),
        Path.join(home, "tmp/generated-images"),
        Path.join(home, "cache/browser")
      ],
      &File.mkdir_p!/1
    )

    roots =
      [
        Path.join(home, "settings"),
        Path.join(home, "memory/traces"),
        Path.join(home, "confirmations"),
        Path.join(home, "traces"),
        Path.join(home, "artifacts"),
        Path.join(home, "audio"),
        Path.join(home, "images"),
        Path.join(home, "generated_images"),
        Path.join(home, "tmp/voice-captures"),
        Path.join(home, "tmp/image-inputs"),
        Path.join(home, "tmp/generated-images"),
        Path.join(home, "cache/browser")
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

    print_output("#{label} secret_scan", Jason.encode!(result, pretty: true))
    result
  end

  defp release_v050b_browser_fixture(results) do
    output =
      results
      |> Enum.find(&(&1.id == "artifact_browser_smoke_seed"))
      |> case do
        nil -> ""
        result -> Map.get(result, :redacted_output_tail, "")
      end

    %{
      artifact_sha256: release_output_capture(output, ~r/^ARTIFACT_SHA=([a-f0-9]{64})$/m),
      thread_id: release_output_capture(output, ~r/^THREAD_ID=([^\n]+)$/m),
      workspace_url: release_output_capture(output, ~r/^WORKSPACE_URL=([^\n]+)$/m),
      detail_url: release_output_capture(output, ~r/^DETAIL_URL=([^\n]+)$/m)
    }
  end

  defp release_output_capture(output, regex) do
    case Regex.run(regex, output) do
      [_match, value] -> value
      _missing -> nil
    end
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
    Mix.shell().info("- browser_research_delegate")
    Mix.shell().info("- docker_sandbox")
    Mix.shell().info("- docker_full_gate")
    Mix.shell().info("- telegram (delivery; Telegram only)")
    Mix.shell().info("- email (delivery; email only)")
    Mix.shell().info("- inbound_telegram (inbound; Telegram only)")
    Mix.shell().info("- inbound_email (inbound; email only)")
    Mix.shell().info("- matrix (delivery; Matrix only)")
    Mix.shell().info("- inbound_matrix (inbound; Matrix only)")
    Mix.shell().info("- whatsapp (WhatsApp only)")
    Mix.shell().info("- signal (Signal only)")
    Mix.shell().info("- discord (delivery; Discord only)")
    Mix.shell().info("- slack (delivery; Slack only)")
    Mix.shell().info("- inbound_discord (inbound; Discord only)")
    Mix.shell().info("- inbound_slack (inbound; Slack only)")
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

  defp run_external_smoke(["browser_research_delegate"]) do
    run_cmd!(
      "external-smoke browser_research_delegate",
      app_cwd(:core),
      "mix",
      ["test", "test/external/browser_research_delegate_smoke_test.exs"],
      [
        {"ALLBERT_BROWSER_RESEARCH_DELEGATE_EXTERNAL_SMOKE", "1"}
        | owned_env("external-smoke-browser-research-delegate", 0)
      ]
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

  defp run_external_smoke(["telegram"]), do: run_delivery_smoke("telegram")
  defp run_external_smoke(["email"]), do: run_delivery_smoke("email")
  defp run_external_smoke(["inbound_telegram"]), do: run_inbound_smoke("telegram")
  defp run_external_smoke(["inbound_email"]), do: run_inbound_smoke("email")
  defp run_external_smoke(["matrix"]), do: run_matrix_smoke()
  defp run_external_smoke(["inbound_matrix"]), do: run_matrix_inbound_smoke()
  defp run_external_smoke(["whatsapp"]), do: run_whatsapp_smoke()
  defp run_external_smoke(["signal"]), do: run_signal_smoke()
  defp run_external_smoke(["discord"]), do: run_delivery_smoke("discord")
  defp run_external_smoke(["slack"]), do: run_delivery_smoke("slack")
  defp run_external_smoke(["inbound_discord"]), do: run_inbound_smoke("discord")
  defp run_external_smoke(["inbound_slack"]), do: run_inbound_smoke("slack")

  defp run_external_smoke(args) do
    Mix.raise(
      "unknown external smoke #{Enum.join(args, " ")}; run `mix allbert.test external-smoke list`"
    )
  end

  defp run_matrix_smoke do
    run_cmd!(
      "external-smoke matrix",
      app_cwd(:core),
      "mix",
      ["test", "test/external/matrix_smoke_test.exs"],
      [{"ALLBERT_MATRIX_EXTERNAL_SMOKE", "1"} | owned_env("external-smoke-matrix", 0)]
    )
  end

  defp run_matrix_inbound_smoke do
    run_cmd!(
      "external-smoke matrix-inbound",
      app_cwd(:core),
      "mix",
      ["test", "test/external/matrix_inbound_smoke_test.exs"],
      [
        {"ALLBERT_MATRIX_INBOUND_EXTERNAL_SMOKE", "1"}
        | owned_env("external-smoke-inbound-matrix", 0)
      ],
      stream?: true
    )
  end

  defp run_whatsapp_smoke do
    run_cmd!(
      "external-smoke whatsapp",
      app_cwd(:core),
      "mix",
      ["test", "test/external/whatsapp_smoke_test.exs"],
      [{"ALLBERT_WHATSAPP_EXTERNAL_SMOKE", "1"} | owned_env("external-smoke-whatsapp", 0)]
    )
  end

  defp run_signal_smoke do
    run_cmd!(
      "external-smoke signal",
      app_cwd(:core),
      "mix",
      ["test", "test/external/signal_smoke_test.exs"],
      [{"ALLBERT_SIGNAL_EXTERNAL_SMOKE", "1"} | owned_env("external-smoke-signal", 0)]
    )
  end

  defp run_delivery_smoke(providers) when providers in ["discord", "slack"] do
    slug = String.replace(providers, ",", "-")

    run_cmd!(
      "external-smoke channel-delivery (#{providers})",
      app_cwd(:core),
      "mix",
      ["test", "test/external/discord_slack_smoke_test.exs"],
      [
        {"ALLBERT_DISCORD_SLACK_EXTERNAL_SMOKE", "1"},
        {"ALLBERT_SMOKE_PROVIDERS", providers}
        | owned_env("external-smoke-delivery-#{slug}", 0)
      ]
    )
  end

  defp run_delivery_smoke(providers) when providers in ["telegram", "email"] do
    slug = String.replace(providers, ",", "-")

    run_cmd!(
      "external-smoke telegram-email-delivery (#{providers})",
      app_cwd(:core),
      "mix",
      ["test", "test/external/telegram_email_smoke_test.exs"],
      [
        {"ALLBERT_TELEGRAM_EMAIL_EXTERNAL_SMOKE", "1"},
        {"ALLBERT_SMOKE_PROVIDERS", providers}
        | owned_env("external-smoke-delivery-#{slug}", 0)
      ]
    )
  end

  defp run_inbound_smoke(providers) when providers in ["discord", "slack"] do
    slug = String.replace(providers, ",", "-")

    run_cmd!(
      "external-smoke channel-inbound (#{providers})",
      app_cwd(:core),
      "mix",
      ["test", "test/external/messaging_channel_inbound_smoke_test.exs"],
      [
        {"ALLBERT_MESSAGING_CHANNEL_INBOUND_EXTERNAL_SMOKE", "1"},
        {"ALLBERT_SMOKE_PROVIDERS", providers}
        | owned_env("external-smoke-inbound-#{slug}", 0)
      ],
      stream?: true
    )
  end

  defp run_inbound_smoke(providers) when providers in ["telegram", "email"] do
    slug = String.replace(providers, ",", "-")

    run_cmd!(
      "external-smoke telegram-email-inbound (#{providers})",
      app_cwd(:core),
      "mix",
      ["test", "test/external/telegram_email_inbound_smoke_test.exs"],
      [
        {"ALLBERT_TELEGRAM_EMAIL_INBOUND_EXTERNAL_SMOKE", "1"},
        {"ALLBERT_SMOKE_PROVIDERS", providers}
        | owned_env("external-smoke-inbound-#{slug}", 0)
      ],
      stream?: true
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
            {:ok, label, migrate_output <> empty_partition_message(lane)}

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

  defp empty_partition_message(lane),
    do: "no #{lane} tests assigned to this partition\n"

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
    stream? = Keyword.get(opts, :stream?, false)

    {output, status} =
      if stream? do
        Mix.shell().info("==> #{label}")

        System.cmd(executable, args,
          cd: cwd,
          env: env,
          stderr_to_stdout: true,
          into: IO.stream(:stdio, :line)
        )
      else
        System.cmd(executable, args, cd: cwd, env: env, stderr_to_stdout: true)
      end

    unless stream? do
      print_output(label, output)
    end

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
    Enum.find_value(@owner_prefixes, :unknown, fn {prefix, owner} ->
      if String.starts_with?(path, prefix), do: owner
    end)
  end

  defp app_cwd(owner)
       when owner in [
              :core,
              :stocksage,
              :telegram,
              :email,
              :discord,
              :slack,
              :matrix,
              :whatsapp,
              :signal,
              :notes_files
            ] do
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
      mix allbert.test param-contract-sweep
      mix allbert.test release
      mix allbert.test release.v042
      mix allbert.test release.v043
      mix allbert.test release.v044
      mix allbert.test release.v045
      mix allbert.test release.v046
      mix allbert.test release.v047
      mix allbert.test release.v047b
      mix allbert.test release.v048
      mix allbert.test release.v049
      mix allbert.test release.v050
      mix allbert.test release.v050b
      mix allbert.test release.v051
      mix allbert.test release.v052
      mix allbert.test release.v053
      mix allbert.test release.v054
      mix allbert.test release.v055
      mix allbert.test release.v0551
      mix allbert.test release.v056
      mix allbert.test release.v057
      mix allbert.test release.v058
      mix allbert.test release.v059
      mix allbert.test external-smoke list
      mix allbert.test external-smoke -- browser_research
      mix allbert.test external-smoke -- browser_research_delegate
      mix allbert.test external-smoke -- docker_sandbox
      mix allbert.test external-smoke -- docker_full_gate
      mix allbert.test external-smoke -- telegram
      mix allbert.test external-smoke -- email
      mix allbert.test external-smoke -- inbound_telegram
      mix allbert.test external-smoke -- inbound_email
      mix allbert.test external-smoke -- matrix
      mix allbert.test external-smoke -- inbound_matrix
      mix allbert.test external-smoke -- whatsapp
      mix allbert.test external-smoke -- signal
      mix allbert.test external-smoke -- discord
      mix allbert.test external-smoke -- slack
      mix allbert.test external-smoke -- inbound_discord
      mix allbert.test external-smoke -- inbound_slack

    `mix precommit` is a compatibility shortcut for `mix allbert.test commit`;
    release evidence is `mix allbert.test release`.
    """)
  end
end
