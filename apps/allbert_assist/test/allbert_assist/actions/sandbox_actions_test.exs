defmodule AllbertAssist.Actions.SandboxActionsTest do
  use ExUnit.Case, async: false
  @moduletag :app_env_serial

  alias AllbertAssist.Actions.Runner
  alias AllbertAssist.Paths
  alias AllbertAssist.Sandbox
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

  test "registered sandbox doctor action reports disabled posture" do
    assert {:ok, response} = Runner.run("sandbox_doctor", %{}, context())

    assert response.status == :disabled
    assert response.doctor.enabled? == false
    assert [%{name: "sandbox_doctor", status: :completed}] = response.actions
  end

  test "sandbox bundle action builds disposable bundle and cleanup action discards it" do
    project = fixture_project("actions-bundle")

    assert {:ok, response} =
             Runner.run(
               "build_sandbox_bundle",
               %{project_root: project, project_paths: ["mix.exs"], id: "action-bundle"},
               context()
             )

    assert response.status == :completed
    assert File.exists?(response.bundle.metadata_path)

    assert {:ok, cleanup} =
             Runner.run("discard_sandbox_bundle", %{root: response.bundle.root}, context())

    assert cleanup.status == :completed
    refute File.exists?(response.bundle.root)
  end

  test "sandbox command action returns denied report while sandbox is disabled" do
    project = fixture_project("actions-command")
    {:ok, bundle} = Sandbox.build_bundle(%{project_root: project, project_paths: ["mix.exs"]})

    assert {:ok, response} =
             Runner.run(
               "run_sandbox_command",
               %{bundle: bundle, command: compile_params()},
               context()
             )

    assert response.status == :denied
    assert response.report.status == :denied
    assert [%{reason: :sandbox_disabled, policy: _policy}] = response.report.diagnostics
  end

  defp context, do: %{request: %{operator_id: "sandbox-actions-test"}}

  defp compile_params do
    %{executable: "mix", argv: ["compile", "--warnings-as-errors"], profile: :compile}
  end

  defp fixture_project(name) do
    root = temp_path("project-#{name}")

    File.mkdir_p!(Path.join(root, "lib"))
    File.write!(Path.join(root, "mix.exs"), "defmodule Fixture.MixProject, do: nil\n")

    root
  end

  defp temp_path(name) do
    Path.join(
      System.tmp_dir!(),
      "allbert-sandbox-actions-#{name}-#{System.unique_integer([:positive])}"
    )
  end

  defp restore_app_env(module, nil), do: Application.delete_env(:allbert_assist, module)
  defp restore_app_env(module, config), do: Application.put_env(:allbert_assist, module, config)
end
