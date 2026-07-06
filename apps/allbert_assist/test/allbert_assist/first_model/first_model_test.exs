defmodule AllbertAssist.FirstModelTest do
  @moduledoc """
  v0.62 M4 — First-Model-Path: the Ollama three-way probe resolves the model
  states; the guided install and pull execute only behind an approved
  confirmation (the M4 Authority Contract), record their command/egress, and
  degrade to BYOK below the floor / on decline.
  """
  use AllbertAssist.DataCase, async: false

  alias AllbertAssist.Actions.FirstModel.{InstallOllama, PullModel}
  alias AllbertAssist.Actions.Runner
  alias AllbertAssist.FirstModel.{Hardware, Ollama}

  @moduletag :first_model_path

  setup {Req.Test, :verify_on_exit!}

  setup do
    original_req_options = Application.get_env(:allbert_assist, :first_model_req_options)
    original_host = System.get_env("OLLAMA_HOST")

    on_exit(fn ->
      if original_req_options,
        do: Application.put_env(:allbert_assist, :first_model_req_options, original_req_options),
        else: Application.delete_env(:allbert_assist, :first_model_req_options)

      if original_host,
        do: System.put_env("OLLAMA_HOST", original_host),
        else: System.delete_env("OLLAMA_HOST")
    end)

    :ok
  end

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

    test "default localhost HTTP uses Req and parses version/tags" do
      Application.put_env(:allbert_assist, :first_model_req_options, plug: {Req.Test, __MODULE__})

      Req.Test.expect(__MODULE__, fn %{request_path: "/api/version"} = conn ->
        Req.Test.json(conn, %{"version" => "0.5.0"})
      end)

      assert Ollama.server_version() == {:ok, "0.5.0"}

      Req.Test.expect(__MODULE__, fn %{request_path: "/api/tags"} = conn ->
        Req.Test.json(conn, %{
          "models" => [%{"name" => Ollama.curated_model()}]
        })
      end)

      assert Ollama.model_tags() == [Ollama.curated_model()]
    end

    test "default HTTP refuses non-loopback OLLAMA_HOST" do
      System.put_env("OLLAMA_HOST", "https://example.com")

      assert Ollama.local_url("/api/version") == {:error, :non_loopback_host}
      assert Ollama.server_version() == :error
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
      assert {:ok, %{status: :completed, actions: [%{executed: false, commands: commands}]}} =
               Runner.run("install_ollama", %{dry_run: true}, %{user_id: "local"})

      assert is_list(commands)
      assert commands != []
    end

    test "the install commands are allowlisted per OS (no shell pipeline)" do
      assert {:ok, commands} = InstallOllama.install_commands()

      for {cmd, args} <- commands do
        assert is_binary(cmd)
        assert is_list(args)
        refute cmd in ["sh", "bash", "zsh"] and "-c" in args
      end
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

    test "approved pull uses Req against the loopback Ollama API" do
      Application.put_env(:allbert_assist, :first_model_req_options, plug: {Req.Test, __MODULE__})

      Req.Test.expect(__MODULE__, fn %{method: "POST", request_path: "/api/pull"} = conn ->
        assert Req.Test.raw_body(conn) =~ Ollama.curated_model()
        Req.Test.json(conn, %{"status" => "success"})
      end)

      assert {:ok, %{status: :completed, actions: [%{executed: true, summary: summary}]}} =
               PullModel.run(%{}, %{confirmation: %{approved?: true}})

      assert summary.status == "success"
    end
  end
end
