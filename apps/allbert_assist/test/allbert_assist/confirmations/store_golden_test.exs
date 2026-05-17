defmodule AllbertAssist.Confirmations.StoreGoldenTest do
  use ExUnit.Case, async: false

  alias AllbertAssist.Confirmations.Store
  alias AllbertAssist.Paths
  alias AllbertAssist.Settings

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
        "allbert-store-golden-#{System.unique_integer([:positive])}"
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

  test "requested audit markdown keeps the v0.22 canonical shape", %{home: home} do
    assert {:ok, _record} = Store.create(base_attrs(), now: now())

    assert File.read!(Path.join([home, "confirmations", "audit", "2026-05.md"])) ==
             """

             ## 2026-05-02T12:00:00Z conf_golden

             - event: requested
             - status: pending
             - target_action: external_network_request
             - target_permission: external_network
             - origin_actor: local
             - origin_channel: cli
             - resolver_actor: none
             - resolver_channel: none
             - resolver_surface: none
             - same_channel: none
             - resolution_reason: none
             - decision_source: none
             - source_trace_id: trace-golden
             - target_url: https://example.com
             - audit_version: 1
             """
  end

  test "resolution audit markdown appends the v0.22 canonical fields", %{home: home} do
    assert {:ok, record} = Store.create(base_attrs(), now: now())

    assert {:ok, _resolved} =
             Store.resolve(
               record["id"],
               :denied,
               %{
                 resolver_actor: "local",
                 resolver_channel: :liveview,
                 resolver_surface: "/settings",
                 resolution_reason: "golden denial",
                 same_channel?: false
               },
               now: DateTime.add(now(), 60, :second)
             )

    audit = File.read!(Path.join([home, "confirmations", "audit", "2026-05.md"]))

    assert audit =~ "- event: denied\n"
    assert audit =~ "- status: denied\n"
    assert audit =~ "- resolver_channel: liveview\n"
    assert audit =~ "- resolver_surface: /settings\n"
    assert audit =~ "- same_channel: false\n"
    assert audit =~ "- resolution_reason: golden denial\n"
    assert audit =~ "- audit_version: 1\n"
  end

  defp base_attrs do
    %{
      id: "conf_golden",
      origin: %{actor: "local", channel: :cli, surface: "mix allbert.ask"},
      target_action: %{name: "external_network_request"},
      target_permission: :external_network,
      target_execution_mode: :external_network_unavailable,
      security_decision: %{permission: :external_network, decision: :needs_confirmation},
      source_trace_id: "trace-golden",
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
