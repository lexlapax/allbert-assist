defmodule AllbertAssist.Confirmations.EffectGuardPersistenceTest do
  use ExUnit.Case, async: false

  @moduletag :app_env_serial

  alias AllbertAssist.Confirmations
  alias AllbertAssist.Confirmations.Store
  alias AllbertAssist.Confirmations.Store.Agent, as: StoreAgent
  alias AllbertAssist.Pack.EffectGuard
  alias AllbertAssist.Paths
  alias AllbertAssist.Settings
  alias AllbertAssist.TestSupport.ReadyEffectContext
  alias Jido.AgentServer

  setup do
    home =
      Path.join(
        System.tmp_dir!(),
        "allbert-confirmation-effect-#{System.unique_integer([:positive])}"
      )

    previous_env =
      Map.new(["ALLBERT_HOME", "ALLBERT_HOME_DIR"], fn key -> {key, System.get_env(key)} end)

    previous_app_env =
      Map.new([Paths, Settings, Confirmations], fn module ->
        {module, Application.get_env(:allbert_assist, module)}
      end)

    System.put_env("ALLBERT_HOME", home)
    System.delete_env("ALLBERT_HOME_DIR")
    Enum.each(Map.keys(previous_app_env), &Application.delete_env(:allbert_assist, &1))

    on_exit(fn ->
      File.rm_rf!(home)

      Enum.each(previous_env, fn
        {key, nil} -> System.delete_env(key)
        {key, value} -> System.put_env(key, value)
      end)

      Enum.each(previous_app_env, fn
        {module, nil} -> Application.delete_env(:allbert_assist, module)
        {module, value} -> Application.put_env(:allbert_assist, module, value)
      end)
    end)

    %{home: home}
  end

  test "missing, malformed, and activation carriers do not dispatch or write", %{home: home} do
    before_projection = projection_snapshot()

    for context <- [%{}, %{allbert_pack_epoch: %{}}, %{allbert_pack_activation: :boot_only}] do
      assert {:error, :product_not_ready} = Store.create(attrs("blocked"), context, now: now())
    end

    refute File.exists?(Path.join(home, "confirmations"))
    assert projection_snapshot() == before_projection
  end

  test "create restores exact preimages after same-digest replacement", %{home: home} do
    {context, barrier} = ready_context()
    snapshot = confirmation_snapshot(home)

    assert {:error, :stale_epoch} =
             Store.create(
               attrs("create-race"),
               context,
               now: now(),
               stage_hook: fn 1 -> ReadyEffectContext.replace(barrier) end
             )

    assert confirmation_snapshot(home) == snapshot
  end

  test "resolve restores pending, resolved, and audit preimages after replacement", %{home: home} do
    {create_context, _barrier} = ready_context()
    assert {:ok, record} = Store.create(attrs("resolve-race"), create_context, now: now())
    {context, barrier} = ready_context()
    snapshot = confirmation_snapshot(home)

    assert {:error, :stale_epoch} =
             Store.resolve(
               record["id"],
               :denied,
               %{resolver_actor: "operator"},
               context,
               now: DateTime.add(now(), 1, :second),
               stage_hook: fn 1 -> ReadyEffectContext.replace(barrier) end
             )

    assert confirmation_snapshot(home) == snapshot
  end

  test "annotate restores exact resolved and audit preimages after replacement", %{home: home} do
    {create_context, _barrier} = ready_context()
    assert {:ok, pending} = Store.create(attrs("annotate-race"), create_context, now: now())
    {resolve_context, _barrier} = ready_context()

    assert {:ok, record} =
             Store.resolve(
               pending["id"],
               :approved,
               %{resolver_actor: "operator"},
               resolve_context,
               now: DateTime.add(now(), 1, :second)
             )

    {context, barrier} = ready_context()
    snapshot = confirmation_snapshot(home)

    assert {:error, :stale_epoch} =
             Store.annotate_resolution(
               record["id"],
               %{target_status: "completed"},
               context,
               now: DateTime.add(now(), 2, :second),
               stage_hook: fn 1 -> ReadyEffectContext.replace(barrier) end
             )

    assert confirmation_snapshot(home) == snapshot
  end

  test "expire is a compensated batch, never a partial same-digest transition", %{home: home} do
    {create_context, _barrier} = ready_context()

    assert {:ok, _first} =
             Store.create(attrs("expire-one"), create_context, now: now(), ttl_minutes: 1)

    {create_context, _barrier} = ready_context()

    assert {:ok, _second} =
             Store.create(attrs("expire-two"), create_context, now: now(), ttl_minutes: 1)

    {context, barrier} = ready_context()
    snapshot = confirmation_snapshot(home)

    assert {:error, :stale_epoch} =
             Store.expire(
               context,
               now: DateTime.add(now(), 120, :second),
               stage_hook: fn index -> if index == 2, do: ReadyEffectContext.replace(barrier) end
             )

    assert confirmation_snapshot(home) == snapshot
  end

  test "normal carried create, resolve, annotation, and expiration preserve result semantics" do
    {context, _barrier} = ready_context()

    assert {:ok, pending} =
             Store.create(attrs("normal-resolve"), context, now: now(), ttl_minutes: 1)

    {context, _barrier} = ready_context()

    assert {:ok, resolved} =
             Store.resolve(pending["id"], :denied, %{resolver_channel: :cli}, context,
               now: DateTime.add(now(), 1, :second)
             )

    assert resolved["status"] == "denied"
    {context, _barrier} = ready_context()

    assert {:ok, annotated} =
             Store.annotate_resolution(resolved["id"], %{target_status: "cancelled"}, context,
               now: DateTime.add(now(), 2, :second)
             )

    assert annotated["operator_resolution"]["target_status"] == "cancelled"
    {context, _barrier} = ready_context()

    assert {:ok, expiring} =
             Store.create(attrs("normal-expire"), context, now: now(), ttl_minutes: 1)

    {context, _barrier} = ready_context()

    assert {:ok, [{:ok, expired}]} = Store.expire(context, now: DateTime.add(now(), 120, :second))
    assert expired["id"] == expiring["id"]
    assert expired["status"] == "expired"
  end

  test "empty expiry is a no-op and does not create an audit file", %{home: home} do
    {context, _barrier} = ready_context()

    assert {:ok, []} = Store.expire(context, now: now())
    refute File.exists?(Path.join([home, "confirmations", "audit", "2026-08.md"]))
  end

  defp ready_context do
    {:ok, barrier} = ReadyEffectContext.start_link([])
    {:ok, epoch} = EffectGuard.admit_ready(server: barrier)

    {%{allbert_pack_epoch: epoch, allbert_pack_effect_guard_opts: [server: barrier]}, barrier}
  end

  defp confirmation_snapshot(home) do
    home
    |> Path.join("confirmations/**/*")
    |> Path.wildcard()
    |> Enum.reject(&File.dir?/1)
    |> Enum.map(&{Path.relative_to(&1, home), File.read!(&1)})
    |> Map.new()
  end

  defp projection_snapshot do
    case Process.whereis(StoreAgent) do
      nil ->
        :not_started

      pid ->
        case AgentServer.state(pid) do
          {:ok, state} -> state.agent.state
          _other -> :unavailable
        end
    end
  end

  defp attrs(id) do
    %{
      id: "conf_#{id}",
      origin: %{actor: "operator", channel: :cli},
      target_action: %{name: "external_network_request"},
      target_permission: :external_network,
      target_execution_mode: :external_network_unavailable,
      security_decision: %{permission: :external_network, decision: :needs_confirmation},
      params_summary: %{url: "https://example.com"}
    }
  end

  defp now, do: ~U[2026-08-07 12:00:00Z]
end
