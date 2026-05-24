defmodule AllbertAssist.SandboxTest do
  use ExUnit.Case, async: false

  alias AllbertAssist.Paths
  alias AllbertAssist.Sandbox
  alias AllbertAssist.Sandbox.Backend.Registry
  alias AllbertAssist.Sandbox.Backend.Resolver
  alias AllbertAssist.Sandbox.Host
  alias AllbertAssist.Sandbox.Policy
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

  defp temp_path(name) do
    Path.join(System.tmp_dir!(), "allbert-sandbox-#{name}-#{System.unique_integer([:positive])}")
  end

  defp restore_app_env(module, nil), do: Application.delete_env(:allbert_assist, module)
  defp restore_app_env(module, config), do: Application.put_env(:allbert_assist, module, config)
end
