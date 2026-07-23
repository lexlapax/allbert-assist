defmodule Mix.Tasks.Allbert.Test do
  @moduledoc """
  Run Allbert's developer-facing test gates.

  ## Usage

      mix allbert.test docs
      mix allbert.test inventory [--output PATH] [--check-tags] [--manifest] [--check-manifest]
      mix allbert.test focused -- FILE [FILE...]
      mix allbert.test commit
      mix allbert.test prepush [--partitions N]
      mix allbert.test fast-local [--core-lanes] [--stocksage-lanes] [--web-lanes] [--partitions N]
      mix allbert.test partition-smoke [--partitions N]
      mix allbert.test serial-core --lane LANE [--partitions N]
      mix allbert.test param-contract-sweep
      mix allbert.test metrics [--ingest-campaign DIR]
      mix allbert.test bench-decide
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
      mix allbert.test release.v060
      mix allbert.test release.v060b
      mix allbert.test release.v061
      mix allbert.test release.v061b
      mix allbert.test release.v062
      mix allbert.test release.v063
      mix allbert.test release.v064
      mix allbert.test release.v065
      mix allbert.test release.v066
      mix allbert.test release.v1
      mix allbert.test release.v11
      mix allbert.test release.v101
      mix allbert.test release.v102
      mix allbert.test release.v103
      mix allbert.test release.v104
      mix allbert.test release.v105
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

  alias AllbertAssist.DevGates.PartitionPacker
  alias AllbertAssist.DevGates.PhaseRunner
  alias AllbertAssist.DevGates.TestManifest
  alias AllbertAssist.DevGates.TestMetrics

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
  def run(args) do
    # M8.10 provenance: stash the operator-visible gate subcommand + args
    # once per VM so every metrics record cites the exact invocation.
    :persistent_term.put({__MODULE__, :invocation}, Enum.join(args, " "))
    do_run(args)
  end

  defp do_run(["docs"]), do: docs()
  defp do_run(["inventory" | rest]), do: inventory(rest)
  defp do_run(["focused" | rest]), do: focused(rest)
  defp do_run(["commit" | rest]), do: commit(rest)
  defp do_run(["prepush" | rest]), do: prepush(rest)
  defp do_run(["fast-local" | rest]), do: fast_local(rest)
  defp do_run(["partition-smoke" | rest]), do: partition_smoke(rest)
  defp do_run(["serial-core" | rest]), do: serial_core(rest)
  defp do_run(["param-contract-sweep"]), do: param_contract_sweep()
  defp do_run(["metrics" | rest]), do: metrics(rest)
  defp do_run(["bench-decide"]), do: bench_decide()
  defp do_run(["release"]), do: release()
  defp do_run(["release.v042"]), do: release_v042()
  defp do_run(["release.v043"]), do: release_v043()
  defp do_run(["release.v044"]), do: release_v044()
  defp do_run(["release.v045"]), do: release_v045()
  defp do_run(["release.v046"]), do: release_v046()
  defp do_run(["release.v047"]), do: release_v047()
  defp do_run(["release.v047b"]), do: release_v047b()
  defp do_run(["release.v048"]), do: release_v048()
  defp do_run(["release.v049"]), do: release_v049()
  defp do_run(["release.v050"]), do: release_v050()
  defp do_run(["release.v050b"]), do: release_v050b()
  defp do_run(["release.v051"]), do: release_v051()
  defp do_run(["release.v052"]), do: release_v052()
  defp do_run(["release.v053"]), do: release_v053()
  defp do_run(["release.v054"]), do: release_v054()
  defp do_run(["release.v055"]), do: release_v055()
  defp do_run(["release.v0551"]), do: release_v0551()
  defp do_run(["release.v056"]), do: release_v056()
  defp do_run(["release.v057"]), do: release_v057()
  defp do_run(["release.v058"]), do: release_v058()
  defp do_run(["release.v059"]), do: release_v059()
  defp do_run(["release.v060"]), do: release_v060()
  defp do_run(["release.v060b"]), do: release_v060b()
  defp do_run(["release.v061"]), do: release_v061()
  defp do_run(["release.v061b"]), do: release_v061b()
  defp do_run(["release.v062"]), do: release_v062()
  defp do_run(["release.v063"]), do: release_v063()
  defp do_run(["release.v064"]), do: release_v064()
  defp do_run(["release.v065"]), do: release_v065()
  defp do_run(["release.v066"]), do: release_v066()
  defp do_run(["release.v1"]), do: release_v1()
  defp do_run(["release.v11"]), do: release_v11()
  defp do_run(["release.v101"]), do: release_v101()
  defp do_run(["release.v102"]), do: release_v102()
  defp do_run(["release.v103"]), do: release_v103()
  defp do_run(["release.v104"]), do: release_v104()
  defp do_run(["release.v105"]), do: release_v105()
  defp do_run(["external-smoke" | rest]), do: external_smoke(rest)
  defp do_run(_args), do: usage!()

  defp docs do
    run_cmd!("docs", root(), "git", ["diff", "--check"], [])
    docs_staleness_check!()
    :ok
  end

  # v0.66 M10 (plan Locked Decision 4): the docs gate fails on doc-currency drift so it
  # cannot silently recur next release. The currency-stamp/pin checks apply to the
  # **user-facing guides** — README.md, docs/README.md, docs/operator/, docs/developer/,
  # docs/design/ — which must not carry hardcoded currency stamps (link CHANGELOG/roadmap
  # instead). docs/plans/ files are version-scoped working records (a plan legitimately
  # names its own version and even describes the stamp patterns in build-progress notes),
  # so they get the **index-completeness** check only — each active plan/handoff must be
  # linked from docs/plans/README.md — not the currency-stamp scan. Archives, samples,
  # generated evidence, and historical plans/ADRs are excluded entirely.
  @docs_active_index_dirs ["docs/operator", "docs/developer", "docs/design"]
  @docs_active_plan_index "docs/plans/README.md"
  # Post-v1.0.0: released version docs live in docs/plans/archives/ (indexed by the
  # README's Archives section); the active set is the living planning docs until the
  # next version's triad is authored.
  @docs_active_plan_files [
    "docs/plans/README.md",
    "docs/plans/roadmap.md",
    "docs/plans/allbert-jido-vision.md",
    "docs/plans/future-features.md",
    "docs/plans/v1.1-plan.md",
    "docs/plans/v1.1-request-flow.md"
  ]

  defp docs_staleness_check! do
    root = root()

    errors =
      []
      |> docs_check_no_currency_stamps(root)
      |> docs_check_indexes(root)

    if errors != [] do
      Mix.raise(
        "docs staleness/index check failed:\n" <>
          Enum.map_join(errors, "\n", &("  - " <> &1))
      )
    end

    Mix.shell().info(
      "docs staleness/index check: clean (no older-version currency stamps; operator/developer/design/plans indexes complete)"
    )
  end

  defp docs_check_no_currency_stamps(errors, root) do
    # User-facing guides only — docs/plans/ are version-scoped working records and get
    # the index-completeness check instead (see docs_check_plan_index/2).
    active_files =
      (["README.md", "docs/README.md"] ++
         Enum.flat_map(@docs_active_index_dirs, &docs_active_md(root, &1)))
      |> Enum.uniq()

    shipped_mm = shipped_version_mm(root)

    Enum.reduce(active_files, errors, fn rel, acc ->
      path = Path.join(root, rel)

      if File.exists?(path) do
        raw = File.read!(path)
        # Whitespace-normalized so the pin is caught even when it wraps across lines.
        flat = String.replace(raw, ~r/\s+/, " ")

        acc
        |> docs_stamp(
          rel,
          raw =~ ~r/current as of v/i,
          "hardcoded 'current as of v<x>' stamp — link CHANGELOG/roadmap instead"
        )
        |> docs_stamp(
          rel,
          flat =~ ~r/v\d+\.\d+(?:\.\d+)?.{0,60}?\bis the current packaged release line\b/i,
          "hardcoded 'v<x> is the current packaged release line' pin — link CHANGELOG/roadmap for the current line"
        )
        |> docs_stamp(
          rel,
          # The shipped version left marked 'Planned' (version-aware: only the current
          # shipped line, so genuinely-planned future rows never trip).
          shipped_mm != nil and
            Enum.any?(
              String.split(raw, "\n"),
              &(&1 =~ ~r/\bv#{Regex.escape(shipped_mm)}\b/ and &1 =~ ~r/\bPlanned\b/)
            ),
          "the shipped release v#{shipped_mm} is still marked 'Planned' — flip to Released"
        )
      else
        acc
      end
    end)
  end

  defp docs_stamp(errors, _rel, false, _msg), do: errors
  defp docs_stamp(errors, rel, true, msg), do: errors ++ ["#{rel}: #{msg}"]

  # Current shipped release line as "MAJOR.MINOR" from the umbrella version, or nil.
  defp shipped_version_mm(root) do
    with {:ok, content} <- File.read(Path.join(root, "mix.exs")),
         [_, mm] <- Regex.run(~r/version:\s*"(\d+\.\d+)\.\d+"/, content) do
      mm
    else
      _ -> nil
    end
  end

  defp docs_check_indexes(errors, root) do
    errors
    |> docs_check_directory_indexes(root)
    |> docs_check_plan_index(root)
  end

  defp docs_check_directory_indexes(errors, root) do
    Enum.reduce(@docs_active_index_dirs, errors, fn dir, acc ->
      index_path = Path.join([root, dir, "README.md"])

      if File.exists?(index_path) do
        index = File.read!(index_path)

        orphans =
          root
          |> docs_active_md(dir)
          |> Enum.map(&Path.basename/1)
          |> Enum.reject(&(&1 == "README.md"))
          |> Enum.reject(&String.contains?(index, &1))
          |> Enum.map(&"#{dir}/#{&1}: not linked from #{dir}/README.md")

        acc ++ orphans
      else
        acc ++ ["#{dir}/README.md: active-doc index missing"]
      end
    end)
  end

  defp docs_check_plan_index(errors, root) do
    index_path = Path.join(root, @docs_active_plan_index)

    if File.exists?(index_path) do
      index = File.read!(index_path)

      missing =
        @docs_active_plan_files
        |> Enum.reject(&(&1 == @docs_active_plan_index))
        |> Enum.map(&Path.basename/1)
        |> Enum.reject(&String.contains?(index, &1))
        |> Enum.map(&"#{@docs_active_plan_index}: missing active plan link #{&1}")

      errors ++ missing
    else
      errors ++ ["#{@docs_active_plan_index}: active-plan index missing"]
    end
  end

  defp docs_active_md(root, dir) do
    root
    |> Path.join(dir)
    |> Path.join("*.md")
    |> Path.wildcard()
    |> Enum.map(&Path.relative_to(&1, root))
  end

  defp inventory(args) do
    {opts, rest, invalid} =
      OptionParser.parse(args,
        strict: [
          output: :string,
          check_tags: :boolean,
          manifest: :boolean,
          check_manifest: :boolean
        ]
      )

    reject_invalid!(invalid)
    reject_rest!(rest)

    records = inventory_records()

    if Keyword.get(opts, :check_tags, false) do
      check_lane_tags!(records)
    end

    cond do
      Keyword.get(opts, :manifest, false) ->
        write_manifest!(records)

      Keyword.get(opts, :check_manifest, false) ->
        check_manifest!(records)

      true ->
        emit_inventory_csv(records, Keyword.get(opts, :output))
    end
  end

  defp emit_inventory_csv(records, output) do
    csv = inventory_csv(records)

    case output do
      nil ->
        Mix.shell().info(csv)

      path ->
        path = Path.expand(path, root())
        File.mkdir_p!(Path.dirname(path))
        File.write!(path, csv)
        Mix.shell().info("wrote #{Path.relative_to(path, root())}")
    end
  end

  # M8.9: the committed per-test manifest is the standing no-loss invariant.
  # --manifest regenerates docs/validation/test-manifest.csv from the live
  # tree; --check-manifest diffs an in-memory regeneration against the
  # committed file and fails on any difference, so identity/lane/multiplicity
  # drift breaks gates (release.v102 step v102_manifest_drift) instead of
  # hiding until the next audit.
  defp write_manifest!(records) do
    rows = manifest_rows(records)
    path = Path.join(root(), TestManifest.manifest_relative_path())
    File.mkdir_p!(Path.dirname(path))
    File.write!(path, TestManifest.csv(rows))
    Mix.shell().info("wrote #{TestManifest.manifest_relative_path()} (#{length(rows)} rows)")
  end

  defp check_manifest!(records) do
    rows = manifest_rows(records)
    relative = TestManifest.manifest_relative_path()
    path = Path.join(root(), relative)

    committed =
      case File.read(path) do
        {:ok, content} ->
          content

        {:error, reason} ->
          Mix.raise(
            "committed test manifest unreadable (#{relative}: #{reason}); " <>
              "generate it with: mix allbert.test inventory --manifest"
          )
      end

    case TestManifest.check(TestManifest.csv(rows), committed) do
      :ok ->
        Mix.shell().info("test manifest ok: #{length(rows)} rows match #{relative}")

      {:error, summary} ->
        Mix.raise("""
        test manifest drift against #{relative}:
        #{summary}
        Review the drift, then regenerate with: mix allbert.test inventory --manifest
        """)
    end
  end

  @doc false
  def manifest_rows(records \\ inventory_records()) do
    TestManifest.rows(records, root(), @lanes)
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
      # v1.0.3 M1: db_partition_safe joins the packed core lanes — converted
      # Repo-backed files leave db_serial but stay partition-executed
      # (--max-cases 1 per owned-env partition; never the pure_async group).
      [:db_serial, :db_partition_safe, :app_env_serial, :home_fs_serial, :global_process_serial]
      |> Enum.each(&run_serial_partitions!("fast-local", :core, &1, partitions))
    end

    if stocksage_lanes? do
      [:db_serial, :app_env_serial, :global_process_serial]
      |> Enum.each(&run_serial_partitions!("fast-local", :stocksage, &1, partitions))
    end

    if web_lanes? do
      [:liveview_serial]
      |> Enum.each(&run_serial_partitions!("fast-local", :web, &1, partitions))
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

    run_serial_partitions!("serial-core", :core, lane, partitions)
  end

  defp run_serial_partitions!(gate, owner, lane, partitions) do
    packed = packed_lane_paths(owner, lane, partitions)

    1..partitions
    |> Enum.map(fn partition ->
      %{
        label: "serial-#{owner} #{lane} p#{partition}/#{partitions}",
        gate: gate,
        owner: owner,
        partition: partition,
        partitions: partitions,
        lane: lane,
        test_paths: Enum.at(packed, partition - 1),
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

  # v1.0.2 M8.1: render the committed metrics summary from the JSONL store;
  # --ingest-campaign folds pre-recorded seed-campaign logs into the store first.
  defp metrics(args) do
    {opts, rest, invalid} = OptionParser.parse(args, strict: [ingest_campaign: :string])

    reject_invalid!(invalid)
    reject_rest!(rest)

    case Keyword.get(opts, :ingest_campaign) do
      nil ->
        :ok

      dir ->
        dir = Path.expand(dir, root())
        count = TestMetrics.ingest_campaign!(dir)
        Mix.shell().info("ingested #{count} seed-campaign record(s) from #{dir}")
    end

    summary_path = TestMetrics.render_summary!()
    Mix.shell().info("test metrics summary: #{Path.relative_to(summary_path, root())}")
  end

  # v1.0.2 M8.10: the M8.8 decide-turn profiling protocol promoted to a
  # first-class runner. Boots the test env in an owned gate home (migrate
  # first, the serial-lane pattern), runs corpus v1 in the child VM
  # (`DecideBench.record_run!/0` — warmup pass + 3 timed rounds), and
  # records ONE provenance-carrying store row (corpus_id "decide-v1").
  defp bench_decide do
    env = owned_env("bench-decide", 0)

    try do
      {migrate_output, migrate_status} =
        System.cmd("mix", ["ecto.migrate.allbert", "--quiet"],
          cd: app_cwd(:core),
          env: env,
          stderr_to_stdout: true
        )

      if migrate_status != 0 do
        print_output("bench-decide migrate", migrate_output)
        Mix.raise("bench-decide migrate failed with status #{migrate_status}")
      end

      {output, status} =
        System.cmd("mix", ["run", "-e", "AllbertAssist.DevGates.DecideBench.record_run!()"],
          cd: app_cwd(:core),
          env: env,
          stderr_to_stdout: true
        )

      print_output("bench-decide", output)

      if status != 0 do
        Mix.raise("bench-decide failed with status #{status}")
      end
    after
      cleanup_owned_env(env)
    end
  end

  defp commit_phases do
    env = owned_env("commit", 0)

    [
      phase("hex_audit", root(), "mix", ["hex.audit"], env),
      phase("static_compile", root(), "mix", ["compile", "--warnings-as-errors"], env),
      phase("format", root(), "mix", ["format", "--check-formatted"], env),
      phase("credo", root(), "mix", ["credo", "--strict"], env)
    ]
  end

  defp prepush_phases(partitions) do
    env = owned_env("prepush", 0)

    [
      phase("hex_audit", root(), "mix", ["hex.audit"], env),
      phase(
        "static_compile",
        root(),
        "mix",
        ["compile", "--force", "--warnings-as-errors"],
        env
      ),
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
      phase("hex_audit", root(), "mix", ["hex.audit"], env),
      phase(
        "static_compile",
        root(),
        "mix",
        ["compile", "--force", "--warnings-as-errors"],
        env
      ),
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
        Keyword.merge(opts, env: env, command: gate_command())
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
      args: ["test", "test/allbert_assist_web/live/workspace/workspace_destinations_test.exs"],
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
        "test/allbert_assist_web/live/workspace/workspace_destinations_test.exs",
        "test/allbert_assist_web/live/workspace/workspace_settings_central_test.exs"
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
        "test/allbert_assist/dynamic_plugins/codegen_test.exs",
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
      args: ["test", "test/allbert_assist_web/live/workspace/workspace_chat_turn_test.exs"],
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
      args: ["test", "test/allbert_assist_web/live/workspace/workspace_chat_turn_test.exs"],
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
      args: ["test", "test/allbert_assist_web/live/workspace/workspace_chat_turn_test.exs"],
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
        "test/allbert_assist_web/live/workspace/workspace_chat_turn_test.exs"
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
      args: ["test", "test/allbert_assist_web/live/workspace/workspace_chat_turn_test.exs"],
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
        "the shipped intent.router_strategy default is two_stage_local; live local-model routing is exercised by the operator manual-validation punchlist in docs/plans/archives/v0.54-request-flow.md",
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
        "live terminal interaction and Matrix provider delivery remain covered by the v0.55 operator-validation punchlist in docs/plans/archives/v0.55-request-flow.md before tag",
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
        "live warm TUI operator validation remains covered by the v0.55b M5 punchlist in docs/plans/archives/v0.55b-request-flow.md before v0.55.1 closeout",
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
        "test/allbert_assist_web/live/workspace/workspace_shell_nav_test.exs",
        "test/allbert_assist_web/live/workspace/workspace_destinations_test.exs",
        "test/allbert_assist_web/live/workspace/workspace_onboarding_test.exs",
        "test/allbert_assist_web/live/workspace/workspace_canvas_tiles_test.exs"
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
      id: "format_check",
      title: "formatter check for v0.59 release candidate",
      cwd: :root,
      executable: "mix",
      args: ["format", "--check-formatted"],
      coverage: [
        "formatter drift fails the v0.59 release handoff",
        "formatter evidence is captured inside release.v059"
      ]
    },
    %{
      id: "compile_warnings_as_errors",
      title: "compile v0.59 release candidate with warnings as errors",
      cwd: :root,
      executable: "mix",
      args: ["compile", "--warnings-as-errors"],
      coverage: [
        "compiler warnings fail the v0.59 release handoff",
        "compile evidence is captured inside release.v059"
      ]
    },
    %{
      id: "credo_strict",
      title: "Credo strict check for v0.59 release candidate",
      cwd: :root,
      executable: "mix",
      args: ["credo", "--strict"],
      coverage: [
        "Credo strict findings fail the v0.59 release handoff",
        "Credo evidence is captured inside release.v059"
      ]
    },
    %{
      id: "cli_resume_identity",
      title: "CLI conversation resume preserves operator identity",
      cwd: :core,
      executable: "mix",
      args: ["test", "test/mix/tasks/allbert_conversations_test.exs"],
      coverage: [
        "allbert.conversations resume --user threads identity into Runner context",
        "context identity wins over stale params in resume_thread_on_channel"
      ]
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
        "RC substrate handoff has no v0.62/v0.64/v1.0 drift"
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
    portability_artifacts = release_v059_portability_artifacts(home, evidence_dir, env)
    seed_release_v059_secret_scan_fixture(home)

    secret_scan =
      release_channel_pack_secret_scan(home, "release.v059",
        required_paths: Map.get(portability_artifacts, :required_paths, [])
      )

    status =
      if Enum.all?(results, &(&1.status == "passed")) and
           portability_artifacts.status == "passed" and secret_scan.status == "passed" do
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
      portability_artifacts: Map.drop(portability_artifacts, [:required_paths]),
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

  @release_v060_steps [
    %{
      id: "migrate",
      title: "prepare disposable database",
      cwd: :core,
      executable: "mix",
      args: ["ecto.migrate.allbert", "--quiet"],
      coverage: ["schema boot", "release-owned DATABASE_PATH"]
    },
    %{
      id: "format_check",
      title: "formatter check for v0.60 release candidate",
      cwd: :root,
      executable: "mix",
      args: ["format", "--check-formatted"],
      coverage: [
        "formatter drift fails the v0.60 release handoff",
        "formatter evidence is captured inside release.v060"
      ]
    },
    %{
      id: "compile_warnings_as_errors",
      title: "compile v0.60 release candidate with warnings as errors",
      cwd: :root,
      executable: "mix",
      args: ["compile", "--warnings-as-errors"],
      coverage: [
        "compiler warnings fail the v0.60 release handoff",
        "compile evidence is captured inside release.v060"
      ]
    },
    %{
      id: "credo_strict",
      title: "Credo strict check for v0.60 release candidate",
      cwd: :root,
      executable: "mix",
      args: ["credo", "--strict"],
      coverage: [
        "Credo strict findings fail the v0.60 release handoff",
        "Credo evidence is captured inside release.v060"
      ]
    },
    %{
      id: "dialyzer",
      title: "Dialyzer static analysis for v0.60 release candidate",
      cwd: :root,
      executable: "mix",
      args: ["dialyzer"],
      coverage: [
        "Dialyzer warnings fail the v0.60 release handoff",
        "Dialyzer evidence is captured inside release.v060"
      ]
    },
    %{
      id: "v060_security_sweep",
      title: "v0.60 design-artifact, ADR-acceptance, coherence, and handoff eval rows",
      cwd: :core,
      executable: "mix",
      args: [
        "test",
        "test/security/v060_sweep_eval_test.exs",
        "test/security/security_eval_case_test.exs"
      ],
      coverage: [
        "design-artifact presence rows File.read! each of the seven v0.60 docs/design/*.md (1:1)",
        "ADR-acceptance rows File.read! ADR 0077/0078 and assert Accepted (v0.60)",
        "design-only no-authority invariant holds; no new Settings key",
        "cross-doc coherence holds for first-model states and the persona/FMP boundary",
        "handoff drift-check enumerates v0.61/v0.62/v0.63 consumers"
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

  defp release_v060 do
    env = owned_env("release-v060", 0)
    home = env_value(env, "ALLBERT_HOME")
    database = env_value(env, "DATABASE_PATH")
    evidence_dir = Path.join(home, "release_evidence/v060")
    File.mkdir_p!(evidence_dir)

    started_at = DateTime.utc_now()
    results = Enum.map(@release_v060_steps, &run_release_v060_step(&1, env))

    status =
      if Enum.all?(results, &(&1.status == "passed")) do
        "passed"
      else
        "failed"
      end

    evidence = %{
      gate: "mix allbert.test release.v060",
      version: "v0.60",
      status: status,
      generated_at: DateTime.utc_now() |> DateTime.to_iso8601(),
      started_at: DateTime.to_iso8601(started_at),
      allbert_home: home,
      database_path: database,
      evidence_dir: evidence_dir,
      external_network:
        "disabled; deterministic design-artifact, ADR-acceptance, walking-skeleton, and docs-gate checks run against local files and fixtures only",
      notes:
        "post-implementation audit and manual operator validation remain required before v0.60 closeout",
      steps: results
    }

    evidence_path = Path.join(evidence_dir, "release-v060-#{DateTime.to_unix(started_at)}.json")
    File.write!(evidence_path, Jason.encode!(evidence, pretty: true))
    Mix.shell().info("release.v060 evidence: #{evidence_path}")

    if status != "passed" do
      Mix.raise("release.v060 failed; evidence: #{evidence_path}")
    end
  end

  defp run_release_v060_step(step, env) do
    started = System.monotonic_time(:millisecond)
    cwd = release_step_cwd(step.cwd)

    {output, exit_status} =
      System.cmd(step.executable, step.args, cd: cwd, env: env, stderr_to_stdout: true)

    duration_ms = System.monotonic_time(:millisecond) - started
    print_output("release.v060 #{step.id}", output)

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

  @release_v060b_steps [
    %{
      id: "migrate",
      title: "prepare disposable database",
      cwd: :core,
      executable: "mix",
      args: ["ecto.migrate.allbert", "--quiet"],
      coverage: ["schema boot", "release-owned DATABASE_PATH"]
    },
    %{
      id: "format_check",
      title: "formatter check for v0.60b release candidate",
      cwd: :root,
      executable: "mix",
      args: ["format", "--check-formatted"],
      coverage: [
        "formatter drift fails the v0.60b visual-language handoff",
        "formatter evidence is captured inside release.v060b"
      ]
    },
    %{
      id: "compile_warnings_as_errors",
      title: "compile v0.60b release candidate with warnings as errors",
      cwd: :root,
      executable: "mix",
      args: ["compile", "--warnings-as-errors"],
      coverage: [
        "compiler warnings fail the v0.60b visual-language handoff",
        "compile evidence is captured inside release.v060b"
      ]
    },
    %{
      id: "credo_strict",
      title: "Credo strict check for v0.60b release candidate",
      cwd: :root,
      executable: "mix",
      args: ["credo", "--strict"],
      coverage: [
        "Credo strict findings fail the v0.60b visual-language handoff",
        "Credo evidence is captured inside release.v060b"
      ]
    },
    %{
      id: "dialyzer",
      title: "Dialyzer static analysis for v0.60b release candidate",
      cwd: :root,
      executable: "mix",
      args: ["dialyzer"],
      coverage: [
        "Dialyzer warnings fail the v0.60b visual-language handoff",
        "included because v0.60b produces styled-variant rendering code",
        "Dialyzer evidence is captured inside release.v060b"
      ]
    },
    %{
      id: "v060b_security_sweep",
      title:
        "v0.60b design-artifact, ADR-acceptance, decision, design-only, and handoff eval rows",
      cwd: :core,
      executable: "mix",
      args: [
        "test",
        "test/security/v060b_sweep_eval_test.exs",
        "test/security/security_eval_case_test.exs"
      ],
      coverage: [
        "design-artifact presence rows File.read! each of the v0.60b docs/design/visual-*.md",
        "ADR-acceptance row File.read! ADR 0079 and asserts Accepted-with-choice (v0.60b) with a named direction",
        "the ≥3-candidate-count and operator-decision rows pass with a single recorded choice",
        "design-only no-authority invariant holds; no new Settings key",
        "handoff drift-check names v0.61 as the sole consumer; downstream unchanged"
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

  defp release_v060b do
    env = owned_env("release-v060b", 0)
    home = env_value(env, "ALLBERT_HOME")
    database = env_value(env, "DATABASE_PATH")
    evidence_dir = Path.join(home, "release_evidence/v060b")
    File.mkdir_p!(evidence_dir)

    started_at = DateTime.utc_now()
    results = Enum.map(@release_v060b_steps, &run_release_v060b_step(&1, env))

    status =
      if Enum.all?(results, &(&1.status == "passed")) do
        "passed"
      else
        "failed"
      end

    evidence = %{
      gate: "mix allbert.test release.v060b",
      version: "v0.60b",
      status: status,
      generated_at: DateTime.utc_now() |> DateTime.to_iso8601(),
      started_at: DateTime.to_iso8601(started_at),
      allbert_home: home,
      database_path: database,
      evidence_dir: evidence_dir,
      external_network:
        "disabled; deterministic visual-language design-artifact, ADR-acceptance, styled-variant rendering, and docs-gate checks run against local files and fixtures only",
      notes:
        "v0.60b is a design + disposable-exploration release; the chosen visual language and its token/component delta hand off to v0.61 only. Manual S4.5 design-review evidence is retained outside the repo",
      steps: results
    }

    evidence_path = Path.join(evidence_dir, "release-v060b-#{DateTime.to_unix(started_at)}.json")
    File.write!(evidence_path, Jason.encode!(evidence, pretty: true))
    Mix.shell().info("release.v060b evidence: #{evidence_path}")

    if status != "passed" do
      Mix.raise("release.v060b failed; evidence: #{evidence_path}")
    end
  end

  defp run_release_v060b_step(step, env) do
    started = System.monotonic_time(:millisecond)
    cwd = release_step_cwd(step.cwd)

    {output, exit_status} =
      System.cmd(step.executable, step.args, cd: cwd, env: env, stderr_to_stdout: true)

    duration_ms = System.monotonic_time(:millisecond) - started
    print_output("release.v060b #{step.id}", output)

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

  @release_v061_steps [
    %{
      id: "migrate",
      title: "prepare disposable database",
      cwd: :core,
      executable: "mix",
      args: ["ecto.migrate.allbert", "--quiet"],
      coverage: ["schema boot", "release-owned DATABASE_PATH"]
    },
    %{
      id: "format_check",
      title: "formatter check for v0.61 release candidate",
      cwd: :root,
      executable: "mix",
      args: ["format", "--check-formatted"],
      coverage: [
        "formatter drift fails the v0.61 presentation-overhaul handoff",
        "formatter evidence is captured inside release.v061"
      ]
    },
    %{
      id: "compile_warnings_as_errors",
      title: "compile v0.61 release candidate with warnings as errors",
      cwd: :root,
      executable: "mix",
      args: ["compile", "--warnings-as-errors"],
      coverage: [
        "compiler warnings fail the v0.61 presentation-overhaul handoff",
        "compile evidence is captured inside release.v061"
      ]
    },
    %{
      id: "credo_strict",
      title: "Credo strict check for v0.61 release candidate",
      cwd: :root,
      executable: "mix",
      args: ["credo", "--strict"],
      coverage: [
        "Credo strict findings fail the v0.61 presentation-overhaul handoff",
        "Credo evidence is captured inside release.v061"
      ]
    },
    %{
      id: "dialyzer",
      title: "Dialyzer static analysis for v0.61 release candidate",
      cwd: :root,
      executable: "mix",
      args: ["dialyzer"],
      coverage: [
        "Dialyzer warnings fail the v0.61 presentation-overhaul handoff",
        "included because v0.61 ships substantial LiveView/CSS-token/shell code",
        "Dialyzer evidence is captured inside release.v061"
      ]
    },
    %{
      id: "redesigned_surface_proof",
      title:
        "the redesigned shell/screens render through the catalog with first-class Direction C",
      cwd: :web,
      executable: "mix",
      args: [
        "test",
        "test/allbert_assist_web/workspace/direction_c_tokens_test.exs",
        "test/allbert_assist_web/components/operator_shell_nav_test.exs",
        "test/allbert_assist_web/workspace/chat_primary_hero_test.exs",
        "test/allbert_assist_web/brand_landing_test.exs",
        "test/allbert_assist_web/workspace/motion_layer_test.exs",
        "test/allbert_assist_web/dark_mode_test.exs",
        "test/allbert_assist_web/workspace/visual_hierarchy_test.exs",
        "test/allbert_assist_web/controllers/page_controller_test.exs",
        "test/allbert_assist_web/live/objectives_live_test.exs",
        "test/allbert_assist_web/v061/redesigned_surface_proof_test.exs",
        "test/allbert_assist_web/v061/accessibility_conformance_test.exs"
      ],
      coverage: [
        "Direction C promoted to first-class :root/dark tokens; the four variants render",
        "D sidebar grouped IA nav reaches all nine surfaces; no route sprawl beyond /objectives",
        "chat-primary hero, brand + landing + static SEO/OG, motion, OS dark mode, hierarchy",
        "Jobs/Objectives catalog rendering, view-only suggested actions, accessibility conformance",
        "high-contrast overrides the promoted palette; no operator-data leak in the landing"
      ]
    },
    %{
      id: "v061_security_sweep",
      title: "v0.61 design-artifact and eval-inventory rows",
      cwd: :core,
      executable: "mix",
      args: [
        "test",
        "test/security/v061_sweep_eval_test.exs",
        "test/security/security_eval_case_test.exs"
      ],
      coverage: [
        "layout explored/selected + screenshot design-record rows File.read!/File.exists the artifacts",
        "the :v061 row set is complete, shaped (≥3 asserts), and routed to its owning tests"
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

  defp release_v061 do
    env = owned_env("release-v061", 0)
    home = env_value(env, "ALLBERT_HOME")
    database = env_value(env, "DATABASE_PATH")
    evidence_dir = Path.join(home, "release_evidence/v061")
    File.mkdir_p!(evidence_dir)

    started_at = DateTime.utc_now()
    results = Enum.map(@release_v061_steps, &run_release_v061_step(&1, env))

    status =
      if Enum.all?(results, &(&1.status == "passed")) do
        "passed"
      else
        "failed"
      end

    evidence = %{
      gate: "mix allbert.test release.v061",
      version: "v0.61",
      status: status,
      generated_at: DateTime.utc_now() |> DateTime.to_iso8601(),
      started_at: DateTime.to_iso8601(started_at),
      allbert_home: home,
      database_path: database,
      evidence_dir: evidence_dir,
      external_network:
        "disabled; deterministic layout/redesigned-surface/visual-token proofs, design-artifact eval rows, and docs-gate checks run against local files and fixtures only",
      notes:
        "v0.61 implements the v0.60 IA in Layout D and the v0.60b-chosen Direction C visual language as the primary 1.0 surface; presentation-only, no new authority. Manual S0-S15 operator validation evidence is retained outside the repo",
      steps: results
    }

    evidence_path = Path.join(evidence_dir, "release-v061-#{DateTime.to_unix(started_at)}.json")
    File.write!(evidence_path, Jason.encode!(evidence, pretty: true))
    Mix.shell().info("release.v061 evidence: #{evidence_path}")

    if status != "passed" do
      Mix.raise("release.v061 failed; evidence: #{evidence_path}")
    end
  end

  defp run_release_v061_step(step, env) do
    started = System.monotonic_time(:millisecond)
    cwd = release_step_cwd(step.cwd)

    {output, exit_status} =
      System.cmd(step.executable, step.args, cd: cwd, env: env, stderr_to_stdout: true)

    duration_ms = System.monotonic_time(:millisecond) - started
    print_output("release.v061 #{step.id}", output)

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

  @release_v061b_steps [
    %{
      id: "migrate",
      title: "prepare disposable database",
      cwd: :core,
      executable: "mix",
      args: ["ecto.migrate.allbert", "--quiet"],
      coverage: ["schema boot", "release-owned DATABASE_PATH"]
    },
    %{
      id: "format_check",
      title: "formatter check for v0.61b release candidate",
      cwd: :root,
      executable: "mix",
      args: ["format", "--check-formatted"],
      coverage: [
        "formatter drift fails the v0.61b ux-refinement handoff",
        "formatter evidence is captured inside release.v061b"
      ]
    },
    %{
      id: "compile_warnings_as_errors",
      title: "compile v0.61b release candidate with warnings as errors",
      cwd: :root,
      executable: "mix",
      args: ["compile", "--warnings-as-errors"],
      coverage: [
        "compiler warnings fail the v0.61b ux-refinement handoff",
        "compile evidence is captured inside release.v061b"
      ]
    },
    %{
      id: "credo_strict",
      title: "Credo strict check for v0.61b release candidate",
      cwd: :root,
      executable: "mix",
      args: ["credo", "--strict"],
      coverage: [
        "Credo strict findings fail the v0.61b ux-refinement handoff",
        "Credo evidence is captured inside release.v061b"
      ]
    },
    %{
      id: "dialyzer",
      title: "Dialyzer static analysis for v0.61b release candidate",
      cwd: :root,
      executable: "mix",
      args: ["dialyzer"],
      coverage: [
        "Dialyzer warnings fail the v0.61b ux-refinement handoff",
        "included because v0.61b ships shell recomposition + a registered action",
        "Dialyzer evidence is captured inside release.v061b"
      ]
    },
    %{
      id: "v061b_shell_proof",
      title: "the eight v0.61b refinements hold on the consolidated shell",
      cwd: :web,
      executable: "mix",
      args: [
        "test",
        "test/allbert_assist_web/v061b/chat_type_hierarchy_test.exs",
        "test/allbert_assist_web/v061b/status_link_chip_test.exs",
        "test/allbert_assist_web/v061b/dark_lockstep_test.exs",
        "test/allbert_assist_web/v061b/thread_rename_live_test.exs",
        "test/allbert_assist_web/v061b/sidebar_consolidation_test.exs",
        "test/allbert_assist_web/v061b/docked_pane_test.exs",
        "test/allbert_assist_web/v061b/topbar_retirement_test.exs",
        "test/allbert_assist_web/v061b/sidebar_collapse_test.exs"
      ],
      coverage: [
        "chat type hierarchy strict body > label > timestamp on token-resolved values",
        "objective link-chips name destination + title + status with the >=3 overflow",
        "dark/system-dark token-map lockstep with the AA anchors held",
        "inline thread rename round-trip through the registered-action spine",
        "single-sidebar consolidation + enumerated destination-inventory reachability",
        "docked pane never floats over chat; replace-and-restore tenancy",
        "top bars retired with the 15-row relocation map mirrored + cross-shell theme",
        "sidebar collapse expanded/rail/hidden with a11y + persistence restore path"
      ]
    },
    %{
      id: "v061_regression_proof",
      title: "the v0.61 proofs (as reconciled by M3/M5) still hold on the new shell",
      cwd: :web,
      executable: "mix",
      args: [
        "test",
        "test/allbert_assist_web/workspace/direction_c_tokens_test.exs",
        "test/allbert_assist_web/components/operator_shell_nav_test.exs",
        "test/allbert_assist_web/workspace/chat_primary_hero_test.exs",
        "test/allbert_assist_web/brand_landing_test.exs",
        "test/allbert_assist_web/workspace/motion_layer_test.exs",
        "test/allbert_assist_web/dark_mode_test.exs",
        "test/allbert_assist_web/workspace/visual_hierarchy_test.exs",
        "test/allbert_assist_web/controllers/page_controller_test.exs",
        "test/allbert_assist_web/live/objectives_live_test.exs",
        "test/allbert_assist_web/v061/redesigned_surface_proof_test.exs",
        "test/allbert_assist_web/v061/accessibility_conformance_test.exs"
      ],
      coverage: [
        "the refinement does not regress what v0.61 proved",
        "reconciliations (dark literals, nav structure) were deliberate reviewed edits, not weakenings"
      ]
    },
    %{
      id: "v061b_security_sweep",
      title: "v0.61b artifact, invariant, and eval-inventory rows",
      cwd: :core,
      executable: "mix",
      args: [
        "test",
        "test/security/v061b_sweep_eval_test.exs",
        "test/security/security_eval_case_test.exs",
        "test/allbert_assist/actions/conversations/rename_thread_test.exs",
        # M9.1: the registry/permission exact lists make no-new-authority
        # exactness IN-gate (a second new action previously passed green —
        # only the full core suite caught it).
        "test/allbert_assist/actions/registry_test.exs"
      ],
      coverage: [
        "shell-spec/sign-off + ADR 0080 Accepted artifact rows File.read! the docs",
        "no-internal-rename and no-new-authority (registry diff exactly rename_thread) rows",
        "registry exact lists in-gate — the authority envelope is enforced, not sampled",
        "the :v061b row set is complete, shaped (>=3 asserts), and routed to its owning tests",
        "rename ownership/gate-deny negative tests run inside the gate"
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

  defp release_v061b do
    env = owned_env("release-v061b", 0)
    home = env_value(env, "ALLBERT_HOME")
    database = env_value(env, "DATABASE_PATH")
    evidence_dir = Path.join(home, "release_evidence/v061b")
    File.mkdir_p!(evidence_dir)

    started_at = DateTime.utc_now()
    results = Enum.map(@release_v061b_steps, &run_release_v061b_step(&1, env))

    status =
      if Enum.all?(results, &(&1.status == "passed")) do
        "passed"
      else
        "failed"
      end

    evidence = %{
      gate: "mix allbert.test release.v061b",
      version: "v0.61b",
      status: status,
      generated_at: DateTime.utc_now() |> DateTime.to_iso8601(),
      started_at: DateTime.to_iso8601(started_at),
      allbert_home: home,
      database_path: database,
      evidence_dir: evidence_dir,
      external_network:
        "disabled; deterministic shell/token/rename proofs, artifact eval rows, and docs-gate checks run against local files and fixtures only",
      notes:
        "v0.61b implements the eight operator UX-feedback items over the v0.61 surface per ADR 0080; presentation recomposition + one internal rename_thread action on the existing :conversation_write permission, no new authority. Manual S1-S6 operator validation evidence is retained outside the repo",
      steps: results
    }

    evidence_path = Path.join(evidence_dir, "release-v061b-#{DateTime.to_unix(started_at)}.json")
    File.write!(evidence_path, Jason.encode!(evidence, pretty: true))
    Mix.shell().info("release.v061b evidence: #{evidence_path}")

    if status != "passed" do
      Mix.raise("release.v061b failed; evidence: #{evidence_path}")
    end
  end

  defp run_release_v061b_step(step, env) do
    started = System.monotonic_time(:millisecond)
    cwd = release_step_cwd(step.cwd)

    {output, exit_status} =
      System.cmd(step.executable, step.args, cd: cwd, env: env, stderr_to_stdout: true)

    duration_ms = System.monotonic_time(:millisecond) - started
    print_output("release.v061b #{step.id}", output)

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

  @release_v062_steps [
    %{
      id: "migrate",
      title: "prepare disposable database",
      cwd: :core,
      executable: "mix",
      args: ["ecto.migrate.allbert", "--quiet"],
      coverage: ["schema boot", "release-owned DATABASE_PATH"]
    },
    %{
      id: "format_check",
      title: "formatter check for v0.62 release candidate",
      cwd: :root,
      executable: "mix",
      args: ["format", "--check-formatted"],
      coverage: [
        "formatter drift fails the v0.62 packaging handoff",
        "formatter evidence is captured inside release.v062"
      ]
    },
    %{
      id: "compile_warnings_as_errors",
      title: "compile v0.62 release candidate with warnings as errors",
      cwd: :root,
      executable: "mix",
      args: ["compile", "--warnings-as-errors"],
      coverage: [
        "compiler warnings fail the v0.62 packaging handoff",
        "compile evidence is captured inside release.v062"
      ]
    },
    %{
      id: "credo_strict",
      title: "Credo strict check for v0.62 release candidate",
      cwd: :root,
      executable: "mix",
      args: ["credo", "--strict"],
      coverage: [
        "Credo strict findings fail the v0.62 packaging handoff",
        "infrastructure env vars are classified, not bypassing Settings Central",
        "Credo evidence is captured inside release.v062"
      ]
    },
    %{
      id: "dialyzer",
      title: "Dialyzer static analysis for v0.62 release candidate",
      cwd: :root,
      executable: "mix",
      args: ["dialyzer"],
      coverage: [
        "Dialyzer warnings fail the v0.62 packaging handoff",
        "included because v0.62 adds a CLI/daemon/vault runtime surface",
        "Dialyzer evidence is captured inside release.v062"
      ]
    },
    %{
      id: "v062_packaging_proof",
      title: "the packaged entry points, first-run, daemon, and vault hold",
      cwd: :core,
      executable: "mix",
      args: [
        "test",
        "test/allbert_assist/runtime_env_test.exs",
        "test/allbert_assist/plugin/paths_test.exs",
        "test/allbert_assist/runtime/paths_test.exs",
        "test/allbert_assist/database_backup_test.exs",
        "test/allbert_assist/cli/dispatcher_test.exs",
        "test/allbert_assist/cli/commands_test.exs",
        "test/allbert_assist/cli/first_run_test.exs",
        "test/allbert_assist/first_model/first_model_test.exs",
        "test/allbert_assist/runtime/writer_lock_test.exs",
        "test/allbert_assist/serve_test.exs",
        "test/allbert_assist/settings/vault_test.exs",
        "test/allbert_assist/channels/tui_convergence_test.exs",
        "test/allbert_assist/install_path_test.exs",
        "test/allbert_assist/actions/conversations/persist_approval_media_response_test.exs"
      ],
      coverage: [
        "release-safe env detection (RELEASE_NAME/RELEASE_ROOT) replaces Mix.env probes",
        "packaged plugin root resolution + backup-before-migrate on version change",
        "dispatcher inventory map, operator/dev split, attach round-trip + auth refusals + embedded single-writer fallback",
        "all seven First-Model-Path states incl. below_hardware_floor BYOK degrade",
        "serve health read-only + documented service unit; three-tier vault resolution + migration",
        "converged TUI console reads; the M0.1 media-response internal action"
      ]
    },
    %{
      id: "v062_security_sweep",
      title: "v0.62 artifact, authority-envelope, and eval-inventory rows",
      cwd: :core,
      executable: "mix",
      args: [
        "test",
        "test/security/v062_sweep_eval_test.exs",
        "test/security/security_eval_case_test.exs",
        "test/allbert_assist/actions/registry_test.exs",
        "test/allbert_assist/intent/eval/corpus_completeness_test.exs"
      ],
      coverage: [
        "no-new-authority: registry diff is exactly the named internal actions, no new class/key",
        "ADR 0076 Accepted + Distribution Trust; ADR 0070 convergence; package paths documented",
        "vault no-leak sweep; converged reads stay off the intent router",
        "registry exact lists + intent-corpus completeness in-gate — enforced, not sampled",
        "the :v062 row set is complete, shaped, and routed to its owning tests"
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

  defp release_v062 do
    env = owned_env("release-v062", 0)
    home = env_value(env, "ALLBERT_HOME")
    database = env_value(env, "DATABASE_PATH")
    evidence_dir = Path.join(home, "release_evidence/v062")
    File.mkdir_p!(evidence_dir)

    started_at = DateTime.utc_now()
    results = Enum.map(@release_v062_steps, &run_release_v062_step(&1, env))

    status =
      if Enum.all?(results, &(&1.status == "passed")) do
        "passed"
      else
        "failed"
      end

    evidence = %{
      gate: "mix allbert.test release.v062",
      version: "v0.62",
      status: status,
      generated_at: DateTime.utc_now() |> DateTime.to_iso8601(),
      started_at: DateTime.to_iso8601(started_at),
      allbert_home: home,
      database_path: database,
      evidence_dir: evidence_dir,
      external_network:
        "disabled; deterministic packaging/CLI/first-run/daemon/vault proofs, artifact eval rows, and docs-gate checks run against local files and injected transports only",
      notes:
        "v0.62 packages Allbert as an OTP release with a unified `allbert` CLI, first-run/First-Model-Path onboarding, an `allbert serve` daemon, and a three-tier secret vault. This checkout-bound gate cannot execute the packaged artifact; the artifact smoke harness (.github/workflows/release-artifacts.yml + scripts/) is the second verification layer. Per-OS brew/curl/service/vault rehearsals and the tag are operator S-steps.",
      steps: results
    }

    evidence_path = Path.join(evidence_dir, "release-v062-#{DateTime.to_unix(started_at)}.json")
    File.write!(evidence_path, Jason.encode!(evidence, pretty: true))
    Mix.shell().info("release.v062 evidence: #{evidence_path}")

    if status != "passed" do
      Mix.raise("release.v062 failed; evidence: #{evidence_path}")
    end
  end

  defp run_release_v062_step(step, env) do
    started = System.monotonic_time(:millisecond)
    cwd = release_step_cwd(step.cwd)

    {output, exit_status} =
      System.cmd(step.executable, step.args, cd: cwd, env: env, stderr_to_stdout: true)

    duration_ms = System.monotonic_time(:millisecond) - started
    print_output("release.v062 #{step.id}", output)

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

  @release_v063_steps [
    %{
      id: "migrate",
      title: "prepare disposable database",
      cwd: :core,
      executable: "mix",
      args: ["ecto.migrate.allbert", "--quiet"],
      coverage: ["schema boot", "release-owned DATABASE_PATH"]
    },
    %{
      id: "format_check",
      title: "formatter check for v0.63 release candidate",
      cwd: :root,
      executable: "mix",
      args: ["format", "--check-formatted"],
      coverage: ["formatter drift fails the v0.63 onboarding handoff"]
    },
    %{
      id: "compile_warnings_as_errors",
      title: "compile v0.63 release candidate with warnings as errors",
      cwd: :root,
      executable: "mix",
      args: ["compile", "--warnings-as-errors"],
      coverage: ["compiler warnings fail the v0.63 onboarding handoff"]
    },
    %{
      id: "credo_strict",
      title: "Credo strict check for v0.63 release candidate",
      cwd: :root,
      executable: "mix",
      args: ["credo", "--strict"],
      coverage: ["Credo strict findings fail the v0.63 onboarding handoff"]
    },
    %{
      id: "dialyzer",
      title: "Dialyzer static analysis for v0.63 release candidate",
      cwd: :root,
      executable: "mix",
      args: ["dialyzer"],
      coverage: ["Dialyzer warnings fail the v0.63 onboarding handoff"]
    },
    %{
      id: "v063_onboarding_proof",
      title: "the shared wizard, provider step, personas, and terminal dispatcher hold",
      cwd: :core,
      executable: "mix",
      args: [
        "test",
        "test/allbert_assist/onboarding_test.exs",
        "test/allbert_assist/cli/first_run_test.exs",
        "test/allbert_assist/cli/areas/onboarding_test.exs",
        "test/allbert_assist/personas_test.exs",
        "test/allbert_assist/actions/apply_persona_profile_test.exs",
        "test/allbert_assist/onboarding/provider_step_test.exs"
      ],
      coverage: [
        "M1 shared state machine + marker unification + top-level onboard verb",
        "M2 track-aware readiness guidance (no dead ends); M3 vault-tier/doctor interpretation",
        "M4 seed-only persona catalog + confirmation-gated apply; M6 --authorize + refusal contract"
      ]
    },
    %{
      id: "v063_security_sweep",
      title: "v0.63 onboarding security/flow eval rows + ADR acceptance",
      cwd: :core,
      executable: "mix",
      args: [
        "test",
        "test/security/onboarding_security_eval_test.exs",
        "test/security/onboarding_flow_eval_test.exs",
        "test/security/v063_sweep_eval_test.exs",
        "test/security/security_eval_case_test.exs",
        "test/allbert_assist/actions/registry_test.exs"
      ],
      coverage: [
        "no-authority-from-personas, no-secret-leak (log+response), safe-write-only, explicit review",
        "shared step IDs (both surfaces), operator readiness copy, trust spine, QuickStart no-dead-end",
        "env-tier write rejected, provider switch is settings-write, approve->applied round-trip",
        "ADR 0069 + 0075 Accepted; the :v063 row set is complete/shaped/routed and every row's assert atoms are bound"
      ]
    },
    %{
      id: "v063_web_onboarding",
      title: "the web onboarding wizard drives M1–M4 + auto-open (LiveView)",
      cwd: :root,
      executable: "mix",
      args: [
        "test",
        "apps/allbert_assist_web/test/allbert_assist_web/workspace/first_run_test.exs",
        "apps/allbert_assist_web/test/allbert_assist_web/live/workspace/workspace_onboarding_test.exs",
        "--only",
        "onboarding_wizard"
      ],
      coverage: [
        "the web wizard renders real M3 masked entry + M4 review diff + first-chat prompts",
        "no legacy objective panel; auto-open decision; the trust spine is surfaced on web",
        "closes the audit gap: the web half of the shared wizard is now inside the gate"
      ]
    },
    %{
      id: "docs_gate",
      title: "docs gate and release-planning whitespace check",
      cwd: :root,
      executable: "mix",
      args: ["allbert.test", "docs"],
      coverage: ["git diff --check is clean", "docs gate is visible in release evidence"]
    }
  ]

  defp release_v063 do
    env = owned_env("release-v063", 0)
    home = env_value(env, "ALLBERT_HOME")
    database = env_value(env, "DATABASE_PATH")
    evidence_dir = Path.join(home, "release_evidence/v063")
    File.mkdir_p!(evidence_dir)

    started_at = DateTime.utc_now()
    results = Enum.map(@release_v063_steps, &run_release_v063_step(&1, env))

    status = if Enum.all?(results, &(&1.status == "passed")), do: "passed", else: "failed"

    evidence = %{
      gate: "mix allbert.test release.v063",
      version: "v0.63",
      status: status,
      generated_at: DateTime.utc_now() |> DateTime.to_iso8601(),
      started_at: DateTime.to_iso8601(started_at),
      allbert_home: home,
      database_path: database,
      evidence_dir: evidence_dir,
      external_network:
        "disabled; deterministic shared-wizard/provider-step/persona/dispatcher proofs, onboarding eval rows, web wizard LiveView tests, and docs-gate checks run against local files and injected transports only — the first-model probe is overridden in the test env (:first_model_state_override), so no localhost Ollama probe runs",
      notes:
        "v0.63 Guided Onboarding & Profiles builds one shared wizard over web + terminal, a seed-only persona system, and a first-run trust spine — all over the existing runtime/action/settings spine, granting no new authority. M7.7: the gate now also runs the web onboarding wizard LiveView tests (v063_web_onboarding step), every :v063 row binds its assert atoms to its owning test, and the gate is hermetic. This core gate proves the shared machine, personas, terminal + web surfaces, and the :v063 security/flow eval rows.",
      steps: results
    }

    evidence_path = Path.join(evidence_dir, "release-v063-#{DateTime.to_unix(started_at)}.json")
    File.write!(evidence_path, Jason.encode!(evidence, pretty: true))
    Mix.shell().info("release.v063 evidence: #{evidence_path}")

    if status != "passed" do
      Mix.raise("release.v063 failed; evidence: #{evidence_path}")
    end
  end

  defp run_release_v063_step(step, env) do
    started = System.monotonic_time(:millisecond)
    cwd = release_step_cwd(step.cwd)

    {output, exit_status} =
      System.cmd(step.executable, step.args, cd: cwd, env: env, stderr_to_stdout: true)

    duration_ms = System.monotonic_time(:millisecond) - started
    print_output("release.v063 #{step.id}", output)

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

  @release_v064_steps [
    %{
      id: "migrate",
      title: "prepare disposable database",
      cwd: :core,
      executable: "mix",
      args: ["ecto.migrate.allbert", "--quiet"],
      coverage: ["schema boot", "release-owned DATABASE_PATH"]
    },
    %{
      id: "format_check",
      title: "formatter check for v0.64 release candidate",
      cwd: :root,
      executable: "mix",
      args: ["format", "--check-formatted"],
      coverage: ["formatter drift fails the v0.64 first-run handoff"]
    },
    %{
      id: "compile_warnings_as_errors",
      title: "compile v0.64 release candidate with warnings as errors",
      cwd: :root,
      executable: "mix",
      args: ["compile", "--warnings-as-errors"],
      coverage: ["compiler warnings fail the v0.64 first-run handoff"]
    },
    %{
      id: "credo_strict",
      title: "Credo strict check for v0.64 release candidate",
      cwd: :root,
      executable: "mix",
      args: ["credo", "--strict"],
      coverage: ["Credo strict findings fail the v0.64 first-run handoff"]
    },
    %{
      id: "dialyzer",
      title: "Dialyzer static analysis for v0.64 release candidate",
      cwd: :root,
      executable: "mix",
      args: ["dialyzer"],
      coverage: ["Dialyzer warnings fail the v0.64 first-run handoff"]
    },
    %{
      id: "v064_trusted_install_restore",
      title: "trusted installer verification and backup restore path hold",
      cwd: :core,
      executable: "mix",
      args: [
        "test",
        "test/allbert_assist/install_path_test.exs",
        "test/allbert_assist/database_test.exs",
        "test/allbert_assist/database_backup_test.exs",
        "test/allbert_assist/actions/registry_test.exs"
      ],
      coverage: [
        "installer downloads and verifies SHA256SUMS.cosign.bundle before checksum comparison",
        "Homebrew formula fill updates version, URLs, and checksums together",
        "startup migrations serialize concurrent first-boot attempts",
        "artifact signing is a hard release-workflow gate",
        "backup-before-migrate restore is listable, path-bounded, and confirmation-gated"
      ]
    },
    %{
      id: "v064_model_and_first_run_repair",
      title: "local model repair, first-run copy, service posture, and TUI guard hold",
      cwd: :core,
      executable: "mix",
      args: [
        "test",
        "test/allbert_assist/first_model/first_model_test.exs",
        "test/allbert_assist/cli/areas/onboarding_test.exs",
        "test/allbert_assist/cli/first_run_test.exs",
        "test/allbert_assist/cli/dispatcher_test.exs",
        "test/allbert_assist/cli/tui_test.exs"
      ],
      coverage: [
        "guided runtime install and curated model pull stay behind preview/confirmation paths",
        "Ollama pull uses streaming progress and workspace progress signals",
        "bare CLI and TUI blocked states avoid raw probe atoms and show repair destinations",
        "service status routes through read-only health/service posture"
      ]
    },
    %{
      id: "v064_security_sweep",
      title: "v0.64 eval rows, trust spine, natural prompt routing, and docs handoff hold",
      cwd: :core,
      executable: "mix",
      args: [
        "test",
        "test/security/v064_sweep_eval_test.exs",
        "test/security/onboarding_flow_eval_test.exs",
        "test/security/onboarding_security_eval_test.exs",
        "test/security/security_eval_case_test.exs",
        "test/allbert_assist/agents/intent_agent_test.exs"
      ],
      coverage: [
        "the :v064 row set is complete, shaped, routed, and bound to owning assertions",
        "trust spine names hosted egress, vault custody, memory review, and no new authority",
        "plain first-chat prompts route to read-only direct_answer rather than side effects",
        "v0.65 local files/notes/reviewed-memory handoff is current"
      ]
    },
    %{
      id: "v064_web_model_repair",
      title: "the web first-run repair route opens the standalone Models panel",
      cwd: :root,
      executable: "mix",
      args: [
        "test",
        "apps/allbert_assist_web/test/allbert_assist_web/workspace/first_run_test.exs",
        "apps/allbert_assist_web/test/allbert_assist_web/live/workspace/workspace_onboarding_test.exs"
      ],
      coverage: [
        "completed onboarding with an unavailable model opens workspace:models",
        "the standalone Models panel exposes install-runtime and pull-model repair controls",
        "the model pull dispatches asynchronously and streams live progress frames (v0.64.3)"
      ]
    },
    %{
      id: "v064_version_consistency",
      title: "umbrella apps agree on version (no cross-app :vsn drift at release)",
      cwd: :root,
      executable: "mix",
      args: [
        "test",
        "apps/allbert_assist_web/test/allbert_assist_web/version_consistency_test.exs"
      ],
      coverage: [
        "the CLI-banner app and the asset-version app agree on version"
      ]
    },
    %{
      id: "docs_gate",
      title: "docs gate and release-planning whitespace check",
      cwd: :root,
      executable: "mix",
      args: ["allbert.test", "docs"],
      coverage: ["git diff --check is clean", "docs gate is visible in release evidence"]
    }
  ]

  defp release_v064 do
    env = owned_env("release-v064", 0)
    home = env_value(env, "ALLBERT_HOME")
    database = env_value(env, "DATABASE_PATH")
    evidence_dir = Path.join(home, "release_evidence/v064")
    File.mkdir_p!(evidence_dir)

    started_at = DateTime.utc_now()
    results = Enum.map(@release_v064_steps, &run_release_v064_step(&1, env))

    status = if Enum.all?(results, &(&1.status == "passed")), do: "passed", else: "failed"

    evidence = %{
      gate: "mix allbert.test release.v064",
      version: "v0.64",
      status: status,
      generated_at: DateTime.utc_now() |> DateTime.to_iso8601(),
      started_at: DateTime.to_iso8601(started_at),
      allbert_home: home,
      database_path: database,
      evidence_dir: evidence_dir,
      external_network:
        "disabled; deterministic trusted-installer, restore, first-model, first-run repair, trust-spine, intent-routing, and web repair proofs use local files, injected Req transports, and disposable Allbert homes only",
      notes:
        "v0.64 Trusted Install And Non-Developer First Run makes the package-first path fail-closed on artifact trust, exposes a bounded DB restore path, routes missing-model first-run states to repair actions, drives the curated local model pull with progress, keeps BYOK/custom as an advanced fallback, and binds every :v064 security/flow row to an owning assertion.",
      steps: results
    }

    evidence_path = Path.join(evidence_dir, "release-v064-#{DateTime.to_unix(started_at)}.json")
    File.write!(evidence_path, Jason.encode!(evidence, pretty: true))
    Mix.shell().info("release.v064 evidence: #{evidence_path}")

    if status != "passed" do
      Mix.raise("release.v064 failed; evidence: #{evidence_path}")
    end
  end

  defp run_release_v064_step(step, env) do
    started = System.monotonic_time(:millisecond)
    cwd = release_step_cwd(step.cwd)

    {output, exit_status} =
      System.cmd(step.executable, step.args, cd: cwd, env: env, stderr_to_stdout: true)

    duration_ms = System.monotonic_time(:millisecond) - started
    print_output("release.v064 #{step.id}", output)

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

  @release_v065_steps [
    %{
      id: "migrate",
      title: "prepare disposable database",
      cwd: :core,
      executable: "mix",
      args: ["ecto.migrate.allbert", "--quiet"],
      coverage: ["schema boot", "release-owned DATABASE_PATH"]
    },
    %{
      id: "format_check",
      title: "formatter check for v0.65 release candidate",
      cwd: :root,
      executable: "mix",
      args: ["format", "--check-formatted"],
      coverage: ["formatter drift fails the v0.65 local-knowledge handoff"]
    },
    %{
      id: "compile_warnings_as_errors",
      title: "compile v0.65 release candidate with warnings as errors",
      cwd: :root,
      executable: "mix",
      args: ["compile", "--warnings-as-errors"],
      coverage: ["compiler warnings fail the v0.65 local-knowledge handoff"]
    },
    %{
      id: "credo_strict",
      title: "Credo strict check for v0.65 release candidate",
      cwd: :root,
      executable: "mix",
      args: ["credo", "--strict"],
      coverage: ["Credo strict findings fail the v0.65 local-knowledge handoff"]
    },
    %{
      id: "dialyzer",
      title: "Dialyzer static analysis for v0.65 release candidate",
      cwd: :root,
      executable: "mix",
      args: ["dialyzer"],
      coverage: ["Dialyzer warnings fail the v0.65 local-knowledge handoff"]
    },
    %{
      id: "v065_notes_root_connect",
      title: "config-free notes-root connect action and admin notes CLI hold",
      cwd: :core,
      executable: "mix",
      args: [
        "test",
        "test/allbert_assist/actions/settings/set_notes_root_test.exs",
        "test/allbert_assist/cli/areas/notes_test.exs"
      ],
      coverage: [
        "set_notes_root validates the path, writes the single Settings Central safe key, and fails closed",
        "allbert admin notes set-root PATH persists/reads back the root and exits non-zero on a missing directory"
      ]
    },
    %{
      id: "v065_memory_status_recall",
      title: "admin memory status counts and reviewed-memory CLI surfaces hold",
      cwd: :core,
      executable: "mix",
      args: [
        "test",
        "test/mix/tasks/allbert_memory_test.exs"
      ],
      coverage: [
        "admin memory status reports exact scoped per-status counts, root, and explicit --all-users aggregate, not a bounded list sample",
        "review/update/delete/retrieve run through the CLI action surfaces with confirmation-gated delete"
      ]
    },
    %{
      id: "v065_memory_chat_loop",
      title: "launch-path memory write + recall route from natural chat phrasings",
      cwd: :core,
      executable: "mix",
      args: [
        "test",
        "test/allbert_assist/intent/descriptor_test.exs",
        "test/allbert_assist/actions/intent_actions_test.exs"
      ],
      coverage: [
        "append_memory extracts the memory content from remember/note-to-self phrasings, creating a reviewable candidate instead of a clarification",
        "read_recent_memory runs with no query so 'show what you remember' recalls recent memory instead of stalling on a missing slot"
      ]
    },
    %{
      id: "v065_local_knowledge_prompts",
      title: "launch-path local-knowledge first-chat prompts are always present",
      cwd: :core,
      executable: "mix",
      args: [
        "test",
        "test/allbert_assist/onboarding_test.exs"
      ],
      coverage: [
        "first_chat_prompts append the shared notes+memory local-knowledge set regardless of applied persona"
      ]
    },
    %{
      id: "v065_security_sweep",
      title: "v0.65 eval rows, notes/memory boundaries, and docs handoff hold",
      cwd: :core,
      executable: "mix",
      args: [
        "test",
        "test/security/v065_sweep_eval_test.exs"
      ],
      coverage: [
        "the :v065 row set is complete, shaped, routed, and bound to owning assertions",
        "notes reads stay root/extension bounded, write_note stays confirmation-gated, and the :notes_files namespace is non-writable",
        "memory review is user-controlled (keep=:kept, reject=:flagged), status counts are exact, and recall is :kept-only",
        "the workspace:memory panel dispatches registered actions with no new authority; v0.66 no-docs validation handoff is current"
      ]
    },
    %{
      id: "v065_web_notes_memory",
      title: "workspace:notes and workspace:memory destinations render and drive review",
      cwd: :root,
      executable: "mix",
      args: [
        "test",
        "apps/allbert_assist_web/test/allbert_assist_web/live/workspace/workspace_destinations_test.exs"
      ],
      coverage: [
        "the Notes nav item and workspace:notes destination render the action-backed notes panel with a real note",
        "the Memory nav item and workspace:memory destination drive keep/reject/delete through the Runner"
      ]
    },
    %{
      id: "v065_version_consistency",
      title: "umbrella apps agree on version (no cross-app :vsn drift at release)",
      cwd: :root,
      executable: "mix",
      args: [
        "test",
        "apps/allbert_assist_web/test/allbert_assist_web/version_consistency_test.exs"
      ],
      coverage: [
        "the CLI-banner app and the asset-version app agree on version"
      ]
    },
    %{
      id: "docs_gate",
      title: "docs gate and release-planning whitespace check",
      cwd: :root,
      executable: "mix",
      args: ["allbert.test", "docs"],
      coverage: ["git diff --check is clean", "docs gate is visible in release evidence"]
    }
  ]

  defp release_v065 do
    env = owned_env("release-v065", 0)
    home = env_value(env, "ALLBERT_HOME")
    database = env_value(env, "DATABASE_PATH")
    evidence_dir = Path.join(home, "release_evidence/v065")
    File.mkdir_p!(evidence_dir)

    started_at = DateTime.utc_now()
    results = Enum.map(@release_v065_steps, &run_release_v065_step(&1, env))

    status = if Enum.all?(results, &(&1.status == "passed")), do: "passed", else: "failed"

    evidence = %{
      gate: "mix allbert.test release.v065",
      version: "v0.65",
      status: status,
      generated_at: DateTime.utc_now() |> DateTime.to_iso8601(),
      started_at: DateTime.to_iso8601(started_at),
      allbert_home: home,
      database_path: database,
      evidence_dir: evidence_dir,
      external_network:
        "disabled; deterministic local-knowledge, notes-root connect, memory review/recall, and web destination proofs use local files, disposable Allbert homes, and reviewed-memory fixtures only",
      notes:
        "v0.65 Local Knowledge: Files, Notes, And Agent Memory makes the config-free notes-root connect affordance, root/extension-bounded reads, confirmation-gated writes, the non-writable :notes_files namespace, user-controlled memory review (keep=:kept, reject=:flagged, confirmation-gated delete), exact status counts, and :kept-only recall a testable product loop, and binds every :v065 security row to an owning assertion.",
      steps: results
    }

    evidence_path = Path.join(evidence_dir, "release-v065-#{DateTime.to_unix(started_at)}.json")
    File.write!(evidence_path, Jason.encode!(evidence, pretty: true))
    Mix.shell().info("release.v065 evidence: #{evidence_path}")

    if status != "passed" do
      Mix.raise("release.v065 failed; evidence: #{evidence_path}")
    end
  end

  defp run_release_v065_step(step, env) do
    started = System.monotonic_time(:millisecond)
    cwd = release_step_cwd(step.cwd)

    {output, exit_status} =
      System.cmd(step.executable, step.args, cd: cwd, env: env, stderr_to_stdout: true)

    duration_ms = System.monotonic_time(:millisecond) - started
    print_output("release.v065 #{step.id}", output)

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

  # v0.66 Product RC & No-Docs Validation gate. Two-layer verification (plan Locked
  # Decision 1): this checkout-bound gate proves contract/routing/boundary invariants
  # deterministically; install/browser/model/cross-platform claims are operator-attested
  # and reconciled in docs/validation/v0.66/. Steps are added milestone-by-milestone
  # (M1 skeleton -> M5-M9 proof buckets -> M8 delta-sweep -> M10 docs staleness -> M11
  # secret scan + finalize).
  @release_v066_steps [
    %{
      id: "migrate",
      title: "prepare disposable database",
      cwd: :core,
      executable: "mix",
      args: ["ecto.migrate.allbert", "--quiet"],
      coverage: ["schema boot", "release-owned DATABASE_PATH"]
    },
    %{
      id: "format_check",
      title: "formatter check for v0.66 release candidate",
      cwd: :root,
      executable: "mix",
      args: ["format", "--check-formatted"],
      coverage: ["formatter drift fails the v0.66 product-RC gate"]
    },
    %{
      id: "compile_warnings_as_errors",
      title: "compile v0.66 release candidate with warnings as errors",
      cwd: :root,
      executable: "mix",
      args: ["compile", "--warnings-as-errors"],
      coverage: ["compiler warnings fail the v0.66 product-RC gate"]
    },
    %{
      id: "credo_strict",
      title: "Credo strict check for v0.66 release candidate",
      cwd: :root,
      executable: "mix",
      args: ["credo", "--strict"],
      coverage: ["Credo strict findings fail the v0.66 product-RC gate"]
    },
    %{
      id: "dialyzer",
      title: "Dialyzer static analysis for v0.66 release candidate",
      cwd: :root,
      executable: "mix",
      args: ["dialyzer"],
      coverage: ["Dialyzer warnings fail the v0.66 product-RC gate"]
    },
    %{
      id: "v066_version_consistency",
      title: "umbrella apps agree on version (no cross-app :vsn drift at the RC)",
      cwd: :root,
      executable: "mix",
      args: [
        "test",
        "apps/allbert_assist_web/test/allbert_assist_web/version_consistency_test.exs"
      ],
      coverage: [
        "the CLI-banner app and the asset-version app agree on version at the v0.66 RC"
      ]
    },
    %{
      id: "v066_security_sweep",
      title: "v0.66 product-RC eval rows are complete, shaped, routed, and bound",
      cwd: :core,
      executable: "mix",
      args: [
        "test",
        "test/security/v066_sweep_eval_test.exs"
      ],
      coverage: [
        "every gate-bound product-rc-* row asserts a contract-level proxy (capability exposure, permission/confirmation floor, routing, or boundary), not live browser/model behavior",
        "each :v066 row binds its assert atoms in the owning sweep test; no prose-only/unbound rows"
      ]
    },
    %{
      id: "v066_web_render_dispatch",
      title: "workspace/jobs/objectives/settings LiveViews mount and dispatch without crashing",
      cwd: :root,
      executable: "mix",
      args: [
        "test",
        # Representative workspace render/dispatch (routing + notes/memory/channels/
        # settings destinations). M8.11b: full split files, never `file:LINE` — a
        # stale line pin excludes everything and false-greens the step. The
        # ~600-assert workspace_live_test monolith stays out entirely, so the gate
        # stays practical (workspace_live_test is 256-1400s).
        "apps/allbert_assist_web/test/allbert_assist_web/live/workspace/workspace_destinations_test.exs",
        "apps/allbert_assist_web/test/allbert_assist_web/live/workspace/workspace_settings_central_test.exs",
        "apps/allbert_assist_web/test/allbert_assist_web/live/jobs_live_test.exs",
        "apps/allbert_assist_web/test/allbert_assist_web/live/objectives_live_test.exs"
      ],
      coverage: [
        "the browser-pipeline LiveViews render and handle registered events without raising — the server-side render/dispatch contract behind product-rc-web-smoke-no-console-error-001 (representative workspace destinations + full jobs/objectives suites)"
      ]
    },
    %{
      id: "v066_cli_tui_dispatch",
      title: "grouped CLI/TUI dispatch, area routers, and first-run run without raw mix",
      cwd: :core,
      executable: "mix",
      args: [
        "test",
        "test/allbert_assist/cli/commands_test.exs",
        "test/allbert_assist/cli/dispatcher_test.exs",
        "test/allbert_assist/cli/tui_test.exs",
        "test/allbert_assist/cli/areas/notes_test.exs",
        "test/allbert_assist/cli/areas/model_test.exs",
        "test/allbert_assist/cli/areas/onboarding_test.exs"
      ],
      coverage: [
        "grouped help renders every group and states dev/CI stays under mix; operator verbs and admin reads dispatch through the operator table and registered actions, not raw mix — the contract behind product-rc-cli-tui-no-mix-needed-001"
      ]
    },
    %{
      id: "v066_local_knowledge",
      title:
        "launch-path notes-root bounding + reviewed-memory recall re-run as a v0.66 proof bucket",
      cwd: :core,
      executable: "mix",
      args: [
        "test",
        "test/allbert_assist/actions/settings/set_notes_root_test.exs",
        "test/allbert_assist/memory/active_memory_test.exs",
        "test/allbert_assist/memory/review_test.exs",
        "test/security/active_memory_eval_test.exs"
      ],
      coverage: [
        "the config-free notes-root connect fails closed on a bad path, reviewed-memory recall stays :kept-only, and review transitions are user-controlled — the runtime half of product-rc-local-files-notes-memory-policy-bounded-001 (recall in a later chat is operator-attested [model])"
      ]
    },
    %{
      id: "v066_advanced_surfaces",
      title:
        "advanced-surface exposure/floor evals re-run across public-protocol/channel/MCP/browser classes",
      cwd: :core,
      executable: "mix",
      args: [
        "test",
        "test/security/v051_public_protocol_eval_test.exs",
        "test/security/v053_channel_pack_eval_test.exs",
        "test/security/mcp_integration_eval_test.exs",
        "test/security/v043_browser_research_eval_test.exs",
        "test/security/v046_research_delegate_eval_test.exs"
      ],
      coverage: [
        "public surfaces deny internals by default, channels/MCP/browser keep their exposure and egress floors — the contract half of product-rc-advanced-surfaces-no-regression-001 (live per-class exercise is operator-attested [model]/[smoke] per Locked Decision 6)"
      ]
    },
    %{
      id: "v066_routing_first_model",
      title: "launch-path routing (no mis-route) + consumer-default first-model state machine",
      cwd: :core,
      executable: "mix",
      args: [
        "test",
        "test/allbert_assist/intent/descriptor_test.exs",
        "test/allbert_assist/actions/intent_actions_test.exs",
        "test/allbert_assist/cli/first_run_test.exs",
        "test/allbert_assist/onboarding_test.exs"
      ],
      coverage: [
        "remember/note-to-self write phrasings and query-less recall route without a needs-clarification stall (v0.63 F5 / v0.65 chat-bug class), the first-model state machine keeps a keyless-local consumer default with BYOK as fallback, and first_chat prompts carry the local-knowledge set — the contract behind product-rc-conversational-routing-no-misroute-001 and product-rc-consumer-default-oneclick-model-no-key-first-chat-001 (first useful chat is operator-attested [model])"
      ]
    },
    %{
      id: "v066_authority_delta",
      title:
        "no-authority sweeps re-run across the surfaces added since v0.59 (packaging, onboarding, notes/memory)",
      cwd: :core,
      executable: "mix",
      args: [
        "test",
        "test/security/v062_sweep_eval_test.exs",
        "test/security/v063_sweep_eval_test.exs",
        "test/security/v065_sweep_eval_test.exs"
      ],
      coverage: [
        "the v0.62 packaging, v0.63 onboarding/profile, and v0.65 notes/memory security sweeps still hold at the RC — the delta-sweep half of product-rc-profile-no-authority-regression-001 and product-rc-packaging-no-authority-regression-001"
      ]
    },
    %{
      id: "v066_portability",
      title: "Home export redaction + import dry-run/rollback portability re-run at the RC",
      cwd: :core,
      executable: "mix",
      args: [
        "test",
        "test/allbert_assist/portability/export_import_test.exs"
      ],
      coverage: [
        "an Allbert Home exports with secrets redacted (ref+status only) and imports as a dry-run that blocks before applying — the contract behind product-rc-export-import-upgrade-001 (a real cross-version upgrade + uninstall-preserves-Home are operator-attested [host]/[smoke])"
      ]
    },
    %{
      id: "v066_secret_scan",
      title: "redaction removes secret values/refs from logs, output, and evidence",
      cwd: :core,
      executable: "mix",
      args: [
        "test",
        "test/allbert_assist/runtime/redactor_test.exs"
      ],
      coverage: [
        "the runtime redactor strips secret key values and secret refs while preserving public fields — the contract behind product-rc-evidence-secret-scan-001; no raw secret reaches release evidence"
      ]
    },
    %{
      id: "docs_gate",
      title: "docs gate, staleness/index check, and release-planning whitespace check",
      cwd: :root,
      executable: "mix",
      args: ["allbert.test", "docs"],
      coverage: ["git diff --check is clean", "docs gate is visible in release evidence"]
    }
  ]

  defp release_v066 do
    env = owned_env("release-v066", 0)
    home = env_value(env, "ALLBERT_HOME")
    database = env_value(env, "DATABASE_PATH")
    evidence_dir = Path.join(home, "release_evidence/v066")
    File.mkdir_p!(evidence_dir)

    started_at = DateTime.utc_now()
    results = Enum.map(@release_v066_steps, &run_release_v066_step(&1, env))

    status = if Enum.all?(results, &(&1.status == "passed")), do: "passed", else: "failed"

    evidence = %{
      gate: "mix allbert.test release.v066",
      version: "v0.66",
      status: status,
      generated_at: DateTime.utc_now() |> DateTime.to_iso8601(),
      started_at: DateTime.to_iso8601(started_at),
      allbert_home: home,
      database_path: database,
      evidence_dir: evidence_dir,
      external_network:
        "disabled; this gate proves contract/routing/boundary invariants only. Install/browser/model/cross-platform claims are operator-attested and recorded in docs/validation/v0.66/, not here.",
      notes:
        "v0.66 Product RC & No-Docs Validation is a two-layer release: the deterministic release.v066 gate proves that every already-shipped product path (packaging, onboarding, local files/notes/memory, routing, advanced surfaces, export/import) stays behind the same action/settings/security spine and grants no new authority, while scripted host smokes, real-browser web smoke + the item-11 usability audit, cross-platform installs, and real-egress model/advanced-surface runs are attested at closeout.",
      steps: results
    }

    evidence_path = Path.join(evidence_dir, "release-v066-#{DateTime.to_unix(started_at)}.json")
    File.write!(evidence_path, Jason.encode!(evidence, pretty: true))
    Mix.shell().info("release.v066 evidence: #{evidence_path}")

    if status != "passed" do
      Mix.raise("release.v066 failed; evidence: #{evidence_path}")
    end
  end

  defp run_release_v066_step(step, env) do
    started = System.monotonic_time(:millisecond)
    cwd = release_step_cwd(step.cwd)

    {output, exit_status} =
      System.cmd(step.executable, step.args, cd: cwd, env: env, stderr_to_stdout: true)

    duration_ms = System.monotonic_time(:millisecond) - started
    print_output("release.v066 #{step.id}", output)

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

  # v1.0 Stability Release & Public Contract Freeze gate. Deterministic
  # freeze-enforcement: the :v1 sweep asserts every frozen Tier 1/Tier 2 contract
  # still exists by exact name (a rename/remove fails), plus the v0.66 product-RC
  # contract rows (the acceptance-matrix gate half) and the static/docs gates.
  # Attested acceptance-matrix rows (install/browser/model/cross-host) are the DIT
  # milestones in docs/plans/archives/v1.0-handoff.md, recorded under docs/validation/v1.0/.
  @release_v1_steps [
    %{
      id: "hex_audit",
      title: "audit locked dependencies for advisories and retirements",
      cwd: :root,
      executable: "mix",
      args: ["hex.audit"],
      coverage: ["known dependency vulnerabilities fail the v1.0 freeze gate"]
    },
    %{
      id: "migrate",
      title: "prepare disposable database",
      cwd: :core,
      executable: "mix",
      args: ["ecto.migrate.allbert", "--quiet"],
      coverage: ["schema boot", "release-owned DATABASE_PATH"]
    },
    %{
      id: "format_check",
      title: "formatter check for the v1.0 freeze",
      cwd: :root,
      executable: "mix",
      args: ["format", "--check-formatted"],
      coverage: ["formatter drift fails the v1.0 freeze gate"]
    },
    %{
      id: "compile_warnings_as_errors",
      title: "compile the v1.0 freeze with warnings as errors",
      cwd: :root,
      executable: "mix",
      args: ["compile", "--force", "--warnings-as-errors"],
      coverage: ["a forced rebuild makes compiler warnings fail the v1.0 freeze gate"]
    },
    %{
      id: "credo_strict",
      title: "Credo strict check for the v1.0 freeze",
      cwd: :root,
      executable: "mix",
      args: ["credo", "--strict"],
      coverage: ["Credo strict findings fail the v1.0 freeze gate"]
    },
    %{
      id: "dialyzer",
      title: "Dialyzer static analysis for the v1.0 freeze",
      cwd: :root,
      executable: "mix",
      args: ["dialyzer"],
      coverage: ["Dialyzer warnings fail the v1.0 freeze gate"]
    },
    %{
      id: "v1_version_consistency",
      title: "umbrella apps agree on version at the v1.0 freeze",
      cwd: :root,
      executable: "mix",
      args: [
        "test",
        "apps/allbert_assist_web/test/allbert_assist_web/version_consistency_test.exs"
      ],
      coverage: ["the CLI-banner app and the asset-version app agree on version at v1.0"]
    },
    %{
      id: "v1_freeze_sweep",
      title: "v1.0 public-contract freeze sweep: every frozen contract exists by exact name",
      cwd: :core,
      executable: "mix",
      args: [
        "test",
        "test/security/v1_sweep_eval_test.exs"
      ],
      coverage: [
        "the 7 :v1 freeze rows are complete, shaped, routed, and bound",
        "every frozen Tier 1/Tier 2 contract (functions, signals, DB columns, Settings keys, Home roots, permission classes, ADR 0021 A20) exists by exact name — a rename/remove fails"
      ]
    },
    %{
      id: "v1_product_rc_sweep",
      title: "v0.66 product-RC contract rows re-run as the v1.0 acceptance-matrix gate half",
      cwd: :core,
      executable: "mix",
      args: [
        "test",
        "test/security/v066_sweep_eval_test.exs"
      ],
      coverage: [
        "the 11 gate-bound product-rc-* contract rows still hold at the freeze; attested install/browser/model/cross-host rows are the DIT milestones in v1.0-handoff.md"
      ]
    },
    %{
      id: "docs_gate",
      title: "docs gate, staleness/index check, and release-planning whitespace check",
      cwd: :root,
      executable: "mix",
      args: ["allbert.test", "docs"],
      coverage: ["git diff --check is clean", "docs staleness/index check is clean"]
    }
  ]

  defp release_v1 do
    env = owned_env("release-v1", 0)
    home = env_value(env, "ALLBERT_HOME")
    database = env_value(env, "DATABASE_PATH")
    evidence_dir = Path.join(home, "release_evidence/v1")
    File.mkdir_p!(evidence_dir)

    started_at = DateTime.utc_now()
    results = Enum.map(@release_v1_steps, &run_release_v1_step(&1, env))

    status = if Enum.all?(results, &(&1.status == "passed")), do: "passed", else: "failed"

    evidence = %{
      gate: "mix allbert.test release.v1",
      version: "v1.0",
      status: status,
      generated_at: DateTime.utc_now() |> DateTime.to_iso8601(),
      started_at: DateTime.to_iso8601(started_at),
      allbert_home: home,
      database_path: database,
      evidence_dir: evidence_dir,
      external_network:
        "disabled; this gate proves the public-contract freeze deterministically (every frozen Tier 1/Tier 2 contract exists by exact name) plus the v0.66 product-RC contract rows. Install/browser/model/cross-host acceptance-matrix rows are operator-attested DIT milestones in docs/validation/v1.0/, not here.",
      notes:
        "v1.0 Stability Release & Public Contract Freeze: the :v1 sweep enforces the tiered freeze (docs/developer/public-contract-freeze.md) — a rename or removal of any frozen contract fails the gate while Tier 2 additive changes stay green. Re-runs the v0.66 product-RC contract rows as the acceptance-matrix gate half.",
      steps: results
    }

    evidence_path = Path.join(evidence_dir, "release-v1-#{DateTime.to_unix(started_at)}.json")
    File.write!(evidence_path, Jason.encode!(evidence, pretty: true))
    Mix.shell().info("release.v1 evidence: #{evidence_path}")

    if status != "passed" do
      Mix.raise("release.v1 failed; evidence: #{evidence_path}")
    end
  end

  defp run_release_v1_step(step, env) do
    started = System.monotonic_time(:millisecond)
    cwd = release_step_cwd(step.cwd)

    {output, exit_status} =
      System.cmd(step.executable, step.args, cd: cwd, env: env, stderr_to_stdout: true)

    duration_ms = System.monotonic_time(:millisecond) - started
    print_output("release.v1 #{step.id}", output)
    status = release_step_status("release.v1", step.id, exit_status, output)

    TestMetrics.record(%{
      gate: "release.v1",
      command: gate_command(),
      cwd: Path.relative_to(cwd, root()),
      phase_or_step: step.id,
      status: status,
      wall_ms: duration_ms,
      output: output
    })

    %{
      id: step.id,
      title: step.title,
      status: status,
      exit_status: exit_status,
      duration_ms: duration_ms,
      cwd: Path.relative_to(cwd, root()),
      command: shell_join([step.executable | step.args]),
      coverage: step.coverage,
      output_sha256: sha256(output),
      redacted_output_tail: output |> redact_release_output() |> tail(12_000)
    }
  end

  @v11_focused_steps [
    %{
      id: "v11_authority_sweep",
      title: "v1.1 fan-out authority and denial binding sweep",
      cwd: :core,
      executable: "mix",
      args: ["test", "test/security/v11_sweep_eval_test.exs"],
      coverage: ["eleven :v11 rows are concrete, routed, and AssertBinding-bound"]
    },
    %{
      id: "v11_runtime_fanout",
      title: "fan-out runtime, steering, and cancellation contracts",
      cwd: :core,
      executable: "mix",
      args: [
        "test",
        "test/allbert_assist/objectives/fanout_test.exs",
        "test/allbert_assist/objectives/fanout_steering_test.exs",
        "test/allbert_assist/objectives/delegate_cancel_test.exs",
        "test/allbert_assist/intent/steering_test.exs"
      ],
      coverage: ["durable fan-out, ownership, steering accuracy, and tiered cancellation"]
    },
    %{
      id: "v11_channel_authority",
      title: "channel notify, editing, and TUI attachment contracts",
      cwd: :core,
      executable: "mix",
      args: [
        "test",
        "test/allbert_assist/channels/notify_test.exs",
        "test/allbert_assist/channels/notify_edit_test.exs",
        "test/allbert_assist/channels/tui_subscriptions_test.exs"
      ],
      coverage: ["default-off authority, exact origin, edit-in-place, ephemeral TUI subscription"]
    },
    %{
      id: "v11_web_operator",
      title: "web fan-out operator controls",
      cwd: :web,
      executable: "mix",
      args: ["test", "test/allbert_assist_web/live/objective_live_test.exs"],
      coverage: ["fan-out tree and Runner-dispatched steer/cancel controls"]
    }
  ]

  @release_v11_steps @release_v1_steps ++ @v11_focused_steps

  defp release_v11 do
    env = owned_env("release-v11", 0)
    home = env_value(env, "ALLBERT_HOME")
    database = env_value(env, "DATABASE_PATH")
    evidence_dir = Path.join(home, "release_evidence/v11")
    File.mkdir_p!(evidence_dir)

    started_at = DateTime.utc_now()
    results = Enum.map(@release_v11_steps, &run_release_v11_step(&1, env))
    status = if Enum.all?(results, &(&1.status == "passed")), do: "passed", else: "failed"

    evidence = %{
      gate: "mix allbert.test release.v11",
      version: "v1.1",
      status: status,
      generated_at: DateTime.utc_now() |> DateTime.to_iso8601(),
      started_at: DateTime.to_iso8601(started_at),
      allbert_home: home,
      database_path: database,
      evidence_dir: evidence_dir,
      external_network:
        "disabled; configured live model/channel validation is recorded separately",
      notes:
        "release.v1 prefix plus v1.1 fan-out authority, runtime, channel, and operator-surface contracts",
      steps: results
    }

    evidence_path = Path.join(evidence_dir, "release-v11-#{DateTime.to_unix(started_at)}.json")
    File.write!(evidence_path, Jason.encode!(evidence, pretty: true))
    Mix.shell().info("release.v11 evidence: #{evidence_path}")

    if status != "passed", do: Mix.raise("release.v11 failed; evidence: #{evidence_path}")
  end

  defp run_release_v11_step(step, env) do
    started = System.monotonic_time(:millisecond)
    cwd = release_step_cwd(step.cwd)

    {output, exit_status} =
      System.cmd(step.executable, step.args, cd: cwd, env: env, stderr_to_stdout: true)

    duration_ms = System.monotonic_time(:millisecond) - started
    print_output("release.v11 #{step.id}", output)
    status = release_step_status("release.v11", step.id, exit_status, output)

    TestMetrics.record(%{
      gate: "release.v11",
      command: gate_command(),
      cwd: Path.relative_to(cwd, root()),
      phase_or_step: step.id,
      status: status,
      wall_ms: duration_ms,
      output: output
    })

    %{
      id: step.id,
      title: step.title,
      status: status,
      exit_status: exit_status,
      duration_ms: duration_ms,
      cwd: Path.relative_to(cwd, root()),
      command: shell_join([step.executable | step.args]),
      coverage: step.coverage,
      output_sha256: sha256(output),
      redacted_output_tail: output |> redact_release_output() |> tail(12_000)
    }
  end

  # M8.11b false-green repair: a release step that exits 0 while its ExUnit
  # output shows ZERO executed tests is a FALSE GREEN, not a pass — the
  # recorded failure mode is a stale `file:LINE` pin excluding every test
  # ("All tests have been excluded." then "0 tests, 0 failures (N excluded)"
  # with exit 0). Any step whose output carries ExUnit totals must have
  # executed at least one test; steps that never run ExUnit (format, credo,
  # dialyzer, docs, file-presence checks) print no totals line and are
  # judged by exit status alone.
  @exunit_totals_marker ~r/\b\d+ tests?, \d+ failures?/

  @doc false
  def release_step_status(gate, step_id, exit_status, output) do
    cond do
      exit_status != 0 ->
        "failed"

      exunit_ran_zero_tests?(output) ->
        Mix.shell().error(
          "#{gate} #{step_id}: FAILED — ExUnit executed zero tests " <>
            "(totals sum to 0; \"All tests have been excluded\" is red, not green)"
        )

        "failed"

      true ->
        "passed"
    end
  end

  defp exunit_ran_zero_tests?(output) do
    Regex.match?(@exunit_totals_marker, output) and
      TestMetrics.sum_exunit_totals(output).tests == 0
  end

  # v1.0.1: the point gate is the full v1 freeze/product-RC prefix plus focused
  # v1.0.1 steps (plan Locked Decision 8) so freeze coverage cannot drift from
  # the point gate.
  @v101_focused_steps [
    %{
      id: "v101_asset_digest",
      title: "R15: app stylesheet flows through the digest manifest (no version query)",
      cwd: :root,
      executable: "mix",
      args: [
        "test",
        "apps/allbert_assist_web/test/allbert_assist_web/controllers/theme_controller_test.exs"
      ],
      coverage: [
        "the layout links /assets/css/app.css with no ?v= query so prod static_lookup digests it (R15)"
      ]
    },
    %{
      id: "v101_design_tokens",
      title:
        "operator surfaces hold the design-system token contract (btn drift, list form included)",
      cwd: :root,
      executable: "mix",
      args: [
        "test",
        "apps/allbert_assist_web/test/allbert_assist_web/workspace/design_system_tokens_test.exs"
      ],
      coverage: [
        "zero raw daisy btn classes in production web source; tightened regex catches class={[...]} list forms"
      ]
    },
    %{
      id: "v101_offline_sw",
      title: "offline service-worker guard is order-independent and version-locked",
      cwd: :root,
      executable: "mix",
      args: [
        "test",
        "apps/allbert_assist_web/test/allbert_assist_web/workspace/offline_test.exs"
      ],
      coverage: [
        "compile-time version keeps the :pure_async lane contract; CACHE_NAME matches the app version"
      ]
    },
    %{
      id: "v101_dit5_evidence",
      title: "DIT-5 upgrade/uninstall transcript present in the v1.0 evidence set",
      cwd: :root,
      executable: "test",
      args: ["-f", "docs/validation/v1.0/dit5-upgrade-uninstall.log"],
      coverage: [
        "the v1.0 evidence matrix DIT-5 row resolves to a real transcript (content is operator-attested)"
      ]
    }
  ]

  @release_v101_steps @release_v1_steps ++ @v101_focused_steps

  defp release_v101 do
    env = owned_env("release-v101", 0)
    home = env_value(env, "ALLBERT_HOME")
    database = env_value(env, "DATABASE_PATH")
    evidence_dir = Path.join(home, "release_evidence/v101")
    File.mkdir_p!(evidence_dir)

    started_at = DateTime.utc_now()
    results = Enum.map(@release_v101_steps, &run_release_v101_step(&1, env))

    status = if Enum.all?(results, &(&1.status == "passed")), do: "passed", else: "failed"

    evidence = %{
      gate: "mix allbert.test release.v101",
      version: "v1.0.1",
      status: status,
      generated_at: DateTime.utc_now() |> DateTime.to_iso8601(),
      started_at: DateTime.to_iso8601(started_at),
      allbert_home: home,
      database_path: database,
      evidence_dir: evidence_dir,
      external_network:
        "disabled; the release.v1 freeze/product-RC prefix re-runs unchanged, then the v1.0.1 focused steps prove the point-release fixes deterministically. Packaged digested-CSS/SW smoke and browser checks are operator-attested per docs/plans/v1.0.1-request-flow.md.",
      notes:
        "v1.0.1 Post-1.0 Remediation Point Release: steps = the release.v1 quintet plus focused v1.0.1 steps (R15 digest cache-busting, btn drift guard, offline SW version lock, DIT-5 evidence presence).",
      steps: results
    }

    evidence_path = Path.join(evidence_dir, "release-v101-#{DateTime.to_unix(started_at)}.json")
    File.write!(evidence_path, Jason.encode!(evidence, pretty: true))
    Mix.shell().info("release.v101 evidence: #{evidence_path}")

    if status != "passed" do
      Mix.raise("release.v101 failed; evidence: #{evidence_path}")
    end
  end

  defp run_release_v101_step(step, env) do
    started = System.monotonic_time(:millisecond)
    cwd = release_step_cwd(step.cwd)

    {output, exit_status} =
      System.cmd(step.executable, step.args, cd: cwd, env: env, stderr_to_stdout: true)

    duration_ms = System.monotonic_time(:millisecond) - started
    print_output("release.v101 #{step.id}", output)
    status = release_step_status("release.v101", step.id, exit_status, output)

    TestMetrics.record(%{
      gate: "release.v101",
      command: gate_command(),
      cwd: Path.relative_to(cwd, root()),
      phase_or_step: step.id,
      status: status,
      wall_ms: duration_ms,
      output: output
    })

    %{
      id: step.id,
      title: step.title,
      status: status,
      exit_status: exit_status,
      duration_ms: duration_ms,
      cwd: Path.relative_to(cwd, root()),
      command: shell_join([step.executable | step.args]),
      coverage: step.coverage,
      output_sha256: sha256(output),
      redacted_output_tail: output |> redact_release_output() |> tail(12_000)
    }
  end

  @v102_focused_steps [
    %{
      id: "v102_lane_reconciliation",
      title: "lane taxonomy reconciles: every test file carries exactly one audited primary lane",
      cwd: :root,
      executable: "mix",
      args: ["allbert.test", "inventory", "--check-tags"],
      coverage: [
        "inventory --check-tags exits 0 with zero findings (M1 reconciliation holds; adjudications audited)"
      ]
    },
    %{
      id: "v102_manifest_drift",
      title: "committed per-test manifest matches a live regeneration (M8.9 no-loss invariant)",
      cwd: :root,
      executable: "mix",
      args: ["allbert.test", "inventory", "--check-manifest"],
      coverage: [
        "inventory --check-manifest exits 0: docs/validation/test-manifest.csv reconciles per-test identities, lane tags, skip tags, and execution multiplicities against the live tree (M8.9)"
      ]
    },
    %{
      id: "v102_residue_workspace",
      title: "residue (a): first-run marker test deterministic in its post-split home",
      cwd: :root,
      executable: "mix",
      args: [
        "test",
        "apps/allbert_assist_web/test/allbert_assist_web/live/workspace/workspace_onboarding_test.exs"
      ],
      coverage: [
        "owned home + db/allbert.sqlite3 marker keeps the completed-onboarding repair panel deterministic (M1 fix (a), M4 home)"
      ]
    },
    %{
      id: "v102_residue_tui",
      title:
        "residue (b): v0.55 TUI channel eval asserts on the turn tail, not absolute positions",
      cwd: :core,
      executable: "mix",
      args: ["test", "test/security/v055_tui_channel_eval_test.exs"],
      coverage: [
        "runtime thread reuse cannot flip the eval; security_eval_serial lane contract holds (M1 fix (b))"
      ]
    },
    %{
      id: "v102_residue_intent_agent",
      title: "residue (c): intent agent registry baseline is seeded per test",
      cwd: :core,
      executable: "mix",
      args: ["test", "test/allbert_assist/agents/intent_agent_test.exs"],
      coverage: [
        "registry baseline seeding keeps the exposed-action list deterministic (M1 fix (c))"
      ]
    },
    %{
      id: "v102_residue_corpus",
      title: "residue (d): corpus completeness owns its registry seed",
      cwd: :core,
      executable: "mix",
      args: ["test", "test/allbert_assist/intent/eval/corpus_completeness_test.exs"],
      coverage: ["corpus rows resolve against a seeded registry (M1 fix (d))"]
    },
    %{
      id: "v102_residue_golden",
      title: "residue (e): golden set re-asserts research descriptors before running",
      cwd: :core,
      executable: "mix",
      args: ["test", "test/allbert_assist/intent/golden_set_test.exs"],
      coverage: [
        "ensure_research_descriptors! precondition keeps the golden set order-independent (M1 fix (e))"
      ]
    },
    %{
      id: "v102_residue_batch_matrix",
      title: "residue leak pair green in BOTH previously-flipping orders",
      cwd: :core,
      executable: "sh",
      args: [
        "-c",
        "MIX_ENV=test mix test test/security/v046_research_delegate_eval_test.exs test/allbert_assist/intent/golden_set_test.exs --seed 0 && MIX_ENV=test mix test test/allbert_assist/intent/golden_set_test.exs test/security/v046_research_delegate_eval_test.exs --seed 0"
      ],
      coverage: [
        "the v046+golden leak pair passes in both recorded prior-failing orders (M1 residue matrix rows 6/7)"
      ]
    },
    %{
      id: "v102_web_lanes",
      title: "post-split web lanes run partitioned and green",
      cwd: :root,
      executable: "mix",
      args: ["allbert.test", "fast-local", "--web-lanes", "--partitions", "4"],
      coverage: [
        "the seven M4 split files fold into --web-lanes; the live-Runtime remainder stays out (Locked Decision 5)"
      ]
    },
    %{
      id: "v102_deps_migration_backup",
      title:
        "M7 wave-2 persistence layer: migration serialization and backup/restore hold on ecto 3.14 + exqlite 0.39",
      cwd: :core,
      executable: "mix",
      args: [
        "test",
        "test/allbert_assist/database_test.exs",
        "test/allbert_assist/database_backup_test.exs"
      ],
      coverage: [
        "startup migrations serialize concurrent first-boot attempts and backup-before-migrate restores on the refreshed ecto/exqlite pack"
      ]
    },
    %{
      id: "v102_deps_workflows",
      title: "M7 wave-1 jsv 0.21 still validates the workflow YAML surface",
      cwd: :core,
      executable: "mix",
      args: ["test", "test/allbert_assist/workflows"],
      coverage: ["workflow schema/validator suites green on jsv 0.21.2"]
    }
  ]

  @release_v102_steps @release_v1_steps ++ @v102_focused_steps

  defp release_v102 do
    env = owned_env("release-v102", 0)
    home = env_value(env, "ALLBERT_HOME")
    database = env_value(env, "DATABASE_PATH")
    evidence_dir = Path.join(home, "release_evidence/v102")
    File.mkdir_p!(evidence_dir)

    started_at = DateTime.utc_now()
    results = Enum.map(@release_v102_steps, &run_release_v102_step(&1, env))

    status = if Enum.all?(results, &(&1.status == "passed")), do: "passed", else: "failed"

    evidence = %{
      gate: "mix allbert.test release.v102",
      version: "v1.0.2",
      status: status,
      generated_at: DateTime.utc_now() |> DateTime.to_iso8601(),
      started_at: DateTime.to_iso8601(started_at),
      allbert_home: home,
      database_path: database,
      evidence_dir: evidence_dir,
      external_network:
        "disabled; the release.v1 freeze/product-RC prefix re-runs unchanged, then the v1.0.2 focused steps prove lane reconciliation, the five de-flaked residues (solo + both batch orders), the post-split web lanes, and the refreshed dependency surfaces deterministically. Packaged artifact validation is M9 (operator-held, published-artifact attestations).",
      notes:
        "v1.0.2 Test Isolation Phase 1 & Catch-up Binary Release: steps = the release.v1 quintet plus focused v1.0.2 steps (lane reconciliation, residue solos + batch matrix, web-lane fold, M7 dependency proofs).",
      steps: results
    }

    evidence_path = Path.join(evidence_dir, "release-v102-#{DateTime.to_unix(started_at)}.json")
    File.write!(evidence_path, Jason.encode!(evidence, pretty: true))
    Mix.shell().info("release.v102 evidence: #{evidence_path}")

    if status != "passed" do
      Mix.raise("release.v102 failed; evidence: #{evidence_path}")
    end
  end

  defp run_release_v102_step(step, env) do
    started = System.monotonic_time(:millisecond)
    cwd = release_step_cwd(step.cwd)

    {output, exit_status} =
      System.cmd(step.executable, step.args, cd: cwd, env: env, stderr_to_stdout: true)

    duration_ms = System.monotonic_time(:millisecond) - started
    print_output("release.v102 #{step.id}", output)
    status = release_step_status("release.v102", step.id, exit_status, output)

    TestMetrics.record(%{
      gate: "release.v102",
      command: gate_command(),
      cwd: Path.relative_to(cwd, root()),
      phase_or_step: step.id,
      status: status,
      wall_ms: duration_ms,
      output: output
    })

    %{
      id: step.id,
      title: step.title,
      status: status,
      exit_status: exit_status,
      duration_ms: duration_ms,
      cwd: Path.relative_to(cwd, root()),
      command: shell_join([step.executable | step.args]),
      coverage: step.coverage,
      output_sha256: sha256(output),
      redacted_output_tail: output |> redact_release_output() |> tail(12_000)
    }
  end

  # v1.0.3 Test Isolation Phase 2 & Catch-up Binary Release. The gate is the
  # full v1 freeze/product-RC prefix (@release_v1_steps) plus focused v1.0.3
  # steps that prove, deterministically in every gate run, the two root-fixed
  # flake classes and the four M1 ownership-contract pilots.
  #
  # Operator decision (2026-07-20, recorded): the 20-seed monolith RC campaign
  # is SKIPPED. v1.0.3 ships on the two banked clean scratchpad seeds
  # (1000/2000: exit 0, 0 failures, both retired-class signatures absent) PLUS
  # the two PERMANENT regression steps below (v103_sidebar_ownership,
  # v103_list_channels_context) that guard both classes deterministically in
  # every gate run — that pair, not a seed sweep, is the acceptance basis.
  # The operator explicitly accepted that this proves the two known roots but
  # is narrower than a 20-seed unknown-ordering campaign.
  #
  # Every focused test-file step selects a FULL split file (never file:LINE) so
  # the M8.11b zero-test guard in release_step_status/4 can never false-green on
  # an over-excluded pin, and no step passes --slowest (which would force
  # ExUnit to max_cases: 1 and defeat the concurrency the lanes now buy).
  @v103_focused_steps [
    %{
      id: "v103_lane_reconciliation",
      title: "lane taxonomy reconciles: every test file carries exactly one audited primary lane",
      cwd: :root,
      executable: "mix",
      args: ["allbert.test", "inventory", "--check-tags"],
      coverage: [
        "inventory --check-tags exits 0 with zero findings (M1/M2/M3 re-laning holds; adjudications audited)"
      ]
    },
    %{
      id: "v103_manifest_drift",
      title: "committed per-test manifest matches a live regeneration (M8.9 no-loss invariant)",
      cwd: :root,
      executable: "mix",
      args: ["allbert.test", "inventory", "--check-manifest"],
      coverage: [
        "inventory --check-manifest exits 0: docs/validation/test-manifest.csv reconciles per-test identities, lane tags, skip tags, and execution multiplicities against the live tree"
      ]
    },
    %{
      id: "v103_pilot_db",
      title: "M1 db pilot: contract-1 sandbox-ownership proof holds (db_partition_safe)",
      cwd: :core,
      executable: "mix",
      args: ["test", "test/allbert_assist/objectives/objective_test.exs"],
      coverage: [
        "objectives frame/cancel run under a per-test non-shared owner with an allowance for the engine agent; the committed ownership-fence proof is green (ADR 0086 contract 1)"
      ]
    },
    %{
      id: "v103_pilot_app_env",
      title: "M1 app_env pilot: contract-2 ConfigContext isolation proof holds (pure_async)",
      cwd: :core,
      executable: "mix",
      args: ["test", "test/allbert_assist/intent/eval/gate_test.exs"],
      coverage: [
        "concurrent contradictory operator floors resolve per-process; a context-free parent still resolves the default (ADR 0086 contract 2)"
      ]
    },
    %{
      id: "v103_pilot_global_process",
      title: "M1 global_process pilot: contract-3 two-context negative proof holds (pure_async)",
      cwd: :core,
      executable: "mix",
      args: ["test", "test/allbert_assist/actions/app_actions_test.exs"],
      coverage: [
        "private supervised registry pairs host two contexts without the singleton :app_id_taken clash; reads travel the internal registry context (ADR 0086 contract 3, ADR 0082 pattern)"
      ]
    },
    %{
      id: "v103_pilot_home_fs",
      title: "M1 home_fs pilot: contract-4 owned-root proof holds (home_fs_serial)",
      cwd: :core,
      executable: "mix",
      args: ["test", "test/allbert_assist/actions/browser_actions_test.exs"],
      coverage: [
        "the OS-pid-qualified, pre-cleaned owned root keeps every exercised Paths read inside it and sweeps planted stale poison (ADR 0086 contract 4, ADR 0031 stay-serial decision)"
      ]
    },
    %{
      id: "v103_sidebar_ownership",
      title:
        "M2 permanent regression: DBConnection-ownership class retired at the sandbox lease root",
      cwd: :web,
      executable: "mix",
      args: ["test", "test/allbert_assist_web/v103/sidebar_ownership_test.exs"],
      coverage: [
        "the sandbox lease is sized from the test's declared budget (DataCase.sandbox_ownership_timeout/1); ExUnit's timeout fires first, so the workspace mount never raises the campaign 'using mode :manual' ownership signature"
      ]
    },
    %{
      id: "v103_list_channels_context",
      title:
        "M3 permanent regression: registry/ListChannels class retired via plugin-context propagation",
      cwd: :core,
      executable: "mix",
      args: ["test", "test/allbert_assist/actions/channels/list_channels_context_test.exs"],
      coverage: [
        "ListChannels.run/2 forwards the internal registry context to Channels.list_channels/1, so a neighbor's registry mutation cannot cross-contaminate the channel list"
      ]
    }
  ]

  @release_v103_steps @release_v1_steps ++ @v103_focused_steps

  defp release_v103 do
    env = owned_env("release-v103", 0)
    home = env_value(env, "ALLBERT_HOME")
    database = env_value(env, "DATABASE_PATH")
    evidence_dir = Path.join(home, "release_evidence/v103")
    File.mkdir_p!(evidence_dir)

    started_at = DateTime.utc_now()
    results = Enum.map(@release_v103_steps, &run_release_v103_step(&1, env))

    status = if Enum.all?(results, &(&1.status == "passed")), do: "passed", else: "failed"

    evidence = %{
      gate: "mix allbert.test release.v103",
      version: "v1.0.3",
      status: status,
      generated_at: DateTime.utc_now() |> DateTime.to_iso8601(),
      started_at: DateTime.to_iso8601(started_at),
      allbert_home: home,
      database_path: database,
      evidence_dir: evidence_dir,
      external_network:
        "disabled; the release.v1 freeze/product-RC prefix re-runs unchanged, then the v1.0.3 focused steps prove lane reconciliation, manifest no-loss, the four M1 ownership-contract pilots, and the two permanent monolith-class regressions (M2 sidebar ownership, M3 ListChannels context) deterministically. The 20-seed RC campaign is SKIPPED by operator decision; two clean banked monolith seeds plus the permanent regression steps are the narrower accepted evidence for the two known roots, not an exhaustive ordering campaign. Packaged artifact validation is M10 (operator-held, published-artifact attestations).",
      notes:
        "v1.0.3 Test Isolation Phase 2 & Catch-up Binary Release: steps = the release.v1 quintet plus focused v1.0.3 steps (lane reconciliation, manifest drift, four M1 pilots, two permanent flake-class regressions).",
      steps: results
    }

    evidence_path = Path.join(evidence_dir, "release-v103-#{DateTime.to_unix(started_at)}.json")
    File.write!(evidence_path, Jason.encode!(evidence, pretty: true))
    Mix.shell().info("release.v103 evidence: #{evidence_path}")

    if status != "passed" do
      Mix.raise("release.v103 failed; evidence: #{evidence_path}")
    end
  end

  defp run_release_v103_step(step, env) do
    started = System.monotonic_time(:millisecond)
    cwd = release_step_cwd(step.cwd)

    {output, exit_status} =
      System.cmd(step.executable, step.args, cd: cwd, env: env, stderr_to_stdout: true)

    duration_ms = System.monotonic_time(:millisecond) - started
    print_output("release.v103 #{step.id}", output)
    status = release_step_status("release.v103", step.id, exit_status, output)

    TestMetrics.record(%{
      gate: "release.v103",
      command: gate_command(),
      cwd: Path.relative_to(cwd, root()),
      phase_or_step: step.id,
      status: status,
      wall_ms: duration_ms,
      output: output
    })

    %{
      id: step.id,
      title: step.title,
      status: status,
      exit_status: exit_status,
      duration_ms: duration_ms,
      cwd: Path.relative_to(cwd, root()),
      command: shell_join([step.executable | step.args]),
      coverage: step.coverage,
      output_sha256: sha256(output),
      redacted_output_tail: output |> redact_release_output() |> tail(12_000)
    }
  end

  # v1.0.4 Packaged Browser Recovery. Source-level proof keeps the permanent
  # v1.0.3 ownership guards, adds release assembly/runtime contracts for the
  # explicit external-browser boundary, and leaves the real extracted-artifact
  # doctor to the native CI matrix.
  @v104_focused_steps [
    %{
      id: "v104_lane_reconciliation",
      title: "lane taxonomy remains reconciled after hotfix tests",
      cwd: :root,
      executable: "mix",
      args: ["allbert.test", "inventory", "--check-tags"],
      coverage: ["every test file carries exactly one audited primary lane"]
    },
    %{
      id: "v104_manifest_drift",
      title: "committed per-test manifest matches the live hotfix tree",
      cwd: :root,
      executable: "mix",
      args: ["allbert.test", "inventory", "--check-manifest"],
      coverage: ["no test identity, lane, skip, or multiplicity disappeared"]
    },
    %{
      id: "v104_release_boundary_contract",
      title: "release assembly excludes host browser runtimes and requires live external proof",
      cwd: :core,
      executable: "mix",
      args: ["test", "test/allbert_assist/install_path_test.exs"],
      coverage: [
        "Node/Playwright/Chromium are absent from artifacts; the artifact harness requires explicit host paths, a live doctor, and no runtime installer/download"
      ]
    },
    %{
      id: "v104_playwright_runtime_contract",
      title: "Playwright bridge preserves host-managed runtime paths and diagnostics",
      cwd: :core,
      executable: "mix",
      args: ["test", "test/allbert_assist/browser/playwright_driver_test.exs"],
      coverage: [
        "the spawned bridge uses explicit host module/browser paths and reports missing Playwright without running a package manager"
      ]
    },
    %{
      id: "v104_browser_doctor_categories",
      title: "browser doctor preserves actionable host-runtime categories",
      cwd: :core,
      executable: "mix",
      args: ["test", "test/allbert_assist/actions/browser_actions_test.exs"],
      coverage: [
        "missing host Playwright is unavailable; a version mismatch is a failed compatibility check; both persist stable categories"
      ]
    },
    %{
      id: "v104_version_consistency",
      title: "mix applications and service-worker cache identify one current release version",
      cwd: :web,
      executable: "mix",
      args: ["test", "test/allbert_assist_web/version_consistency_test.exs"],
      coverage: ["mix trio, CoreApp version, service-worker cache, and gzip stay in lockstep"]
    },
    %{
      id: "v104_sidebar_ownership",
      title: "v1.0.3 DBConnection ownership regression remains retired",
      cwd: :web,
      executable: "mix",
      args: ["test", "test/allbert_assist_web/v103/sidebar_ownership_test.exs"],
      coverage: ["hotfix work does not lose the permanent sandbox-lease ownership guard"]
    },
    %{
      id: "v104_list_channels_context",
      title: "v1.0.3 registry/ListChannels regression remains retired",
      cwd: :core,
      executable: "mix",
      args: ["test", "test/allbert_assist/actions/channels/list_channels_context_test.exs"],
      coverage: ["hotfix work does not lose the permanent registry-context guard"]
    }
  ]

  @release_v104_steps @release_v1_steps ++ @v104_focused_steps

  defp release_v104 do
    env = owned_env("release-v104", 0)
    home = env_value(env, "ALLBERT_HOME")
    database = env_value(env, "DATABASE_PATH")
    evidence_dir = Path.join(home, "release_evidence/v104")
    File.mkdir_p!(evidence_dir)

    started_at = DateTime.utc_now()
    results = Enum.map(@release_v104_steps, &run_release_v104_step(&1, env))
    status = if Enum.all?(results, &(&1.status == "passed")), do: "passed", else: "failed"

    evidence = %{
      gate: "mix allbert.test release.v104",
      version: "v1.0.4",
      status: status,
      generated_at: DateTime.utc_now() |> DateTime.to_iso8601(),
      started_at: DateTime.to_iso8601(started_at),
      allbert_home: home,
      database_path: database,
      evidence_dir: evidence_dir,
      external_network:
        "disabled; release.v104 proves source contracts only. Native CI provisions pinned Playwright and an OS browser outside each artifact, then every extracted artifact must pass the live doctor before upload.",
      notes:
        "v1.0.4 Packaged Browser Recovery: release.v1 plus inventory/manifest, external browser-runtime boundary, version consistency, and the two v1.0.3 permanent ownership regressions.",
      steps: results
    }

    evidence_path = Path.join(evidence_dir, "release-v104-#{DateTime.to_unix(started_at)}.json")
    File.write!(evidence_path, Jason.encode!(evidence, pretty: true))
    Mix.shell().info("release.v104 evidence: #{evidence_path}")

    if status != "passed" do
      Mix.raise("release.v104 failed; evidence: #{evidence_path}")
    end
  end

  defp run_release_v104_step(step, env) do
    started = System.monotonic_time(:millisecond)
    cwd = release_step_cwd(step.cwd)

    {output, exit_status} =
      System.cmd(step.executable, step.args, cd: cwd, env: env, stderr_to_stdout: true)

    duration_ms = System.monotonic_time(:millisecond) - started
    print_output("release.v104 #{step.id}", output)
    status = release_step_status("release.v104", step.id, exit_status, output)

    TestMetrics.record(%{
      gate: "release.v104",
      command: gate_command(),
      cwd: Path.relative_to(cwd, root()),
      phase_or_step: step.id,
      status: status,
      wall_ms: duration_ms,
      output: output
    })

    %{
      id: step.id,
      title: step.title,
      status: status,
      exit_status: exit_status,
      duration_ms: duration_ms,
      cwd: Path.relative_to(cwd, root()),
      command: shell_join([step.executable | step.args]),
      coverage: step.coverage,
      output_sha256: sha256(output),
      redacted_output_tail: output |> redact_release_output() |> tail(12_000)
    }
  end

  # v1.0.5 preserves every v1.0.4 recovery contract and adds an explicit
  # regression for the platform-specific Erlang port visibility option.
  @v105_focused_steps [
    %{
      id: "v105_settings_cross_process_transaction",
      title: "Settings writes are one cross-process transaction",
      cwd: :core,
      executable: "mix",
      args: ["test", "test/allbert_assist/settings/store_cross_process_race_test.exs"],
      coverage: ["Separate BEAM processes preserve disjoint Settings writes in one Allbert Home"]
    },
    %{
      id: "v105_service_confirmation_lifecycle",
      title: "Service approval and manager lifecycle remain distinct",
      cwd: :core,
      executable: "mix",
      args: [
        "test",
        "test/allbert_assist/serve_test.exs",
        "test/allbert_assist/actions/confirmations_actions_test.exs",
        "test/mix/tasks/allbert_confirmations_test.exs"
      ],
      coverage: [
        "Approved service control remains approved while systemd outcome is annotated separately"
      ]
    },
    %{
      id: "v105_configured_local_first_run",
      title: "Configured local endpoints drive first-run readiness",
      cwd: :core,
      executable: "mix",
      args: [
        "test",
        "test/allbert_assist/cli/first_run_test.exs",
        "test/allbert_assist/cli/areas/model_test.exs"
      ],
      coverage: ["A reachable selected model on a configured local endpoint is local-ready"]
    },
    %{
      id: "v105_onboarding_tui_completion",
      title: "Onboarding and TUI share first-chat readiness",
      cwd: :core,
      executable: "mix",
      args: [
        "test",
        "test/allbert_assist/onboarding_test.exs",
        "test/allbert_assist/cli/tui_test.exs"
      ],
      coverage: ["The wizard cannot complete while the selected model is unavailable"]
    },
    %{
      id: "v105_packaged_tui_bootstrap",
      title: "Packaged TUI waits for registry and Settings readiness",
      cwd: :core,
      executable: "mix",
      args: [
        "test",
        "test/allbert_assist/cli/tui_test.exs",
        "test/allbert_assist/channels_test.exs"
      ],
      coverage: [
        "A fresh release process resolves a persisted host-local provider before starting the interactive TUI child"
      ]
    },
    %{
      id: "v105_platform_port_visibility",
      title: "Playwright bridge hides its console only on Windows",
      cwd: :core,
      executable: "mix",
      args: ["test", "test/allbert_assist/browser/playwright_driver_test.exs"],
      coverage: [
        "Windows retains :hide while Darwin/Linux omit it, preventing the packaged macOS Chrome TransformProcessType crash"
      ]
    }
  ]

  @release_v105_steps @release_v104_steps ++ @v105_focused_steps

  defp release_v105 do
    env = owned_env("release-v105", 0)
    home = env_value(env, "ALLBERT_HOME")
    database = env_value(env, "DATABASE_PATH")
    evidence_dir = Path.join(home, "release_evidence/v105")
    File.mkdir_p!(evidence_dir)

    started_at = DateTime.utc_now()
    results = Enum.map(@release_v105_steps, &run_release_v105_step(&1, env))
    status = if Enum.all?(results, &(&1.status == "passed")), do: "passed", else: "failed"

    evidence = %{
      gate: "mix allbert.test release.v105",
      version: "v1.0.5",
      status: status,
      generated_at: DateTime.utc_now() |> DateTime.to_iso8601(),
      started_at: DateTime.to_iso8601(started_at),
      allbert_home: home,
      database_path: database,
      evidence_dir: evidence_dir,
      external_network:
        "disabled; release.v105 proves source contracts only. Native CI supplies host-managed Node, Playwright, and the OS browser, then requires every extracted artifact to pass the live doctor.",
      notes:
        "v1.0.5 RC remediation: complete release.v104 coverage plus cross-process Settings, service lifecycle, configured-local readiness, onboarding/TUI completion, and platform port visibility regressions.",
      steps: results
    }

    evidence_path = Path.join(evidence_dir, "release-v105-#{DateTime.to_unix(started_at)}.json")
    File.write!(evidence_path, Jason.encode!(evidence, pretty: true))
    Mix.shell().info("release.v105 evidence: #{evidence_path}")

    if status != "passed" do
      Mix.raise("release.v105 failed; evidence: #{evidence_path}")
    end
  end

  defp run_release_v105_step(step, env) do
    started = System.monotonic_time(:millisecond)
    cwd = release_step_cwd(step.cwd)

    {output, exit_status} =
      System.cmd(step.executable, step.args, cd: cwd, env: env, stderr_to_stdout: true)

    duration_ms = System.monotonic_time(:millisecond) - started
    print_output("release.v105 #{step.id}", output)
    status = release_step_status("release.v105", step.id, exit_status, output)

    TestMetrics.record(%{
      gate: "release.v105",
      command: gate_command(),
      cwd: Path.relative_to(cwd, root()),
      phase_or_step: step.id,
      status: status,
      wall_ms: duration_ms,
      output: output
    })

    %{
      id: step.id,
      title: step.title,
      status: status,
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

  defp release_v059_portability_artifacts(home, evidence_dir, env) do
    envelope_path = Path.join(evidence_dir, "release-v059-home.envelope.json")
    diagnostic_path = Path.join(evidence_dir, "release-v059-dry-run-diagnostic.json")
    target_home = Path.join(Path.dirname(home), "release-v059-dry-run-target-home")
    File.mkdir_p!(target_home)

    {export_output, export_status} =
      System.cmd("mix", ["allbert.home.export", "--out", envelope_path],
        cd: app_cwd(:core),
        env: env,
        stderr_to_stdout: true
      )

    print_output("release.v059 portability_artifacts export", export_output)

    import_env =
      env
      |> put_env_value("ALLBERT_HOME", target_home)
      |> put_env_value("ALLBERT_HOME_DIR", target_home)

    {import_output, import_status} =
      if export_status == 0 do
        System.cmd(
          "mix",
          [
            "allbert.home.import",
            "--dry-run",
            "--in",
            envelope_path,
            "--evidence-out",
            diagnostic_path
          ],
          cd: app_cwd(:core),
          env: import_env,
          stderr_to_stdout: true
        )
      else
        {"skipped dry-run import because export failed\n", 1}
      end

    print_output("release.v059 portability_artifacts dry_run", import_output)

    artifact_paths =
      [envelope_path, diagnostic_path]
      |> Enum.filter(&File.regular?/1)

    %{
      status:
        if(export_status == 0 and import_status == 0 and length(artifact_paths) == 2,
          do: "passed",
          else: "failed"
        ),
      export_exit_status: export_status,
      dry_run_exit_status: import_status,
      target_home: target_home,
      required_paths: [envelope_path, diagnostic_path],
      artifacts:
        Enum.map(artifact_paths, fn path ->
          %{
            kind: artifact_kind(path),
            path: Path.relative_to(path, home),
            bytes: File.stat!(path).size,
            sha256: path |> File.read!() |> sha256()
          }
        end),
      export_output_sha256: sha256(export_output),
      dry_run_output_sha256: sha256(import_output),
      redacted_export_output_tail: export_output |> redact_release_output() |> tail(4_000),
      redacted_dry_run_output_tail: import_output |> redact_release_output() |> tail(4_000)
    }
  end

  defp put_env_value(env, key, value) do
    env
    |> Enum.reject(fn {existing_key, _value} -> existing_key == key end)
    |> Kernel.++([{key, value}])
  end

  defp artifact_kind(path) do
    cond do
      String.ends_with?(path, ".envelope.json") -> "export_envelope"
      String.ends_with?(path, "diagnostic.json") -> "dry_run_diagnostic"
      true -> "release_artifact"
    end
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

  defp release_channel_pack_secret_scan(home, label, opts \\ []) do
    required_paths =
      opts
      |> Keyword.get(:required_paths, [])
      |> Enum.map(&Path.expand/1)

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
        Path.join(home, "cache/browser"),
        Path.join(home, "release_evidence")
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
        Path.join(home, "cache/browser"),
        Path.join(home, "release_evidence")
      ]
      |> Enum.filter(&File.exists?/1)

    files =
      roots
      |> Enum.flat_map(&Path.wildcard(Path.join(&1, "**/*")))
      |> Enum.filter(&File.regular?/1)

    findings = release_v042_secret_findings(files, home)
    expanded_files = Enum.map(files, &Path.expand/1)
    missing_required_paths = Enum.reject(required_paths, &(&1 in expanded_files))

    result = %{
      status: if(findings == [] and missing_required_paths == [], do: "passed", else: "failed"),
      scanned_roots: Enum.map(roots, &Path.relative_to(&1, home)),
      scanned_file_count: length(files),
      secret_pattern_names: Enum.map(secret_patterns(), fn {name, _pattern} -> name end),
      required_scanned_files:
        required_paths
        |> Enum.reject(&(&1 in missing_required_paths))
        |> Enum.map(&Path.relative_to(&1, home)),
      missing_required_files: Enum.map(missing_required_paths, &Path.relative_to(&1, home)),
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
      {"google_api_key", ~r/\bAIza[0-9A-Za-z_-]{20,}\b/},
      {"github_like_token", ~r/\bgh[pousr]_[A-Za-z0-9_]{20,}\b/},
      {"slack_like_token", ~r/\bxox[baprs]-[A-Za-z0-9-]{20,}\b/},
      {"aws_access_key", ~r/\bAKIA[0-9A-Z]{16}\b/},
      {"aws_session_key", ~r/\bASIA[0-9A-Z]{16}\b/},
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
         gate: gate,
         owner: owner,
         env: env,
         lane: lane,
         partitions: partitions,
         partition: partition,
         test_paths: test_paths
       }) do
    env = [{"MIX_TEST_PARTITION", to_string(partition)} | env]
    validate_serial_lane_paths!(owner, test_paths)
    started = System.monotonic_time(:millisecond)

    output =
      if test_paths == [] do
        {:ok, label, empty_partition_message(lane)}
      else
        run_serial_partition_cmd(label, owner, lane, env, test_paths)
      end

    record_serial_partition_metrics(gate, owner, lane, partition, partitions, started, output)
    cleanup_owned_env(env)
    output
  end

  # M8.8: partitions receive PACKED explicit file lists (PartitionPacker),
  # so ExUnit's hash split (`--partitions`) is no longer passed — each VM
  # runs exactly its assigned files. MIX_TEST_PARTITION stays exported for
  # the per-partition owned-env naming contract.
  defp run_serial_partition_cmd(label, owner, lane, env, test_paths) do
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
               "--only",
               Atom.to_string(lane),
               "--max-cases",
               "1",
               "--slowest",
               "25"
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
  end

  # M8.8: cost-balanced explicit partition lists. Measured per-file costs
  # come from the metrics store; unmeasured files are estimated from their
  # test counts (PartitionPacker doc). The same lane files always run —
  # only their partition assignment moves off ExUnit's name hash, which the
  # store measured at 4.4x imbalance on db_serial (39.6/174.7/165.1/52.0 s).
  # M8.9: a lane's list includes every file carrying that lane's tag at ANY
  # level (module/describe/test), not just primary-lane files — `--only`
  # still filters inside the VM, so each test runs exactly once per lane.
  # This provably restores the pre-M8.8 whole-dir `--only` selection; the
  # onboarding_test describetag block is the proven counterexample to
  # primary-lane-only lists. Cost lookups are owner-qualified (M8.9): two
  # owners can share an output-relative path, so the packer prefers the
  # "owner:path" cost key and falls back to the bare path for legacy records.
  @doc false
  def packed_lane_paths(owner, lane, partitions) do
    files = lane_packing_files(inventory_records(), owner, lane)
    PartitionPacker.pack(files, partitions, TestMetrics.file_costs())
  end

  @doc false
  def lane_packing_files(records, owner, lane) do
    lane_tag = ":#{lane}"

    records
    |> Enum.filter(fn record ->
      record.owner == owner and
        (record.primary_lane == lane or String.contains?(record.tags, lane_tag))
    end)
    |> Enum.map(
      &%{path: relative_test_path(&1.path, owner), test_count: &1.test_count, owner: owner}
    )
  end

  # v1.0.2 M8.1: one metrics record per lane partition VM run; recording is
  # best-effort inside TestMetrics.record/1 and can never fail the gate.
  # M8.9: the record carries the owner so file_costs can emit owner-qualified
  # cost keys (two owners can share an output-relative path).
  defp record_serial_partition_metrics(gate, owner, lane, partition, partitions, started, result) do
    {status, output} =
      case result do
        {:ok, _label, output} -> {"passed", output}
        {:error, _label, _exit_status, output} -> {"failed", output}
      end

    TestMetrics.record(%{
      gate: gate,
      command: gate_command(),
      cwd: Path.relative_to(app_cwd(owner), root()),
      phase_or_step: "serial-#{lane}",
      owner: Atom.to_string(owner),
      lane: Atom.to_string(lane),
      partition: partition,
      partitions: partitions,
      status: status,
      wall_ms: System.monotonic_time(:millisecond) - started,
      output: output
    })
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

  @doc false
  def inventory_records do
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
      test_count: length(Regex.scan(~r/^\s*(?:test|property)\s/m, text)),
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

  # M8.9: @describetag included — its omission is how a describe-level lane
  # tag escaped every inventory check and let packed primary-lane lists drop
  # 3 tests (the 590→587 delta, root-caused in the plan).
  defp tags(text) do
    ~r/@(?:module|describe)?tag\s+([^\n]+)/
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

  # v1.0.2 M1: the text-scan heuristic misclassifies two directions —
  # false NEGATIVES on real egress that happens inside production modules the
  # scan cannot see (env-gated smokes; Coding.Bash → Execution.LocalRunner
  # System.cmd), and false POSITIVES on inert string literals ("bridge" in
  # Playwright error messages; "MCP" in intent-corpus utterances). Two recorded
  # corrections: a path rule (everything under test/external/ is the real-egress
  # smoke lane by house convention), and an explicit per-file adjudication map —
  # each entry carries the audit reason and wins over the text scan.
  @lane_adjudications %{
    # Real OS subprocess via production LocalRunner (System.cmd in lib/, not in
    # the test text): stays in the external policy lane.
    "apps/allbert_assist/test/allbert_assist/coding/m3_bash_action_test.exs" =>
      :external_runtime_serial,
    # v1.0.3 M3 permanent minimal-composition regression: the channel-surface
    # heuristic reads it as external, but it touches no real channel runtime —
    # it plants a settings-root residue and reads a PRIVATE registry through
    # the action context. Repo-backed via DataCase: db_serial is the audited
    # class.
    "apps/allbert_assist/test/allbert_assist/actions/channels/list_channels_context_test.exs" =>
      :db_serial,
    # "bridge" appears only in Playwright error-string literals; drivers are
    # put_env fakes. Audited resource class is the owned-home filesystem.
    # v1.0.3 M1 (ADR 0086 contract 4): stays home_fs_serial by RECORDED
    # decision — pid-qualified pre-cleaned root landed, but the ADR 0031
    # driver app-env read and the named AllbertBrowser singletons keep it in
    # the class (seam gaps recorded in the file header).
    "apps/allbert_assist/test/allbert_assist/actions/browser_actions_test.exs" => :home_fs_serial,
    # v1.0.3 M1 pilot (ADR 0086 contract 1): objective_test converted to
    # per-test non-shared sandbox ownership with explicit engine-agent
    # allowances (use-line `lane: :db_partition_safe`). Repo-backed: the text
    # scan's :db class is correct, but the audited lane is the partitioned
    # db_partition_safe lane, never pure_async.
    "apps/allbert_assist/test/allbert_assist/objectives/objective_test.exs" => :db_partition_safe,
    # v1.0.3 M1 pilot (ADR 0086 contract 2): gate_test reads Settings floors
    # through the process-scoped ConfigContext inside bounded with_context
    # calls and resolves descriptors from a PRIVATE shipped-baseline registry
    # pair. The text scan's app_env/home_fs/global_process hits are comment
    # references and owned tmp roots; audited resource ownership is complete.
    "apps/allbert_assist/test/allbert_assist/intent/eval/gate_test.exs" => :pure_async,
    # v1.0.3 M1 pilot (ADR 0086 contract 3): app_actions_test registers only
    # into supervised private registry pairs (unique names + ETS tables,
    # side_effects: false) and reads through the Runner `:registry` context;
    # the "Registry"/"Supervisor" text hits are the private fixtures. The
    # log-assertion test uses a module-scoped Logger level override
    # (put_module_level, deleted on_exit) — no VM-wide primary-level mutation.
    "apps/allbert_assist/test/allbert_assist/actions/app_actions_test.exs" => :pure_async,
    # "MCP" appears only inside intent-corpus utterance data; the file's real
    # resource class is the global action/plugin registry.
    "apps/allbert_assist/test/allbert_assist/intent/eval/corpus_completeness_test.exs" =>
      :global_process_serial,
    "apps/allbert_assist/test/allbert_assist/intent/golden_set_test.exs" =>
      :global_process_serial,
    # ADR 0082 proof suite: file writes are scoped to owned, uniquely-named
    # fixture subdirectories of the per-run test home (partition-keyed, rm_rf
    # bounded to the owned root) and its registries are start_supervised!
    # privates with unique names/ETS tables — no shared home state is mutated.
    "apps/allbert_assist/test/allbert_assist/registry_context_test.exs" => :pure_async,
    # v1.0.2 M4 split remainder: every test drops the fixture agent_runner and
    # drives the LIVE default Runtime singleton (real agent runtime + the
    # provider/tool supervision it owns) — a shared runtime resource the
    # liveview_serial partition runner does not own. Adjudicated explicitly so
    # the classification never depends on incidental comment text.
    "apps/allbert_assist_web/test/allbert_assist_web/live/workspace_live_test.exs" =>
      :external_runtime_serial
  }

  defp primary_lane(path, async, template, classes) do
    adjudicated_lane(path) ||
      external_smoke_path_lane(path) ||
      resource_lane(classes) ||
      template_lane(template) ||
      async_lane(async) ||
      :global_process_serial
  end

  defp adjudicated_lane(path) do
    Enum.find_value(@lane_adjudications, fn {adjudicated_path, lane} ->
      if String.ends_with?(to_string(path), adjudicated_path), do: lane
    end)
  end

  defp external_smoke_path_lane(path) do
    if to_string(path) =~ ~r{/test/external/}, do: :external_runtime_serial
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
  # v1.0.3 M1: converted files (ADR 0086 contract 1) own per-test sandbox
  # checkout + allowances; they run in the packed db_partition_safe lane.
  defp migration_action(:db_partition_safe, _async), do: "partition_database_owned"

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

  # v1.0.2 M8.3 item 2: per-owner core-p6 tuning was applied, measured on the
  # final tree (quick 464s/1,797, high 947s/2,119, prepush 965s/2,119 — all
  # green), and REVERTED: M8.2's solo-lane p6 gains (db 191.3->148.4s,
  # app_env 155.2->115.3s) did not replicate in-gate (db p6 max-partition wall
  # 188.1s vs p4 185.9s; app_env 160.4s vs 152.7s; home_fs 38.7s vs 29.1s) and
  # the gate walls stayed neutral, so the uniform p4 default stands.
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

  # M8.10: the gate subcommand + args captured in run/1; nil outside a
  # `mix allbert.test` invocation (such records read as LEGACY provenance).
  defp gate_command do
    :persistent_term.get({__MODULE__, :invocation}, nil)
  end

  @spec usage!() :: no_return()
  defp usage! do
    Mix.raise("""
    Usage:
      mix allbert.test docs
      mix allbert.test inventory [--output PATH] [--check-tags] [--manifest] [--check-manifest]
      mix allbert.test focused -- FILE [FILE...]
      mix allbert.test commit
      mix allbert.test prepush [--partitions N]
      mix allbert.test fast-local [--core-lanes] [--stocksage-lanes] [--web-lanes] [--partitions N]
      mix allbert.test partition-smoke [--partitions N]
      mix allbert.test serial-core --lane LANE [--partitions N]
      mix allbert.test param-contract-sweep
      mix allbert.test metrics [--ingest-campaign DIR]
      mix allbert.test bench-decide
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
      mix allbert.test release.v060
      mix allbert.test release.v060b
      mix allbert.test release.v061
      mix allbert.test release.v061b
      mix allbert.test release.v062
      mix allbert.test release.v063
      mix allbert.test release.v064
      mix allbert.test release.v065
      mix allbert.test release.v066
      mix allbert.test release.v1
      mix allbert.test release.v101
      mix allbert.test release.v102
      mix allbert.test release.v103
      mix allbert.test release.v104
      mix allbert.test release.v105
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
