defmodule AllbertAssist.SandboxImageTest do
  use ExUnit.Case, async: false

  alias AllbertAssist.Paths
  alias AllbertAssist.Sandbox.Host
  alias AllbertAssist.Sandbox.Image
  alias AllbertAssist.Sandbox.Policy
  alias AllbertAssist.Settings

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

  test "build uses explicit Docker argv and writes a redacted report", %{home: home} do
    project = fixture_project("build")
    test_pid = self()

    runner = fn docker, argv, opts ->
      send(test_pid, {:build_command, docker, argv, opts})
      context = List.last(argv)
      dockerfile = File.read!(Path.join(context, "Dockerfile"))

      assert File.exists?(Path.join(context, "Dockerfile"))
      assert File.exists?(Path.join([context, "project", "mix.exs"]))
      assert dockerfile =~ "MIX_DEPS_PATH=/opt/allbert/deps"
      assert dockerfile =~ "mix deps.get --only test"
      assert dockerfile =~ "mix deps.compile"

      {:ok, %{exit_status: 0, output: "built image", truncated?: false, output_bytes: 11}}
    end

    assert {:ok, report} =
             Image.build(
               policy: policy(),
               docker: "/usr/local/bin/docker",
               command_runner: runner,
               project_root: project
             )

    assert_receive {:build_command, "/usr/local/bin/docker", argv, opts}

    assert Enum.take(argv, 2) == ["build", "--pull"]
    assert ["--tag", "fixture:local"] = argv_pair(argv, "--tag")
    assert argv_pair(argv, "--build-arg") == ["--build-arg", "BASE_IMAGE=#{default_base()}"]
    assert Enum.any?(argv, &(&1 == "--label"))
    assert opts[:timeout_ms] == 120_000
    assert report.status == :completed
    assert File.exists?(report.report_path)

    persisted = File.read!(report.report_path)
    refute persisted =~ home
    assert persisted =~ "<ALLBERT_HOME>"
  end

  test "verify inspects labels and runs local-only container check" do
    project = fixture_project("verify")
    labels = Image.labels(project)
    test_pid = self()

    runner = fn
      _docker,
      ["image", "inspect", "fixture:local", "--format", "{{json .Config.Labels}}"],
      _opts ->
        {:ok, %{exit_status: 0, output: Jason.encode!(labels), truncated?: false}}

      docker, ["run" | _rest] = argv, opts ->
        send(test_pid, {:verify_command, docker, argv, opts})
        {:ok, %{exit_status: 0, output: "Elixir 1.19.5", truncated?: false}}
    end

    assert {:ok, report} =
             Image.verify(
               policy: policy(),
               docker: "/usr/local/bin/docker",
               command_runner: runner,
               project_root: project
             )

    assert_receive {:verify_command, "/usr/local/bin/docker", argv, _opts}
    assert "--pull=never" in argv
    assert ["--network", "none"] = argv_pair(argv, "--network")
    assert Enum.take(Enum.reverse(argv), 3) == ["--version", "elixir", "fixture:local"]
    assert report.status == :completed
    assert File.exists?(report.report_path)
  end

  test "local status distinguishes missing and invalid images" do
    project = fixture_project("missing")

    missing_runner = fn _docker, _argv, _opts ->
      {:ok, %{exit_status: 1, output: "No such image", truncated?: false}}
    end

    assert {:error, {:image_missing, "fixture:local", %{hint: "mix allbert.sandbox image build"}}} =
             Image.local_status(policy(), "/usr/local/bin/docker",
               command_runner: missing_runner,
               project_root: project
             )

    invalid_runner = fn _docker, _argv, _opts ->
      {:ok, %{exit_status: 0, output: Jason.encode!(%{}), truncated?: false}}
    end

    assert {:error, {:image_labels_invalid, %{hint: "mix allbert.sandbox image build"}}} =
             Image.local_status(policy(), "/usr/local/bin/docker",
               command_runner: invalid_runner,
               project_root: project
             )
  end

  test "verify run argv is local-only" do
    argv = Image.verify_run_argv("fixture:local")

    assert Enum.take(argv, 2) == ["run", "--rm"]
    assert "--pull=never" in argv
    assert ["--network", "none"] = argv_pair(argv, "--network")
    assert "--read-only" in argv
    assert ["--cap-drop", "ALL"] = argv_pair(argv, "--cap-drop")
    assert ["--security-opt", "no-new-privileges"] = argv_pair(argv, "--security-opt")
    assert Enum.slice(argv, -3, 3) == ["fixture:local", "elixir", "--version"]
  end

  defp policy do
    %Policy{
      enabled?: true,
      backend: "docker",
      image: "fixture:local",
      network: "none",
      cpu_limit: 1.0,
      memory_mb: 1024,
      timeout_ms: 120_000,
      output_bytes: 65_536,
      roots: %{},
      host: %Host{os: :linux, arch: :x86_64}
    }
  end

  defp default_base do
    "elixir:#{System.version()}-otp-#{:erlang.system_info(:otp_release)}-slim"
  end

  defp argv_pair(argv, flag) do
    index = Enum.find_index(argv, &(&1 == flag))
    Enum.slice(argv, index, 2)
  end

  defp fixture_project(name) do
    root = temp_path("project-#{name}")
    File.rm_rf!(root)
    File.mkdir_p!(root)

    File.write!(Path.join(root, "mix.exs"), """
    defmodule Fixture.MixProject do
      use Mix.Project
      def project, do: [app: :fixture, version: "0.1.0", elixir: ">= 1.15.0", deps: []]
      def application, do: []
    end
    """)

    File.write!(Path.join(root, "mix.lock"), "%{\"dep\" => :lock}\n")
    root
  end

  defp temp_path(name) do
    Path.join(
      System.tmp_dir!(),
      "allbert-sandbox-image-#{name}-#{System.unique_integer([:positive])}"
    )
  end

  defp restore_app_env(module, nil), do: Application.delete_env(:allbert_assist, module)
  defp restore_app_env(module, config), do: Application.put_env(:allbert_assist, module, config)
end
