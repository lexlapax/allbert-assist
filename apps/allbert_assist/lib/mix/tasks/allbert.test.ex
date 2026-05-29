defmodule Mix.Tasks.Allbert.Test do
  @moduledoc """
  Run Allbert's developer-facing v0.41 test gates.

  ## Usage

      mix allbert.test docs
      mix allbert.test inventory [--output PATH]
      mix allbert.test focused -- FILE [FILE...]
      mix allbert.test fast-local
      mix allbert.test partition-smoke [--partitions N]
      mix allbert.test serial-core --lane LANE [--partitions N]
      mix allbert.test release
      mix allbert.test external-smoke list
      mix allbert.test external-smoke -- docker_sandbox
      mix allbert.test external-smoke -- docker_full_gate
  """

  use Mix.Task

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
  def run(["fast-local" | rest]), do: fast_local(rest)
  def run(["partition-smoke" | rest]), do: partition_smoke(rest)
  def run(["serial-core" | rest]), do: serial_core(rest)
  def run(["release"]), do: release()
  def run(["external-smoke" | rest]), do: external_smoke(rest)
  def run(_args), do: usage!()

  defp docs do
    run_cmd!("docs", root(), "git", ["diff", "--check"], [])
  end

  defp inventory(args) do
    {opts, rest, invalid} = OptionParser.parse(args, strict: [output: :string])

    reject_invalid!(invalid)
    reject_rest!(rest)

    csv = inventory_csv()

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

  defp fast_local(args) do
    reject_rest!(args)

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

    1..partitions
    |> Enum.map(fn partition ->
      %{
        label: "serial-core #{lane} p#{partition}/#{partitions}",
        partition: partition,
        partitions: partitions,
        lane: lane,
        env: owned_env("serial-core-#{lane}", partition)
      }
    end)
    |> Task.async_stream(&run_serial_core_partition/1,
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
    run_cmd!("release precommit", root(), "mix", ["precommit"], owned_env("release-precommit", 0))
    run_cmd!("release dialyzer", root(), "mix", ["dialyzer"], owned_env("release-dialyzer", 0))
  end

  defp external_smoke(args) do
    args
    |> reject_separator()
    |> run_external_smoke()
  end

  defp run_external_smoke(["list"]) do
    Mix.shell().info("external smokes are opt-in and remain serial:")
    Mix.shell().info("- docker_sandbox")
    Mix.shell().info("- docker_full_gate")
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

  defp run_serial_core_partition(%{
         label: label,
         env: env,
         lane: lane,
         partitions: partitions,
         partition: partition
       }) do
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
               ],
               cd: app_cwd(:core),
               env: env,
               stderr_to_stdout: true
             ) do
        if status == 0 do
          {:ok, label, migrate_output <> test_output}
        else
          {:error, label, status, migrate_output <> test_output}
        end
      else
        {output, status} -> {:error, label, status, output}
      end

    cleanup_owned_env(env)
    output
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
    Enum.filter(inventory_records(), &(&1.async == "true"))
  end

  defp inventory_csv do
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
      inventory_records()
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

  defp template_and_async(text) do
    case Regex.run(~r/use\s+([A-Za-z0-9_.]+)\s*,\s*async:\s*(true|false)/, text) do
      [_, template, async] ->
        {template, async}

      nil ->
        case Regex.run(~r/use\s+([A-Za-z0-9_.]+)/, text) do
          [_, template] -> {template, "unspecified"}
          nil -> {"unknown", "unspecified"}
        end
    end
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
      true -> :unknown
    end
  end

  defp app_cwd(owner) when owner in [:core, :stocksage, :telegram, :email] do
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
        "allbert_v041_test_gates",
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
      mix allbert.test inventory [--output PATH]
      mix allbert.test focused -- FILE [FILE...]
      mix allbert.test fast-local
      mix allbert.test partition-smoke [--partitions N]
      mix allbert.test serial-core --lane LANE [--partitions N]
      mix allbert.test release
      mix allbert.test external-smoke list
      mix allbert.test external-smoke -- docker_sandbox
      mix allbert.test external-smoke -- docker_full_gate
    """)
  end
end
