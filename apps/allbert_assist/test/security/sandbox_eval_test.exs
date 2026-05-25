defmodule AllbertAssist.Security.SandboxEvalTest do
  use AllbertAssist.SecurityEvalCase, async: false

  alias AllbertAssist.Paths
  alias AllbertAssist.Sandbox
  alias AllbertAssist.Sandbox.Backend.Resolver
  alias AllbertAssist.Sandbox.Backends.Docker
  alias AllbertAssist.Sandbox.Bundle
  alias AllbertAssist.Sandbox.CommandSpec
  alias AllbertAssist.Sandbox.Host
  alias AllbertAssist.Sandbox.Policy
  alias AllbertAssist.Sandbox.Report
  alias AllbertAssist.Sandbox.ReportWriter
  alias AllbertAssist.SecurityFixtures.EvalInventory
  alias AllbertAssist.Settings

  defmodule EvalDocker do
    @behaviour AllbertAssist.Sandbox.Backend

    def id, do: :docker
    def platforms, do: [:linux]
    def available?(_policy), do: true
    def doctor(_policy), do: %{id: id(), status: :available, reason: :doctor_green}

    def run(bundle, command, _policy) do
      ReportWriter.write(bundle, %Report{
        status: :completed,
        backend: id(),
        command: CommandSpec.summary(command),
        metadata: %{side_effect_ran?: true}
      })
    end

    def cleanup(_bundle), do: :ok
  end

  defmodule UnsupportedDocker do
    @behaviour AllbertAssist.Sandbox.Backend

    def id, do: :docker
    def platforms, do: [:macos]
    def available?(_policy), do: true
    def doctor(_policy), do: %{id: id(), status: :available, reason: :doctor_green}
    def run(_bundle, _command, _policy), do: {:error, :should_not_run}
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

  test "v0.36 sandbox eval rows are registered in the inventory" do
    ids =
      :v036
      |> EvalInventory.rows_for_milestone()
      |> Enum.map(& &1.id)

    assert ids == [
             "sandbox-backend-disabled-001",
             "sandbox-backend-resolver-001",
             "sandbox-image-local-only-001",
             "sandbox-source-policy-001",
             "sandbox-command-shell-deny-001",
             "sandbox-command-struct-revalidate-001",
             "sandbox-network-deny-001",
             "sandbox-secret-deny-001",
             "sandbox-home-isolation-001",
             "sandbox-cleanup-root-confine-001",
             "sandbox-package-manager-deny-001",
             "sandbox-nif-port-deny-001",
             "sandbox-core-load-deny-001",
             "sandbox-report-redaction-001"
           ]
  end

  test "sandbox-backend-disabled-001 denies before backend execution" do
    bundle = safe_bundle!("disabled")
    spec = compile_spec!(bundle)

    assert {:ok, report} =
             Sandbox.run_command(bundle, spec,
               backends: [EvalDocker],
               host: %Host{os: :linux, arch: :x86_64}
             )

    eval =
      run_eval(%{
        id: "sandbox-backend-disabled-001",
        expected: :denied,
        eval_result: %{
          decision: report.status,
          result: report,
          trace: %{side_effect_ran?: report.metadata[:side_effect_ran?]}
        }
      })

    assert_denied(eval, no_side_effect?: true)
  end

  test "sandbox-backend-resolver-001 never selects unsupported on-platform backend" do
    enable_sandbox!()
    policy = policy("auto", %Host{os: :linux, arch: :x86_64})

    resolution =
      Resolver.resolve(policy,
        host: policy.host,
        backends: [UnsupportedDocker]
      )

    assert resolution.resolved_backend == nil
    assert Enum.any?(resolution.candidates, &(&1.status == :unsupported))
    refute Enum.any?(resolution.candidates, &(&1.status == :available))
  end

  test "sandbox-image-local-only-001 and sandbox-network-deny-001 are fixed in backend argv" do
    bundle = safe_bundle!("argv")
    policy = policy("docker", %Host{os: :linux, arch: :x86_64})
    spec = compile_spec!(bundle, policy)
    argv = Docker.argv(bundle, spec, policy)

    assert ["--pull", "never"] = pair(argv, "--pull")
    assert ["--network", "none"] = pair(argv, "--network")
    refute "--pull=always" in argv
    refute "--network=host" in argv
  end

  test "sandbox-source-policy-001 denies dangerous generated source before execution" do
    enable_sandbox!()

    bundle =
      malicious_bundle!("source-policy", """
      defmodule Generated do
        def run, do: System.cmd("sh", ["-c", "curl example.com"])
      end
      """)

    spec = compile_spec!(bundle)

    assert {:ok, report} =
             Sandbox.run_command(bundle, spec,
               policy: policy("docker", %Host{os: :linux, arch: :x86_64}),
               backends: [EvalDocker],
               host: %Host{os: :linux, arch: :x86_64}
             )

    assert report.status == :denied
    assert Enum.any?(report.diagnostics, &(&1.reason == :system_cmd))
  end

  test "sandbox-command-shell-deny-001 and package-manager-deny reject argv shapes" do
    bundle = safe_bundle!("command-deny")
    policy = policy("docker", %Host{os: :linux, arch: :x86_64})

    assert {:error, shell} =
             CommandSpec.normalize(
               %{executable: "mix", argv: ["test", "&&", "curl"], profile: :focused_tests},
               policy: policy,
               bundle: bundle
             )

    assert shell.denial_reason == :shell_syntax_not_allowed

    assert {:error, deps} =
             CommandSpec.normalize(
               %{executable: "mix", argv: ["deps.get"], profile: :compile},
               policy: policy,
               bundle: bundle
             )

    assert deps.denial_reason == :mix_command_not_allowed
  end

  test "sandbox-command-struct-revalidate-001 revalidates forged allowed structs" do
    enable_sandbox!()
    bundle = safe_bundle!("struct-revalidate")

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
               backends: [EvalDocker],
               host: %Host{os: :linux, arch: :x86_64}
             )

    eval =
      run_eval(%{
        id: "sandbox-command-struct-revalidate-001",
        expected: :denied,
        eval_result: %{
          decision: report.status,
          result: report,
          trace: %{side_effect_ran?: report.metadata[:side_effect_ran?]}
        }
      })

    assert_denied(eval, no_side_effect?: true)
    assert [%{reason: :executable_not_allowed}] = report.diagnostics
  end

  test "sandbox-secret-deny-001 blocks secret env passthrough" do
    bundle = safe_bundle!("secret-deny")
    policy = policy("docker", %Host{os: :linux, arch: :x86_64})

    assert {:error, spec} =
             CommandSpec.normalize(
               Map.put(compile_params(), :env, %{"OPENAI_API_KEY" => "sk-test-secret"}),
               policy: policy,
               bundle: bundle
             )

    assert spec.denial_reason == :secret_env_not_allowed
  end

  test "sandbox-home-isolation-001 mounts only disposable bundle roots" do
    bundle = safe_bundle!("home-isolation")
    policy = policy("docker", %Host{os: :linux, arch: :x86_64})
    spec = compile_spec!(bundle, policy)
    argv = Docker.argv(bundle, spec, policy)
    mount_args = mount_args(argv)

    refute Enum.any?(mount_args, &String.contains?(&1, "source=#{Paths.home()},"))
    assert Enum.any?(mount_args, &String.contains?(&1, "source=#{bundle.sandbox_home},"))
    assert bundle.sandbox_home != Paths.home()
  end

  test "sandbox-cleanup-root-confine-001 denies cleanup outside marked bundle roots" do
    outside = temp_path("cleanup-outside")
    File.mkdir_p!(outside)
    File.write!(Path.join(outside, "keep.txt"), "keep")

    result = Sandbox.cleanup(outside)

    eval =
      run_eval(%{
        id: "sandbox-cleanup-root-confine-001",
        expected: :denied,
        eval_result: %{
          decision: if(match?({:error, _}, result), do: :denied, else: :allowed),
          result: result,
          trace: %{side_effect_ran?: not File.exists?(Path.join(outside, "keep.txt"))}
        }
      })

    assert_denied(eval, no_side_effect?: true)
    assert {:error, {:sandbox_bundle_root_outside_sandbox, _path}} = result
    assert File.exists?(Path.join(outside, "keep.txt"))
  end

  test "sandbox-nif-port-deny-001 and core-load-deny block native/core loading attempts" do
    bundle =
      malicious_bundle!("native-core", """
      defmodule Generated do
        def run do
          Port.open({:spawn, "sh"}, [])
          :erlang.load_nif('/tmp/native', 0)
          Code.require_file("/tmp/core.ex")
        end
      end
      """)

    assert {:error, report} = Sandbox.SourcePolicy.scan(bundle)
    reasons = Enum.map(report.diagnostics, & &1.reason)
    assert :port_open in reasons
    assert :nif_load in reasons
    assert :code_require in reasons

    enable_sandbox!()

    module_name =
      Module.concat([
        AllbertAssist.SandboxEvalInjected,
        :"M#{System.unique_integer([:positive])}"
      ])

    source = "defmodule #{inspect(module_name)} do\n  def loaded?, do: true\nend\n"
    report_only_bundle = malicious_bundle!("report-only-core-load", source)
    spec = compile_spec!(report_only_bundle)

    assert {:ok, report} =
             Sandbox.run_command(report_only_bundle, spec,
               policy: policy("docker", %Host{os: :linux, arch: :x86_64}),
               backends: [EvalDocker],
               host: %Host{os: :linux, arch: :x86_64}
             )

    assert report.status == :completed
    refute Code.ensure_loaded?(module_name)
  end

  test "sandbox-report-redaction-001 redacts report paths and secrets" do
    bundle = safe_bundle!("report-redaction")

    assert {:ok, report} =
             ReportWriter.write(bundle, %Report{
               status: :denied,
               backend: :docker,
               diagnostics: [%{path: Paths.home(), api_key: "sk-test-secret"}]
             })

    persisted = report.report_path |> File.read!() |> Jason.decode!()
    inspected = inspect(persisted)

    refute inspected =~ Paths.home()
    refute inspected =~ "sk-test-secret"
    assert inspected =~ "<ALLBERT_HOME>"
    assert inspected =~ "[REDACTED]"
  end

  defp safe_bundle!(name) do
    project = fixture_project(name)

    assert {:ok, %Bundle{} = bundle} =
             Sandbox.build_bundle(%{
               project_root: project,
               project_paths: ["mix.exs"],
               draft_paths: ["drafts/generated.ex"]
             })

    bundle
  end

  defp malicious_bundle!(name, source) do
    project = fixture_project(name)
    File.write!(Path.join([project, "drafts", "generated.ex"]), source)

    assert {:ok, %Bundle{} = bundle} =
             Sandbox.build_bundle(%{
               project_root: project,
               project_paths: ["mix.exs"],
               draft_paths: ["drafts/generated.ex"]
             })

    bundle
  end

  defp compile_spec!(bundle),
    do: compile_spec!(bundle, policy("docker", %Host{os: :linux, arch: :x86_64}))

  defp compile_spec!(bundle, policy) do
    assert {:ok, spec} = CommandSpec.normalize(compile_params(), policy: policy, bundle: bundle)
    spec
  end

  defp compile_params do
    %{executable: "mix", argv: ["compile", "--warnings-as-errors"], profile: :compile}
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

  defp pair(argv, flag) do
    index = Enum.find_index(argv, &(&1 == flag))
    Enum.slice(argv, index, 2)
  end

  defp mount_args(argv) do
    argv
    |> Enum.chunk_every(2, 1, :discard)
    |> Enum.flat_map(fn
      ["--mount", mount] -> [mount]
      _chunk -> []
    end)
  end

  defp fixture_project(name) do
    root = temp_path("project-#{name}")

    File.mkdir_p!(Path.join(root, "drafts"))
    File.write!(Path.join(root, "mix.exs"), "defmodule Fixture.MixProject, do: nil\n")
    File.write!(Path.join([root, "drafts", "generated.ex"]), "defmodule Generated, do: nil\n")

    root
  end

  defp temp_path(name) do
    Path.join(
      System.tmp_dir!(),
      "allbert-sandbox-eval-#{name}-#{System.unique_integer([:positive])}"
    )
  end

  defp restore_app_env(module, nil), do: Application.delete_env(:allbert_assist, module)
  defp restore_app_env(module, config), do: Application.put_env(:allbert_assist, module, config)
end
