defmodule AllbertAssist.Sandbox.Image do
  @moduledoc """
  Local image preparation and verification for the v0.36 Elixir/OTP sandbox.

  Image preparation is an explicit operator setup step. Sandbox command and
  gate execution still use local image inspection and `--pull=never`.
  """

  alias AllbertAssist.Paths
  alias AllbertAssist.Runtime.Redactor
  alias AllbertAssist.Sandbox.Backends.Command
  alias AllbertAssist.Sandbox.Policy

  @kind "elixir_otp"
  @type report :: %{
          status: :completed | :failed | :unavailable,
          operation: :image_build | :image_verify,
          image: String.t(),
          command: map() | nil,
          exit_status: non_neg_integer() | nil,
          stdout: String.t(),
          diagnostics: [map()],
          report_path: String.t() | nil,
          metadata: map()
        }

  @spec build(keyword()) :: {:ok, report()} | {:error, report()}
  def build(opts \\ []) do
    policy = Keyword.get(opts, :policy) || Policy.load!()
    image = Keyword.get(opts, :image, policy.image)
    base_image = Keyword.get(opts, :base_image, default_base_image())
    project_root = Keyword.get(opts, :project_root, File.cwd!())
    labels = labels(project_root)

    with {:ok, docker} <- docker_executable(opts),
         {:ok, context} <- build_context(base_image, opts) do
      argv = build_argv(image, base_image, context, labels, opts)

      docker
      |> run(argv, policy, opts)
      |> build_report(:image_build, image, docker, argv, labels, %{base_image: base_image})
      |> write_and_return()
      |> tap(fn _result -> cleanup_context(context, opts) end)
    else
      {:error, reason} ->
        :image_build
        |> base_report(image, reason)
        |> write_and_return()
    end
  end

  @spec verify(keyword()) :: {:ok, report()} | {:error, report()}
  def verify(opts \\ []) do
    policy = Keyword.get(opts, :policy) || Policy.load!()
    image = Keyword.get(opts, :image, policy.image)
    project_root = Keyword.get(opts, :project_root, File.cwd!())

    with {:ok, docker} <- docker_executable(opts),
         {:ok, metadata} <-
           local_status(policy, docker, Keyword.put(opts, :project_root, project_root)) do
      argv = verify_run_argv(image)

      docker
      |> run(argv, policy, opts)
      |> verify_report(:image_verify, image, docker, argv, metadata)
      |> write_and_return()
    else
      {:error, reason} ->
        :image_verify
        |> base_report(image, reason)
        |> write_and_return()
    end
  end

  @spec local_status(Policy.t(), String.t(), keyword()) :: {:ok, map()} | {:error, term()}
  def local_status(%Policy{} = policy, docker, opts \\ []) when is_binary(docker) do
    project_root = Keyword.get(opts, :project_root, File.cwd!())

    case run(docker, inspect_argv(policy.image), policy, opts) do
      {:ok, %{exit_status: 0, output: output}} ->
        with {:ok, labels} <- decode_labels(output),
             :ok <- validate_labels(labels, project_root) do
          {:ok, %{labels: labels, image: policy.image}}
        end

      {:ok, result} ->
        {:error,
         {:image_missing, policy.image,
          %{hint: "mix allbert.sandbox image build", output: Map.get(result, :output, "")}}}

      {:error, reason} ->
        {:error, {:image_inspect_failed, reason}}
    end
  end

  @spec labels(String.t()) :: %{String.t() => String.t()}
  def labels(project_root \\ File.cwd!()) do
    %{
      "allbert.sandbox.kind" => @kind,
      "allbert.sandbox.version" => allbert_version(),
      "allbert.sandbox.elixir" => System.version(),
      "allbert.sandbox.otp" => otp_release(),
      "allbert.sandbox.lock_sha256" => lock_sha256(project_root),
      "org.opencontainers.image.title" => "Allbert Elixir/OTP Sandbox"
    }
  end

  @spec build_argv(String.t(), String.t(), String.t(), map(), keyword()) :: [String.t()]
  def build_argv(image, base_image, context, labels, opts \\ []) do
    pull_args = if Keyword.get(opts, :pull_base?, true), do: ["--pull"], else: []

    ["build"] ++
      pull_args ++
      ["--file", Path.join(context, "Dockerfile"), "--tag", image] ++
      label_args(labels) ++
      ["--build-arg", "BASE_IMAGE=#{base_image}", context]
  end

  @spec verify_run_argv(String.t()) :: [String.t()]
  def verify_run_argv(image) do
    [
      "run",
      "--rm",
      "--pull=never",
      "--network",
      "none",
      "--read-only",
      "--cap-drop",
      "ALL",
      "--security-opt",
      "no-new-privileges",
      image,
      "elixir",
      "--version"
    ]
  end

  defp inspect_argv(image), do: ["image", "inspect", image, "--format", "{{json .Config.Labels}}"]

  defp docker_executable(opts) do
    case Keyword.get(opts, :docker) || System.find_executable("docker") do
      nil -> {:error, {:missing_executable, "docker"}}
      docker -> {:ok, docker}
    end
  end

  defp build_context(base_image, opts) do
    project_root = Keyword.get(opts, :project_root, File.cwd!())

    root =
      Keyword.get(opts, :context_root) ||
        Path.join(Paths.sandbox_cache_root(), "image-build-#{System.unique_integer([:positive])}")

    File.mkdir_p!(root)
    copy_dependency_context!(project_root, Path.join(root, "project"))

    dockerfile = """
    ARG BASE_IMAGE=#{base_image}
    FROM ${BASE_IMAGE}

    ENV MIX_ENV=test \\
        MIX_DEPS_PATH=/opt/allbert/deps \\
        MIX_BUILD_PATH=/opt/allbert/_build \\
        MIX_HOME=/opt/allbert/mix \\
        HEX_HOME=/opt/allbert/hex \\
        REBAR_CACHE_DIR=/opt/allbert/rebar

    RUN mkdir -p /opt/allbert/deps /opt/allbert/_build /opt/allbert/mix /opt/allbert/hex /opt/allbert/rebar
    WORKDIR /opt/allbert/project
    COPY project/ ./
    RUN mix deps.get --only test || (mix local.hex --force && mix local.rebar --force && mix deps.get --only test)
    RUN mix deps.compile
    WORKDIR /workspace/project
    """

    File.write!(Path.join(root, "Dockerfile"), dockerfile)
    {:ok, root}
  rescue
    exception ->
      {:error, {:context_write_failed, exception.__struct__, Exception.message(exception)}}
  end

  defp copy_dependency_context!(project_root, target_root) do
    File.rm_rf!(target_root)
    File.mkdir_p!(target_root)

    project_root
    |> dependency_manifest_paths()
    |> Enum.each(fn source ->
      relative = Path.relative_to(source, project_root)
      target = Path.join(target_root, relative)
      File.mkdir_p!(Path.dirname(target))
      File.cp!(source, target)
    end)
  end

  defp dependency_manifest_paths(project_root) do
    ([
       Path.join(project_root, "mix.exs"),
       Path.join(project_root, "mix.lock")
     ] ++
       Path.wildcard(Path.join([project_root, "apps", "*", "mix.exs"])) ++
       Path.wildcard(Path.join([project_root, "config", "*.exs"])))
    |> Enum.filter(&File.regular?/1)
    |> Enum.uniq()
  end

  defp cleanup_context(context, opts) do
    if Keyword.get(opts, :cleanup_context?, true), do: File.rm_rf(context)
  end

  defp run(executable, argv, policy, opts) do
    runner = Keyword.get(opts, :command_runner, &Command.run/3)

    runner.(executable, argv,
      timeout_ms: Keyword.get(opts, :timeout_ms, policy.timeout_ms),
      max_output_bytes: Keyword.get(opts, :max_output_bytes, policy.output_bytes)
    )
  end

  defp build_report(result, operation, image, docker, argv, labels, metadata) do
    report_from_result(
      result,
      operation,
      image,
      docker,
      argv,
      Map.merge(metadata, %{labels: labels})
    )
  end

  defp verify_report(result, operation, image, docker, argv, metadata) do
    report_from_result(result, operation, image, docker, argv, metadata)
  end

  defp report_from_result(
         {:ok, %{exit_status: 0} = result},
         operation,
         image,
         docker,
         argv,
         metadata
       ) do
    %{
      status: :completed,
      operation: operation,
      image: image,
      command: command_summary(docker, argv),
      exit_status: 0,
      stdout: Map.get(result, :output, ""),
      diagnostics: [],
      report_path: nil,
      metadata: metadata
    }
  end

  defp report_from_result({:ok, result}, operation, image, docker, argv, metadata) do
    %{
      status: :failed,
      operation: operation,
      image: image,
      command: command_summary(docker, argv),
      exit_status: Map.get(result, :exit_status),
      stdout: Map.get(result, :output, ""),
      diagnostics: [%{reason: :docker_command_failed}],
      report_path: nil,
      metadata: metadata
    }
  end

  defp report_from_result({:error, reason}, operation, image, docker, argv, metadata) do
    %{
      status: :failed,
      operation: operation,
      image: image,
      command: command_summary(docker, argv),
      exit_status: nil,
      stdout: "",
      diagnostics: [%{reason: reason}],
      report_path: nil,
      metadata: metadata
    }
  end

  defp base_report(operation, image, reason) do
    %{
      status: :unavailable,
      operation: operation,
      image: image,
      command: nil,
      exit_status: nil,
      stdout: "",
      diagnostics: [%{reason: reason}],
      report_path: nil,
      metadata: %{}
    }
  end

  defp write_and_return(report) do
    report = write_report!(report)

    if report.status == :completed, do: {:ok, report}, else: {:error, report}
  end

  defp write_report!(report) do
    File.mkdir_p!(Paths.sandbox_reports_root())

    path =
      Path.join(
        Paths.sandbox_reports_root(),
        "#{report.operation}-#{System.unique_integer([:positive])}.json"
      )

    report = %{report | report_path: path}

    body =
      report
      |> redact_paths()
      |> Redactor.redact(:sandbox_trial)
      |> Jason.encode!(pretty: true)

    File.write!(path, body)
    report
  end

  defp redact_paths(value) when is_map(value) do
    value
    |> Enum.map(fn {key, val} -> {key, redact_paths(val)} end)
    |> Map.new()
  end

  defp redact_paths(value) when is_list(value), do: Enum.map(value, &redact_paths/1)

  defp redact_paths(value) when is_binary(value) do
    String.replace(value, Paths.home(), "<ALLBERT_HOME>")
  end

  defp redact_paths(value), do: value

  defp decode_labels(output) do
    case Jason.decode(String.trim(output)) do
      {:ok, labels} when is_map(labels) -> {:ok, labels}
      {:ok, _other} -> {:error, :image_labels_missing}
      {:error, _reason} -> {:error, :image_labels_invalid}
    end
  end

  defp validate_labels(labels, project_root) do
    expected = labels(project_root)

    missing_or_mismatched =
      expected
      |> Enum.reject(fn {key, value} -> Map.get(labels, key) == value end)
      |> Enum.map(fn {key, value} ->
        %{label: key, expected: value, actual: Map.get(labels, key)}
      end)

    if missing_or_mismatched == [] do
      :ok
    else
      {:error,
       {:image_labels_invalid,
        %{hint: "mix allbert.sandbox image build", labels: missing_or_mismatched}}}
    end
  end

  defp label_args(labels) do
    labels
    |> Enum.sort()
    |> Enum.flat_map(fn {key, value} -> ["--label", "#{key}=#{value}"] end)
  end

  defp command_summary(docker, argv) do
    %{
      executable: docker,
      argv: argv,
      pull_policy: if("--pull=never" in argv or "--pull" in argv, do: "explicit", else: "default")
    }
  end

  defp default_base_image do
    "elixir:#{System.version()}-otp-#{otp_release()}-slim"
  end

  defp allbert_version do
    case Application.spec(:allbert_assist, :vsn) do
      nil -> "0.36.0"
      version -> to_string(version)
    end
  end

  defp otp_release do
    :erlang.system_info(:otp_release) |> to_string()
  end

  defp lock_sha256(project_root) do
    lock_path = Path.join(project_root, "mix.lock")

    if File.regular?(lock_path) do
      :crypto.hash(:sha256, File.read!(lock_path)) |> Base.encode16(case: :lower)
    else
      "missing"
    end
  end
end
