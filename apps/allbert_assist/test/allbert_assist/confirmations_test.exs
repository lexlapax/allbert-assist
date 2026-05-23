defmodule AllbertAssist.ConfirmationsTest do
  use ExUnit.Case, async: false

  alias AllbertAssist.Confirmations
  alias AllbertAssist.Paths
  alias AllbertAssist.Settings

  @env_vars ["ALLBERT_HOME", "ALLBERT_HOME_DIR"]

  setup do
    original_env = Map.new(@env_vars, &{&1, System.get_env(&1)})
    original_paths_config = Application.get_env(:allbert_assist, Paths)
    original_settings_config = Application.get_env(:allbert_assist, Settings)
    original_confirmations_config = Application.get_env(:allbert_assist, Confirmations)

    Enum.each(@env_vars, &System.delete_env/1)
    Application.delete_env(:allbert_assist, Paths)
    Application.delete_env(:allbert_assist, Settings)
    Application.delete_env(:allbert_assist, Confirmations)

    home = temp_path("home")
    System.put_env("ALLBERT_HOME", home)

    on_exit(fn ->
      File.rm_rf!(home)
      restore_env(original_env)
      restore_app_env(Paths, original_paths_config)
      restore_app_env(Settings, original_settings_config)
      restore_app_env(Confirmations, original_confirmations_config)
    end)

    {:ok, home: home}
  end

  test "root derives from Allbert Home and creates confirmation folders", %{home: home} do
    assert Confirmations.root() == Path.join(home, "confirmations")
    assert Confirmations.ensure_root!() == Path.join(home, "confirmations")
    assert File.dir?(Path.join([home, "confirmations", "pending"]))
    assert File.dir?(Path.join([home, "confirmations", "resolved"]))
    assert File.dir?(Path.join([home, "confirmations", "audit"]))
  end

  test "create stores a redacted pending confirmation record", %{home: home} do
    assert {:ok, record} =
             Confirmations.create(base_attrs(), ttl_minutes: 10, now: now())

    id = record["id"]
    pending_path = Path.join([home, "confirmations", "pending", "#{id}.yml"])

    assert record["status"] == "pending"
    assert record["origin"]["channel"] == "cli"
    assert record["params_summary"]["api_key"] == "[REDACTED]"
    assert record["resume_params_ref"]["secret_ref"] == "[REDACTED]"
    assert File.exists?(pending_path)

    yaml = File.read!(pending_path)
    refute yaml =~ "sk-test"
    refute yaml =~ "secret://providers/openai/api_key"

    assert {:ok, ^record} = Confirmations.read(id)
    assert [^record] = Confirmations.list()

    audit = File.read!(Path.join([home, "confirmations", "audit", "2026-05.md"]))
    assert audit =~ "requested"
    assert audit =~ id
  end

  test "resolve moves pending records to resolved state and keeps channel handoff", %{home: home} do
    assert {:ok, record} = Confirmations.create(base_attrs(), now: now())
    id = record["id"]

    assert {:ok, resolved} =
             Confirmations.resolve(
               id,
               :denied,
               %{
                 resolver_actor: "local",
                 resolver_channel: :liveview,
                 resolver_surface: "/workspace",
                 resolution_reason: "not needed",
                 same_channel?: false
               },
               now: DateTime.add(now(), 60, :second)
             )

    assert resolved["status"] == "denied"
    assert resolved["operator_resolution"]["resolver_channel"] == "liveview"
    assert resolved["operator_resolution"]["same_channel?"] == false

    refute File.exists?(Path.join([home, "confirmations", "pending", "#{id}.yml"]))
    assert [_resolved] = Confirmations.list(status: :resolved)
    assert {:ok, ^resolved} = Confirmations.read(id)

    audit = File.read!(Path.join([home, "confirmations", "audit", "2026-05.md"]))
    assert audit =~ "resolver_surface: /workspace"
    assert audit =~ "same_channel: false"
    assert audit =~ "resolution_reason: not needed"
  end

  test "expire resolves only records past their ttl" do
    assert {:ok, expired} = Confirmations.create(base_attrs(), ttl_minutes: 1, now: now())

    assert {:ok, current} =
             Confirmations.create(
               Map.put(base_attrs(), :id, "conf_current"),
               ttl_minutes: 30,
               now: now()
             )

    assert {:ok, results} =
             Confirmations.expire(
               now: DateTime.add(now(), 120, :second),
               resolution_attrs: %{resolver_channel: :system, resolution_reason: "ttl expired"}
             )

    assert [{:ok, resolved}] = results
    assert resolved["id"] == expired["id"]
    assert resolved["status"] == "expired"
    assert [%{"id" => "conf_current"}] = Confirmations.list()
    assert current["status"] == "pending"
  end

  test "malformed records are rejected on read", %{home: home} do
    path = Path.join([home, "confirmations", "pending", "bad.yml"])
    File.mkdir_p!(Path.dirname(path))
    File.write!(path, "id: bad\nstatus: purple\n")

    assert {:error, {:invalid_confirmation_record, _reason}} = Confirmations.read("bad")
  end

  defp base_attrs do
    %{
      origin: %{
        actor: "local",
        channel: :cli,
        surface: "mix allbert.ask",
        session_id: "session-1",
        response_target: "stdout"
      },
      target_action: %{name: "external_network_request"},
      target_permission: :external_network,
      target_execution_mode: :external_network_unavailable,
      selected_skill: %{name: "external-network-request", trust_status: :trusted},
      capability_contract: %{action: "external_network_request", confirmation: :required},
      security_decision: %{permission: :external_network, decision: :needs_confirmation},
      source_signal_id: "sig-1",
      source_trace_id: "trace-1",
      runner_metadata: %{runner_action_id: "run-1"},
      params_summary: %{url: "https://example.com", api_key: "sk-test"},
      resume_params_ref: %{
        url: "https://example.com",
        secret_ref: "secret://providers/openai/api_key"
      }
    }
  end

  defp now, do: ~U[2026-05-02 12:00:00Z]

  defp temp_path(name) do
    Path.join(
      System.tmp_dir!(),
      "allbert-confirmations-#{name}-#{System.unique_integer([:positive])}"
    )
  end

  defp restore_env(original_env) do
    Enum.each(original_env, fn
      {key, nil} -> System.delete_env(key)
      {key, value} -> System.put_env(key, value)
    end)
  end

  defp restore_app_env(module, nil), do: Application.delete_env(:allbert_assist, module)
  defp restore_app_env(module, value), do: Application.put_env(:allbert_assist, module, value)
end
