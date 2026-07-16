defmodule AllbertAssist.Workflows.ValidatorTest do
  use ExUnit.Case, async: false
  @moduletag :app_env_serial

  alias AllbertAssist.Objectives.AgentRegistry
  alias AllbertAssist.Settings
  alias AllbertAssist.Workflows.{Loader, Validator}

  defmodule PingCommand do
    use Jido.Action,
      name: "plan_build_validator_ping",
      description: "Plan/Build validator delegate fixture command."

    @impl true
    def run(params, context) do
      state = Map.get(context, :state, %{})

      {:ok,
       Map.merge(state, %{
         last_command: :ping,
         last_result: {:ok, %{reply: Map.get(params, "message") || Map.get(params, :message)}}
       })}
    end
  end

  defmodule StubAgent do
    use AllbertAssist.JidoBacked,
      name: "plan_build_validator_stub",
      description: "Plan/Build validator delegate fixture agent.",
      signal_routes: [
        {"allbert.plan_build.delegate.ping", AllbertAssist.Workflows.ValidatorTest.PingCommand}
      ]

    @impl true
    def rebuild_state(_opts), do: {:ok, %{last_command: nil, last_result: nil}}

    @impl true
    def command_modules, do: [AllbertAssist.Workflows.ValidatorTest.PingCommand]
  end

  setup do
    original_home = System.get_env("ALLBERT_HOME")
    original_paths_config = Application.get_env(:allbert_assist, AllbertAssist.Paths)
    original_settings_config = Application.get_env(:allbert_assist, Settings)
    home = Path.join(System.tmp_dir!(), "allbert-validator-#{System.unique_integer([:positive])}")
    System.put_env("ALLBERT_HOME", home)
    Application.put_env(:allbert_assist, AllbertAssist.Paths, home: home)
    Application.put_env(:allbert_assist, Settings, root: Path.join(home, "settings"))
    File.mkdir_p!(Path.join(home, "workflows"))

    on_exit(fn ->
      restore_env("ALLBERT_HOME", original_home)
      restore_app_env(AllbertAssist.Paths, original_paths_config)
      restore_app_env(Settings, original_settings_config)
      File.rm_rf!(home)
    end)

    {:ok, home: home}
  end

  test "accepts valid workflow fixtures", %{home: home} do
    for id <- ~w[single_step multi_step with_inputs with_ask_user with_if_condition with_save_as] do
      copy_fixture!(id, home)
      assert {:ok, workflow} = Loader.load(id)
      assert {:ok, _validated} = Validator.validate(workflow)
    end
  end

  test "accepts delegate-agent workflows when the target is registered", %{home: home} do
    server = :"plan_build_validator_stub_#{System.unique_integer([:positive])}"

    start_supervised!({StubAgent, name: server})
    assert {:ok, _entry} = AgentRegistry.register("plan-build-stub", server, StubAgent, %{})

    on_exit(fn -> AgentRegistry.unregister("plan-build-stub") end)

    copy_fixture!("with_delegate_agent", home)
    assert {:ok, workflow} = Loader.load("with_delegate_agent")
    assert {:ok, _validated} = Validator.validate(workflow)
  end

  test "rejects documented failure fixtures", %{home: home} do
    expected = %{
      "unknown_key" => :unknown_key,
      "dynamic_action_name" => :dynamic_action_name,
      "secret_substitution" => :secret_substitution_attempt,
      "env_substitution" => :env_substitution_attempt,
      "cycle" => :cycle,
      "forward_ref" => :forward_ref,
      "cap_exceeded" => :cap_exceeded
    }

    for {id, reason} <- expected do
      copy_fixture!(id, home)
      assert {:ok, workflow} = Loader.load(id)
      assert {:error, error} = Validator.validate(workflow)
      assert error.reason == reason
      assert is_binary(error.pointer)
    end
  end

  test "resolves declared inputs with defaults and rejects extras", %{home: home} do
    copy_fixture!("with_inputs", home)
    {:ok, workflow} = Loader.load("with_inputs")
    {:ok, workflow} = Validator.validate(workflow)

    assert {:ok, %{"topic" => "workflow YAML"}} =
             Validator.resolve_inputs(workflow, %{topic: "workflow YAML"})

    assert {:error, error} = Validator.resolve_inputs(workflow, %{})
    assert error.reason == :missing_required

    assert {:error, error} = Validator.resolve_inputs(workflow, %{topic: "x", other: "y"})
    assert error.reason == :unknown_key
  end

  test "enforces configured per-step parameter byte cap", %{home: home} do
    copy_fixture!("single_step", home)

    assert {:ok, _setting} =
             Settings.put("workflows.max_param_bytes_per_step", 8, %{audit?: false})

    assert {:ok, workflow} = Loader.load("single_step")

    assert {:error, error} = Validator.validate(workflow)
    assert error.reason == :cap_exceeded
    assert error.pointer == "/steps/0/params"
  end

  defp copy_fixture!(id, home) do
    File.cp!(
      Path.expand("../../fixtures/v0.44/workflows/#{id}.yaml", __DIR__),
      Path.join([home, "workflows", "#{id}.yaml"])
    )
  end

  defp restore_env(key, nil), do: System.delete_env(key)
  defp restore_env(key, value), do: System.put_env(key, value)
  defp restore_app_env(module, nil), do: Application.delete_env(:allbert_assist, module)
  defp restore_app_env(module, value), do: Application.put_env(:allbert_assist, module, value)
end
