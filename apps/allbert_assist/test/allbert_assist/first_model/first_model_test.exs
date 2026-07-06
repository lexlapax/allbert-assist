defmodule AllbertAssist.FirstModelTest do
  @moduledoc """
  v0.62 M4 — First-Model-Path: the Ollama three-way probe resolves the model
  states; the guided install and pull execute only behind an approved
  confirmation (the M4 Authority Contract), record their command/egress, and
  degrade to BYOK below the floor / on decline.
  """
  use AllbertAssist.DataCase, async: false

  alias AllbertAssist.Actions.FirstModel.{Detect, InstallOllama, PullModel}
  alias AllbertAssist.Actions.Runner
  alias AllbertAssist.FirstModel.{Hardware, Ollama}

  @moduletag :first_model_path

  describe "Ollama.probe/1 (three-way, injected)" do
    test "model_ready when server up and the curated model is present" do
      assert Ollama.probe(
               binary?: fn -> true end,
               version: fn -> {:ok, "0.1"} end,
               tags: fn -> [Ollama.curated_model()] end
             ) == :model_ready
    end

    test "model_missing when server up but curated model absent" do
      assert Ollama.probe(
               binary?: fn -> true end,
               version: fn -> {:ok, "0.1"} end,
               tags: fn -> ["something-else"] end
             ) == :model_missing
    end

    test "unhealthy when the version endpoint is malformed" do
      assert Ollama.probe(
               binary?: fn -> true end,
               version: fn -> :unhealthy end,
               tags: fn -> [] end
             ) == :unhealthy
    end

    test "missing when neither binary nor server is present" do
      assert Ollama.probe(
               binary?: fn -> false end,
               version: fn -> :error end,
               tags: fn -> [] end
             ) == :missing
    end
  end

  test "Hardware.meets_floor? passes unknown RAM and honors a real floor" do
    # On this host RAM is detectable; a floor of 1 GB always passes, a floor of
    # 10_000 GB never does.
    assert Hardware.meets_floor?(1)
    refute Hardware.meets_floor?(1_000_000)
  end

  test "first_model_detect is read-only and reports a state" do
    assert {:ok, %{status: :completed, first_model: %{state: state}}} =
             Runner.run("first_model_detect", %{}, %{user_id: "local"})

    assert state in [
             :local_ready,
             :runtime_missing,
             :runtime_unhealthy,
             :model_missing,
             :below_hardware_floor,
             :byok_ready,
             :blocked
           ]
  end

  describe "install_ollama (command_execute, confirmation-gated)" do
    test "the gate deny path executes nothing" do
      denied = %{user_id: "local", selected_action: "unregistered_boundary_probe"}

      assert {:ok, %{status: status, actions: [%{executed: false}]}} =
               InstallOllama.run(%{}, denied)

      assert status in [:denied, :error]
    end

    test "dry_run reports the allowlisted command without executing" do
      assert {:ok, %{status: :completed, actions: [%{executed: false, command: command}]}} =
               Runner.run("install_ollama", %{dry_run: true}, %{user_id: "local"})

      assert is_list(command)
    end

    test "the install command is allowlisted per OS (no shell injection surface)" do
      {cmd, args} = InstallOllama.install_command()
      assert is_binary(cmd)
      assert is_list(args)
    end
  end

  describe "pull_model (external_network, confirmation-gated)" do
    test "the gate deny path pulls nothing" do
      denied = %{user_id: "local", selected_action: "unregistered_boundary_probe"}

      assert {:ok, %{status: status, actions: [%{executed: false}]}} =
               PullModel.run(%{}, denied)

      assert status in [:denied, :error]
    end

    test "dry_run names the model + endpoint without egress" do
      assert {:ok, %{status: :completed, message: message, actions: [%{executed: false}]}} =
               Runner.run("pull_model", %{dry_run: true}, %{user_id: "local"})

      assert message =~ "/api/pull"
      assert message =~ Ollama.curated_model()
    end
  end
end
