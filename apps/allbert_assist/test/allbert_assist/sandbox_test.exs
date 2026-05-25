defmodule AllbertAssist.SandboxTest do
  use ExUnit.Case, async: false

  alias AllbertAssist.Paths
  alias AllbertAssist.Sandbox
  alias AllbertAssist.Sandbox.Backend.Registry
  alias AllbertAssist.Sandbox.Backend.Resolver
  alias AllbertAssist.Sandbox.Backends.ContainerRunner
  alias AllbertAssist.Sandbox.Backends.Docker
  alias AllbertAssist.Sandbox.Backends.DockerRunsc
  alias AllbertAssist.Sandbox.Backends.PodmanRootless
  alias AllbertAssist.Sandbox.Bundle
  alias AllbertAssist.Sandbox.CommandSpec
  alias AllbertAssist.Sandbox.Host
  alias AllbertAssist.Sandbox.Policy
  alias AllbertAssist.Sandbox.Report
  alias AllbertAssist.Sandbox.ReportWriter
  alias AllbertAssist.Sandbox.SourcePolicy
  alias AllbertAssist.Settings

  defmodule AvailableDocker do
    @behaviour AllbertAssist.Sandbox.Backend

    def id, do: :docker
    def platforms, do: [:linux, :macos]
    def available?(_policy), do: true
    def doctor(_policy), do: %{id: id(), status: :available, reason: :doctor_green}
    def run(_bundle, _command), do: {:error, :not_used}
    def cleanup(_bundle), do: :ok
  end

  defmodule AvailableRunsc do
    @behaviour AllbertAssist.Sandbox.Backend

    def id, do: :docker_runsc
    def platforms, do: [:linux, :macos]
    def available?(_policy), do: true
    def doctor(_policy), do: %{id: id(), status: :available, reason: :doctor_green}
    def run(_bundle, _command), do: {:error, :not_used}
    def cleanup(_bundle), do: :ok
  end

  defmodule UnavailablePodman do
    @behaviour AllbertAssist.Sandbox.Backend

    def id, do: :podman_rootless
    def platforms, do: [:linux]
    def available?(_policy), do: false
    def doctor(_policy), do: %{id: id(), status: :unavailable, reason: :podman_missing}
    def run(_bundle, _command), do: {:error, :not_used}
    def cleanup(_bundle), do: :ok
  end

  defmodule AvailablePodman do
    @behaviour AllbertAssist.Sandbox.Backend

    def id, do: :podman_rootless
    def platforms, do: [:linux]
    def available?(_policy), do: true
    def doctor(_policy), do: %{id: id(), status: :available, reason: :doctor_green}
    def run(_bundle, _command), do: {:error, :not_used}
    def cleanup(_bundle), do: :ok
  end

  defmodule AvailableApple do
    @behaviour AllbertAssist.Sandbox.Backend

    def id, do: :apple_container
    def platforms, do: [:macos]
    def available?(_policy), do: true
    def doctor(_policy), do: %{id: id(), status: :available, reason: :doctor_green}
    def run(_bundle, _command), do: {:error, :not_used}
    def cleanup(_bundle), do: :ok
  end

  defmodule ExplodingBackend do
    @behaviour AllbertAssist.Sandbox.Backend

    def id, do: :docker
    def platforms, do: [:linux]
    def available?(_policy), do: raise("should not run")
    def doctor(_policy), do: raise("should not run")
    def run(_bundle, _command), do: {:error, :not_used}
    def cleanup(_bundle), do: :ok
  end

  defmodule CompletingDocker do
    @behaviour AllbertAssist.Sandbox.Backend

    alias AllbertAssist.Sandbox.CommandSpec
    alias AllbertAssist.Sandbox.Report
    alias AllbertAssist.Sandbox.ReportWriter

    def id, do: :docker
    def platforms, do: [:linux, :macos]
    def available?(_policy), do: true
    def doctor(_policy), do: %{id: id(), status: :available, reason: :doctor_green}

    def run(bundle, command) do
      ReportWriter.write(bundle, %Report{
        status: :completed,
        backend: id(),
        command: CommandSpec.summary(command),
        metadata: %{fixture_backend?: true}
      })
    end

    def cleanup(_bundle), do: :ok
  end

  defmodule FailingDocker do
    @behaviour AllbertAssist.Sandbox.Backend

    alias AllbertAssist.Sandbox.CommandSpec
    alias AllbertAssist.Sandbox.Report
    alias AllbertAssist.Sandbox.ReportWriter

    def id, do: :docker
    def platforms, do: [:linux, :macos]
    def available?(_policy), do: true
    def doctor(_policy), do: %{id: id(), status: :available, reason: :doctor_green}

    def run(bundle, command) do
      ReportWriter.write(bundle, %Report{
        status: :failed,
        backend: id(),
        command: CommandSpec.summary(command),
        exit_status: 1,
        diagnostics: [%{reason: :fixture_failure}]
      })
    end

    def cleanup(_bundle), do: :ok
  end

  setup do
    original_paths_config = Application.get_env(:allbert_assist, Paths)
    original_settings_config = Application.get_env(:allbert_assist, Settings)
    home = temp_path("home")

    Application.put_env(:allbert_assist, Paths, home: home)
    Application.delete_env(:allbert_assist, Settings)

    on_exit(fn ->
      restore_app_env(Paths, original_paths_config)
      restore_app_env(Settings, original_settings_config)
      File.rm_rf!(home)
    end)

    {:ok, home: home}
  end

  test "backend registry exposes the v0.36 backend ids" do
    assert Registry.ids() == [:apple_container, :podman_rootless, :docker_runsc, :docker]
    assert {:ok, AllbertAssist.Sandbox.Backends.Docker} = Registry.module_for(:docker)
    assert {:ok, AllbertAssist.Sandbox.Backends.DockerRunsc} = Registry.module_for("docker_runsc")
    assert {:error, {:unknown_backend, :firecracker}} = Registry.module_for(:firecracker)
  end

  test "auto resolver prefers rootless podman on Linux when available" do
    host = %Host{os: :linux, arch: :x86_64}
    policy = policy("auto", host)

    result =
      Resolver.resolve(policy,
        host: host,
        backends: [AvailablePodman, AvailableRunsc, AvailableDocker]
      )

    assert result.resolved_backend == :podman_rootless
    assert Enum.map(result.candidates, & &1.id) == [:podman_rootless, :docker_runsc, :docker]
  end

  test "auto resolver falls through to docker_runsc before docker" do
    host = %Host{os: :linux, arch: :x86_64}
    policy = policy("auto", host)

    result =
      Resolver.resolve(policy,
        host: host,
        backends: [UnavailablePodman, AvailableRunsc, AvailableDocker]
      )

    assert result.resolved_backend == :docker_runsc
    assert Enum.map(result.candidates, & &1.status) == [:unavailable, :available, :available]
  end

  test "auto resolver selects Apple container first only on capable macOS hosts" do
    capable = %Host{os: :macos, arch: :arm64, macos_version: {26, 0, 0}}
    older = %Host{os: :macos, arch: :arm64, macos_version: {15, 5, 0}}

    capable_result =
      Resolver.resolve(policy("auto", capable),
        host: capable,
        backends: [AvailableApple, AvailableRunsc, AvailableDocker]
      )

    older_result =
      Resolver.resolve(policy("auto", older),
        host: older,
        backends: [AvailableApple, AvailableRunsc, AvailableDocker]
      )

    assert capable_result.resolved_backend == :apple_container

    assert Enum.map(capable_result.candidates, & &1.id) == [
             :apple_container,
             :docker_runsc,
             :docker
           ]

    assert older_result.resolved_backend == :docker_runsc
    assert Enum.map(older_result.candidates, & &1.id) == [:docker_runsc, :docker]
  end

  test "pinned unknown backend fails closed" do
    host = %Host{os: :linux, arch: :x86_64}

    result = Resolver.resolve(policy("firecracker", host), host: host, backends: [])

    assert result.resolved_backend == nil

    assert [%{id: :firecracker, status: :unavailable, reason: :unknown_backend}] =
             result.candidates

    assert [%{reason: :no_available_backend}] = result.diagnostics
  end

  test "doctor is disabled by default and does not inspect backends", %{home: home} do
    report = Sandbox.doctor(backends: [ExplodingBackend], host: %Host{os: :linux, arch: :x86_64})

    assert report.status == :disabled
    assert report.enabled? == false
    assert report.configured_backend == "auto"
    assert report.resolved_backend == nil
    assert report.candidates == []
    assert report.roots.bundles == Path.join([home, "sandbox", "bundles"])
    assert File.dir?(Path.join([home, "sandbox", "reports"]))
  end

  test "doctor resolves configured backend when enabled" do
    assert {:ok, _settings} =
             Settings.write_user_settings(%{
               "sandbox" => %{
                 "elixir" => %{
                   "enabled" => true,
                   "backend" => "docker",
                   "image" => "fixture:local"
                 }
               }
             })

    report =
      Sandbox.doctor(
        backends: [AvailableDocker],
        host: %Host{os: :linux, arch: :x86_64}
      )

    assert report.status == :available
    assert report.enabled? == true
    assert report.configured_backend == "docker"
    assert report.resolved_backend == :docker
    assert [%{id: :docker, status: :available}] = report.candidates
  end

  test "bundle builder copies only allowed project, draft, and test inputs", %{home: home} do
    project = fixture_project("copy")
    File.mkdir_p!(Path.join(project, ".git"))
    File.write!(Path.join([project, ".git", "config"]), "secret repo metadata")
    File.mkdir_p!(Path.join(project, "deps"))
    File.write!(Path.join([project, "deps", "ignored.ex"]), "defmodule Ignored, do: nil")

    assert {:ok, %Bundle{} = bundle} =
             Sandbox.build_bundle(%{
               id: "copy-bundle",
               project_root: project,
               project_paths: ["mix.exs", "lib"],
               draft_paths: ["drafts/generated.ex"],
               test_paths: ["test/generated_test.exs"]
             })

    assert File.exists?(Path.join([bundle.project_path, "mix.exs"]))
    assert File.exists?(Path.join([bundle.project_path, "lib", "safe.ex"]))
    assert File.exists?(Path.join([bundle.drafts_path, "drafts", "generated.ex"]))
    assert File.exists?(Path.join([bundle.tests_path, "test", "generated_test.exs"]))
    refute File.exists?(Path.join([bundle.project_path, ".git", "config"]))
    refute File.exists?(Path.join([bundle.project_path, "deps", "ignored.ex"]))
    assert bundle.sandbox_home == Path.join(bundle.root, "sandbox_home")
    assert String.starts_with?(bundle.root, Path.join([home, "sandbox", "bundles"]))
    assert File.exists?(bundle.metadata_path)
  end

  test "bundle builder fails closed on traversal, real home, and symlink escapes", %{home: home} do
    project = fixture_project("denied")
    outside = Path.join(Path.dirname(project), "outside.ex")
    File.write!(outside, "defmodule Outside, do: nil")

    assert {:error, %{reason: {:path_outside_project, _path}}} =
             Sandbox.build_bundle(%{project_root: project, draft_paths: [outside]})

    assert {:error, %{reason: :real_home_not_allowed}} =
             Sandbox.build_bundle(%{project_root: home})

    link = Path.join(project, "link.ex")
    File.ln_s!(outside, link)

    assert {:error, %{reason: {:symlink_not_allowed, _path}}} =
             Sandbox.build_bundle(%{project_root: project, draft_paths: [link]})
  end

  test "bundle builder confines bundle ids and explicit roots to the sandbox bundle root" do
    project = fixture_project("root-confined")
    outside_root = temp_path("outside-root")

    assert {:error, %{reason: {:invalid_bundle_id, "../escape"}}} =
             Sandbox.build_bundle(%{
               id: "../escape",
               project_root: project,
               project_paths: ["mix.exs"]
             })

    assert {:error, %{reason: {:bundle_root_outside_sandbox, _path}}} =
             Sandbox.build_bundle(
               %{project_root: project, project_paths: ["mix.exs"]},
               root: outside_root
             )
  end

  test "cleanup only removes marked sandbox bundle roots" do
    project = fixture_project("cleanup-confined")
    outside = temp_path("cleanup-outside")
    File.mkdir_p!(outside)
    File.write!(Path.join(outside, "keep.txt"), "keep")

    assert {:error, {:sandbox_bundle_root_outside_sandbox, _path}} = Sandbox.cleanup(outside)
    assert File.exists?(Path.join(outside, "keep.txt"))

    unmarked = Path.join(Paths.sandbox_bundles_root(), "unmarked")
    File.mkdir_p!(unmarked)
    File.write!(Path.join(unmarked, "keep.txt"), "keep")

    assert {:error, {:sandbox_bundle_metadata_missing, _path}} = Sandbox.cleanup(unmarked)
    assert File.exists?(Path.join(unmarked, "keep.txt"))

    {:ok, bundle} =
      Sandbox.build_bundle(%{
        project_root: project,
        project_paths: ["mix.exs"],
        id: "cleanup-confined"
      })

    assert :ok = Sandbox.cleanup(bundle)
    refute File.exists?(bundle.root)
  end

  test "command spec accepts only explicit Elixir gate argv shapes" do
    project = fixture_project("command")
    {:ok, bundle} = Sandbox.build_bundle(%{project_root: project, project_paths: ["mix.exs"]})
    policy = policy("docker", %Host{os: :linux, arch: :x86_64})

    assert {:ok, compile} =
             CommandSpec.normalize(
               %{executable: "mix", argv: ["compile", "--warnings-as-errors"], profile: :compile},
               policy: policy,
               bundle: bundle
             )

    assert CommandSpec.allowed?(compile)
    assert compile.cwd == bundle.project_path

    assert {:error, denied_shell} =
             CommandSpec.normalize(
               %{executable: "mix", argv: ["test", "&&", "curl"], profile: :focused_tests},
               policy: policy,
               bundle: bundle
             )

    assert denied_shell.denial_reason == :shell_syntax_not_allowed

    assert {:error, denied_deps} =
             CommandSpec.normalize(
               %{executable: "mix", argv: ["deps.get"], profile: :compile},
               policy: policy,
               bundle: bundle
             )

    assert denied_deps.denial_reason == :mix_command_not_allowed

    assert {:error, denied_env} =
             CommandSpec.normalize(
               %{
                 executable: "mix",
                 argv: ["compile", "--warnings-as-errors"],
                 profile: :compile,
                 env: %{"OPENAI_API_KEY" => "sk-test"}
               },
               policy: policy,
               bundle: bundle
             )

    assert denied_env.denial_reason == :secret_env_not_allowed

    assert {:error, denied_cwd} =
             CommandSpec.normalize(
               %{
                 executable: "mix",
                 argv: ["compile", "--warnings-as-errors"],
                 profile: :compile,
                 cwd: Path.dirname(bundle.root)
               },
               policy: policy,
               bundle: bundle
             )

    assert {:cwd_outside_bundle, _path} = denied_cwd.denial_reason

    assert {:error, missing_profile} =
             CommandSpec.normalize(
               %{executable: "mix", argv: ["compile", "--warnings-as-errors"]},
               policy: policy,
               bundle: bundle
             )

    assert missing_profile.denial_reason == :profile_not_allowed
  end

  test "run_command revalidates forged command spec structs before backend execution" do
    enable_sandbox!()

    project = fixture_project("forged-spec")
    {:ok, bundle} = Sandbox.build_bundle(%{project_root: project, project_paths: ["mix.exs"]})

    forged = %CommandSpec{
      executable: "curl",
      argv: ["https://example.com"],
      cwd: bundle.project_path,
      profile: :compile,
      timeout_ms: 120_000,
      output_bytes: 65_536,
      status: :allowed
    }

    assert {:ok, report} =
             Sandbox.run_command(bundle, forged,
               backends: [CompletingDocker],
               host: %Host{os: :linux, arch: :x86_64}
             )

    assert report.status == :denied
    assert [%{reason: :executable_not_allowed}] = report.diagnostics
  end

  test "source policy denies dangerous Elixir constructs before backend execution" do
    project = fixture_project("source-policy")
    malicious = Path.join([project, "drafts", "generated.ex"])

    File.write!(malicious, """
    defmodule Generated do
      def run do
        System.cmd("sh", ["-c", "curl example.com"])
        Port.open({:spawn, "sh"}, [])
        Mix.install([:req])
      end
    end
    """)

    {:ok, bundle} =
      Sandbox.build_bundle(%{
        project_root: project,
        project_paths: ["mix.exs"],
        draft_paths: ["drafts/generated.ex"]
      })

    assert {:error, report} = SourcePolicy.scan(bundle)
    reasons = Enum.map(report.diagnostics, & &1.reason)
    assert :system_cmd in reasons
    assert :port_open in reasons
    assert :mix_install in reasons
    refute inspect(report) =~ Paths.home()
  end

  test "source policy allows safe draft source" do
    project = fixture_project("source-safe")

    {:ok, bundle} =
      Sandbox.build_bundle(%{
        project_root: project,
        project_paths: ["mix.exs"],
        draft_paths: ["drafts/generated.ex"]
      })

    assert {:ok, %{status: :allowed, diagnostics: []}} = SourcePolicy.scan(bundle)
  end

  test "docker backend argv uses a local, networkless, read-only container contract" do
    project = fixture_project("docker-argv")
    {:ok, bundle} = Sandbox.build_bundle(%{project_root: project, project_paths: ["mix.exs"]})
    policy = policy("docker", %Host{os: :linux, arch: :x86_64})
    spec = compile_spec!(bundle, policy)

    argv = Docker.argv(bundle, spec, policy)

    assert Enum.take(argv, 2) == ["run", "--rm"]
    assert ["--pull", "never"] = argv_pair(argv, "--pull")
    assert ["--network", "none"] = argv_pair(argv, "--network")
    assert "--read-only" in argv
    assert ["--cap-drop", "ALL"] = argv_pair(argv, "--cap-drop")
    assert ["--security-opt", "no-new-privileges"] = argv_pair(argv, "--security-opt")
    assert ["--user", "65532:65532"] = argv_pair(argv, "--user")
    assert ["--pids-limit", "256"] = argv_pair(argv, "--pids-limit")
    assert ["--memory", "1024m"] = argv_pair(argv, "--memory")
    assert ["--cpus", "1.0"] = argv_pair(argv, "--cpus")
    assert argv_pair(argv, "--workdir") == ["--workdir", "/workspace/project"]
    assert Enum.any?(argv, &(&1 == "/tmp:rw,nosuid,nodev,size=256m,mode=1777"))
    assert Enum.any?(argv, &(&1 == "/run:rw,nosuid,nodev,size=32m,mode=1777"))

    assert mount_arg(argv, bundle.project_path) =~ "target=/workspace/project,readonly"
    assert mount_arg(argv, bundle.drafts_path) =~ "target=/workspace/drafts,readonly"
    assert mount_arg(argv, bundle.tests_path) =~ "target=/workspace/tests,readonly"
    refute mount_arg(argv, bundle.sandbox_home) =~ "readonly"
    refute mount_arg(argv, bundle.reports_path) =~ "readonly"

    assert ["--env", "ALLBERT_HOME=/workspace/allbert_home"] = argv_pair(argv, "--env")
    assert Enum.slice(argv, -4, 4) == ["fixture:local", "mix", "compile", "--warnings-as-errors"]
    refute Enum.any?(argv, &String.contains?(&1, "docker.sock"))
    refute Enum.any?(argv, &(&1 in ["-i", "-t", "-it"]))
  end

  test "docker runsc backend argv pins the gVisor runtime" do
    project = fixture_project("docker-runsc-argv")
    {:ok, bundle} = Sandbox.build_bundle(%{project_root: project, project_paths: ["mix.exs"]})
    policy = policy("docker_runsc", %Host{os: :linux, arch: :x86_64})
    spec = compile_spec!(bundle, policy)

    argv = DockerRunsc.argv(bundle, spec, policy)

    assert ["--runtime", "runsc"] = argv_pair(argv, "--runtime")
    assert ["--network", "none"] = argv_pair(argv, "--network")
    assert Enum.slice(argv, -4, 4) == ["fixture:local", "mix", "compile", "--warnings-as-errors"]
  end

  test "podman backend argv uses rootless-friendly local image settings" do
    project = fixture_project("podman-argv")
    {:ok, bundle} = Sandbox.build_bundle(%{project_root: project, project_paths: ["mix.exs"]})
    policy = policy("podman_rootless", %Host{os: :linux, arch: :x86_64})
    spec = compile_spec!(bundle, policy)

    argv = PodmanRootless.argv(bundle, spec, policy)

    assert "--pull=never" in argv
    assert ["--network", "none"] = argv_pair(argv, "--network")
    assert "--read-only" in argv
    assert ["--cap-drop", "ALL"] = argv_pair(argv, "--cap-drop")
    assert "--userns=keep-id" in argv
    assert mount_arg(argv, bundle.project_path) =~ "target=/workspace/project,readonly"
    assert Enum.slice(argv, -4, 4) == ["fixture:local", "mix", "compile", "--warnings-as-errors"]
  end

  test "report maps redact home paths and sensitive metadata while structs keep file paths" do
    project = fixture_project("report-map-redaction")
    {:ok, bundle} = Sandbox.build_bundle(%{project_root: project, project_paths: ["mix.exs"]})

    assert {:ok, report} =
             ReportWriter.write(bundle, %Report{
               status: :completed,
               backend: :docker,
               metadata: %{engine_argv: [bundle.project_path], api_key: "sk-test-secret"}
             })

    assert File.exists?(report.report_path)
    redacted = Report.to_map(report)

    refute inspect(redacted) =~ bundle.project_path
    refute inspect(redacted) =~ "sk-test-secret"
    assert inspect(redacted) =~ "<ALLBERT_HOME>"
    assert inspect(redacted) =~ "[REDACTED]"
  end

  test "container runner writes bounded reports for successful backend execution", %{home: home} do
    project = fixture_project("container-runner-success")

    {:ok, bundle} =
      Sandbox.build_bundle(%{
        project_root: project,
        project_paths: ["mix.exs"],
        draft_paths: ["drafts/generated.ex"]
      })

    policy = policy("docker", %Host{os: :linux, arch: :x86_64})
    spec = compile_spec!(bundle, policy)
    echo = System.find_executable("echo") || "/bin/echo"

    assert {:ok, report} = ContainerRunner.run(:docker, echo, ["sandbox ok"], bundle, spec)
    assert report.status == :completed
    assert report.exit_status == 0
    assert report.stdout =~ "sandbox ok"
    assert report.metadata.engine_argv == ["sandbox ok"]
    assert File.exists?(report.report_path)

    persisted = report.report_path |> File.read!() |> Jason.decode!()
    assert persisted["status"] == "completed"
    refute inspect(persisted) =~ home
    assert inspect(persisted) =~ "<ALLBERT_HOME>"
  end

  test "container runner writes denied reports before invoking backend execution" do
    project = fixture_project("container-runner-denied")
    malicious = Path.join([project, "drafts", "generated.ex"])
    File.write!(malicious, "defmodule Generated, do: def run, do: System.cmd(\"sh\", [])\n")

    {:ok, bundle} =
      Sandbox.build_bundle(%{
        project_root: project,
        project_paths: ["mix.exs"],
        draft_paths: ["drafts/generated.ex"]
      })

    policy = policy("docker", %Host{os: :linux, arch: :x86_64})
    spec = compile_spec!(bundle, policy)

    assert {:ok, report} =
             ContainerRunner.run(:docker, "/definitely/missing", ["should-not-run"], bundle, spec)

    assert report.status == :denied
    assert report.exit_status == nil
    assert [%{reason: :system_cmd}] = report.diagnostics
    assert File.exists?(report.report_path)
  end

  test "run_command denies disabled sandbox before backend execution" do
    project = fixture_project("run-disabled")
    {:ok, bundle} = Sandbox.build_bundle(%{project_root: project, project_paths: ["mix.exs"]})
    policy = policy("docker", %Host{os: :linux, arch: :x86_64})
    spec = compile_spec!(bundle, policy)

    assert {:ok, report} = Sandbox.run_command(bundle, spec, backends: [ExplodingBackend])
    assert report.status == :denied
    assert [%{reason: :sandbox_disabled, policy: _policy}] = report.diagnostics
    assert File.exists?(report.report_path)
  end

  test "run_command resolves backend and writes command report" do
    enable_sandbox!()

    project = fixture_project("run-command")
    {:ok, bundle} = Sandbox.build_bundle(%{project_root: project, project_paths: ["mix.exs"]})

    assert {:ok, report} =
             Sandbox.run_command(bundle, compile_params(),
               backends: [CompletingDocker],
               host: %Host{os: :linux, arch: :x86_64}
             )

    assert report.status == :completed
    assert report.backend == :docker
    assert report.metadata.fixture_backend?
    assert File.exists?(report.report_path)
  end

  test "run_gate aggregates reviewed profiles and halts on first failing report" do
    enable_sandbox!()

    project = fixture_project("run-gate")
    {:ok, bundle} = Sandbox.build_bundle(%{project_root: project, project_paths: ["mix.exs"]})

    assert {:ok, passed} =
             Sandbox.run_gate(bundle,
               profiles: [:compile, :credo],
               backends: [CompletingDocker],
               host: %Host{os: :linux, arch: :x86_64}
             )

    assert passed.status == :completed
    assert passed.backend == :gate_runner
    assert passed.metadata.step_count == 2

    assert {:ok, failed} =
             Sandbox.run_gate(bundle,
               profiles: [:compile, :credo],
               backends: [FailingDocker],
               host: %Host{os: :linux, arch: :x86_64}
             )

    assert failed.status == :failed
    assert failed.metadata.step_count == 1
    assert [%{reason: :fixture_failure}] = failed.diagnostics
  end

  defp policy(backend, host) do
    %Policy{
      enabled?: true,
      backend: backend,
      image: "fixture:local",
      network: "none",
      cpu_limit: 1.0,
      memory_mb: 1024,
      timeout_ms: 120_000,
      output_bytes: 65_536,
      roots: %{},
      host: host
    }
  end

  defp enable_sandbox! do
    assert {:ok, _settings} =
             Settings.write_user_settings(%{
               "sandbox" => %{
                 "elixir" => %{
                   "enabled" => true,
                   "backend" => "docker",
                   "image" => "fixture:local"
                 }
               }
             })
  end

  defp compile_params,
    do: %{executable: "mix", argv: ["compile", "--warnings-as-errors"], profile: :compile}

  defp compile_spec!(bundle, policy) do
    assert {:ok, spec} = CommandSpec.normalize(compile_params(), policy: policy, bundle: bundle)

    spec
  end

  defp argv_pair(argv, flag) do
    index = Enum.find_index(argv, &(&1 == flag))
    Enum.slice(argv, index, 2)
  end

  defp mount_arg(argv, source) do
    argv
    |> Enum.chunk_every(2, 1, :discard)
    |> Enum.find_value(fn
      ["--mount", mount] ->
        if String.contains?(mount, "source=#{source},"), do: mount

      _chunk ->
        nil
    end)
  end

  defp fixture_project(name) do
    root = temp_path("project-#{name}")
    File.rm_rf!(root)

    File.mkdir_p!(Path.join(root, "lib"))
    File.mkdir_p!(Path.join(root, "drafts"))
    File.mkdir_p!(Path.join(root, "test"))

    File.write!(Path.join(root, "mix.exs"), """
    defmodule Fixture.MixProject do
      use Mix.Project
      def project, do: [app: :fixture, version: "0.1.0", elixir: "~> 1.19"]
      def application, do: []
    end
    """)

    File.write!(Path.join([root, "lib", "safe.ex"]), "defmodule Safe, do: def ok, do: :ok\n")

    File.write!(
      Path.join([root, "drafts", "generated.ex"]),
      "defmodule Generated, do: def ok, do: :ok\n"
    )

    File.write!(
      Path.join([root, "test", "generated_test.exs"]),
      "defmodule GeneratedTest, do: use ExUnit.Case\n"
    )

    root
  end

  defp temp_path(name) do
    Path.join(System.tmp_dir!(), "allbert-sandbox-#{name}-#{System.unique_integer([:positive])}")
  end

  defp restore_app_env(module, nil), do: Application.delete_env(:allbert_assist, module)
  defp restore_app_env(module, config), do: Application.put_env(:allbert_assist, module, config)
end
