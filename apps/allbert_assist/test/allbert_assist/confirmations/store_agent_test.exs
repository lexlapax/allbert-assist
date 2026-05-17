defmodule AllbertAssist.Confirmations.StoreAgentTest do
  use ExUnit.Case, async: false

  alias AllbertAssist.Confirmations.Store
  alias AllbertAssist.Confirmations.Store.Agent, as: StoreAgent
  alias AllbertAssist.Confirmations.Store.Persistence
  alias AllbertAssist.Paths
  alias AllbertAssist.Settings
  alias Jido.AgentServer

  @env_vars ["ALLBERT_HOME", "ALLBERT_HOME_DIR"]

  setup do
    original_env = Map.new(@env_vars, &{&1, System.get_env(&1)})
    original_paths_config = Application.get_env(:allbert_assist, Paths)
    original_settings_config = Application.get_env(:allbert_assist, Settings)

    Enum.each(@env_vars, &System.delete_env/1)
    Application.delete_env(:allbert_assist, Paths)
    Application.delete_env(:allbert_assist, Settings)

    home =
      Path.join(
        System.tmp_dir!(),
        "allbert-store-agent-#{System.unique_integer([:positive])}"
      )

    System.put_env("ALLBERT_HOME", home)

    on_exit(fn ->
      File.rm_rf!(home)
      restore_env(original_env)
      restore_app_env(Paths, original_paths_config)
      restore_app_env(Settings, original_settings_config)
    end)

    {:ok, home: home}
  end

  test "cold start with empty confirmation root builds an empty projection" do
    {:ok, pid} = start_test_agent()

    assert {:ok, state} = AgentServer.state(pid)
    assert state.agent.state.pending_ids == []
    assert state.agent.state.pending_by_target == %{}
    assert state.agent.state.last_command == :rebuild
  end

  test "cold start with existing pending YAML records rehydrates projection" do
    assert {:ok, first} =
             Persistence.create(base_attrs("conf_one"), now: now())

    assert {:ok, second} =
             Persistence.create(
               base_attrs("conf_two") |> put_in([:target_action, :name], "other_action"),
               now: now()
             )

    {:ok, pid} = start_test_agent()
    assert {:ok, state} = AgentServer.state(pid)

    assert Enum.sort(state.agent.state.pending_ids) == Enum.sort([first["id"], second["id"]])
    assert state.agent.state.pending_by_target["external_network_request"] == [first["id"]]
    assert state.agent.state.pending_by_target["other_action"] == [second["id"]]
  end

  test "create read list resolve and expire preserve result shapes" do
    assert {:ok, created} = Store.create(base_attrs("conf_create"), ttl_minutes: 1, now: now())
    assert {:ok, ^created} = Store.read(created["id"])
    assert [^created] = Store.list()

    assert {:ok, resolved} =
             Store.resolve(
               created["id"],
               :denied,
               %{resolver_actor: "local", resolver_channel: :cli},
               now: DateTime.add(now(), 1, :second)
             )

    assert resolved["status"] == "denied"

    assert {:ok, expired} =
             Store.create(base_attrs("conf_expire"), ttl_minutes: 1, now: now())

    assert {:ok, [{:ok, expired_resolved}]} =
             Store.expire(now: DateTime.add(now(), 120, :second))

    assert expired_resolved["id"] == expired["id"]
    assert expired_resolved["status"] == "expired"
  end

  test "restart after process crash rehydrates from confirmation files" do
    previous_trap_exit = Process.flag(:trap_exit, true)

    try do
      assert {:ok, record} = Persistence.create(base_attrs("conf_restart"), now: now())
      {:ok, pid} = start_test_agent()

      Process.exit(pid, :kill)
      ref = Process.monitor(pid)
      assert_receive {:DOWN, ^ref, :process, ^pid, _reason}
      assert_receive {:EXIT, ^pid, :killed}

      {:ok, restarted} = start_test_agent()
      assert {:ok, state} = AgentServer.state(restarted)
      assert record["id"] in state.agent.state.pending_ids
    after
      Process.flag(:trap_exit, previous_trap_exit)
    end
  end

  test "malformed pending YAML does not crash list or expire" do
    bad_path = Path.join([Store.pending_root(), "bad.yml"])
    File.mkdir_p!(Path.dirname(bad_path))
    File.write!(bad_path, "id: bad\nstatus: purple\n")

    assert [] = Store.list()
    assert {:ok, []} = Store.expire(now: DateTime.add(now(), 120, :second))
  end

  defp start_test_agent do
    StoreAgent.start_link(name: nil, id: "store-agent-test-#{System.unique_integer([:positive])}")
  end

  defp base_attrs(id) do
    %{
      id: id,
      origin: %{actor: "local", channel: :cli, surface: "mix allbert.ask"},
      target_action: %{name: "external_network_request"},
      target_permission: :external_network,
      target_execution_mode: :external_network_unavailable,
      security_decision: %{permission: :external_network, decision: :needs_confirmation},
      params_summary: %{url: "https://example.com"}
    }
  end

  defp now, do: ~U[2026-05-02 12:00:00Z]

  defp restore_env(original_env) do
    Enum.each(original_env, fn
      {key, nil} -> System.delete_env(key)
      {key, value} -> System.put_env(key, value)
    end)
  end

  defp restore_app_env(module, nil), do: Application.delete_env(:allbert_assist, module)
  defp restore_app_env(module, value), do: Application.put_env(:allbert_assist, module, value)
end
