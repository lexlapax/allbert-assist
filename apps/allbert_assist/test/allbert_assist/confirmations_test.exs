defmodule AllbertAssist.ConfirmationsTest do
  use ExUnit.Case, async: false
  @moduletag :app_env_serial

  alias AllbertAssist.Confirmations
  alias AllbertAssist.Confirmations.Record
  alias AllbertAssist.Paths
  alias AllbertAssist.Settings
  alias AllbertAssist.TestSupport.ReadyEffectContext

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
             Confirmations.create(base_attrs(), effect_context(), ttl_minutes: 10, now: now())

    id = record["id"]
    pending_path = Path.join([home, "confirmations", "pending", "#{id}.yml"])

    assert record["status"] == "pending"
    assert record["objective_binding_version"] == 2
    assert record["objective_binding_kind"] == "ordinary"
    assert record["origin"]["channel"] == "cli"
    assert record["params_summary"]["api_key"] == "[REDACTED]"
    assert record["resume_params_ref"]["secret_ref"] == "[REDACTED]"
    assert File.exists?(pending_path)

    yaml = File.read!(pending_path)
    refute yaml =~ "sk-test"
    refute yaml =~ "secret://providers/openai/api_key"

    assert {:ok, ^record} = Confirmations.read(id)
    assert [^record] = Confirmations.list()

    assert :ok =
             record
             |> Map.drop(["objective_binding_kind"])
             |> Map.put("objective_binding_version", 1)
             |> Record.validate()

    assert {:error, {:invalid_confirmation_record, {"objective_binding_version", 3}}} =
             record
             |> Map.put("objective_binding_version", 3)
             |> Record.validate()

    assert {:error, {:invalid_confirmation_record, {"objective_binding_kind", "forged"}}} =
             record
             |> Map.put("objective_binding_kind", "forged")
             |> Record.validate()

    audit = File.read!(Path.join([home, "confirmations", "audit", "2026-05.md"]))
    assert audit =~ "requested"
    assert audit =~ id
  end

  test "confirmation resume keeps only the non-secret system-integrity key reference" do
    attrs =
      Map.put(base_attrs(), :resume_params_ref, %{
        key_ref: "secret://system/integrity_v1",
        nested: %{key_ref: "secret://providers/openai/api_key"}
      })

    assert {:ok, record} = Confirmations.create(attrs, effect_context(), now: now())
    assert record["resume_params_ref"]["key_ref"] == "secret://system/integrity_v1"
    assert record["resume_params_ref"]["nested"]["key_ref"] == "[SECRET_REF]"
  end

  test "context-bound create persists trusted objective, step, and action provenance" do
    context = %{
      "user_id" => "alice",
      "objective_id" => "obj-child",
      "step_id" => "step-action",
      "parent_objective_id" => "fanout-parent",
      "objective_title" => "Bound child",
      "objective_status" => "running",
      "selected_action" => "external_network_request",
      "selected_action_module" => AllbertAssist.Actions.Intent.ExternalNetworkRequest
    }

    assert {:ok, record} = Confirmations.create(base_attrs(), effect_context(context), now: now())
    assert record["objective_id"] == "obj-child"
    assert record["step_id"] == "step-action"
    assert record["objective_binding_version"] == 2
    assert record["objective_binding_kind"] == "fanout_child"
    assert record["origin"]["parent_objective_id"] == "fanout-parent"
    assert record["origin"]["objective_id"] == "obj-child"
    assert record["target_action"]["name"] == "external_network_request"

    assert record["target_action"]["module"] ==
             "AllbertAssist.Actions.Intent.ExternalNetworkRequest"

    assert record["params_summary"]["execution_objective_id"] == "obj-child"
    assert record["params_summary"]["execution_step_id"] == "step-action"
    assert record["resume_params_ref"]["url"] == "https://example.com"
  end

  test "context-bound create rejects conflicting authority provenance" do
    context = %{
      objective_id: "obj-child",
      step_id: "step-action",
      selected_action: "external_network_request",
      selected_action_module: AllbertAssist.Actions.Intent.ExternalNetworkRequest
    }

    assert {:error, {:confirmation_binding_mismatch, :objective_id}} =
             Confirmations.create(
               Map.put(base_attrs(), :objective_id, "obj-other"),
               effect_context(context)
             )

    assert {:error, {:confirmation_binding_mismatch, :step_id}} =
             Confirmations.create(
               Map.put(base_attrs(), :step_id, "step-other"),
               effect_context(context)
             )

    assert {:error, {:confirmation_binding_mismatch, :target_action}} =
             Confirmations.create(
               put_in(base_attrs(), [:target_action, :name], "run_shell_command"),
               effect_context(context)
             )

    assert {:error, {:confirmation_binding_mismatch, :target_action_module}} =
             Confirmations.create(
               put_in(base_attrs(), [:target_action, :module], "Wrong.Module"),
               effect_context(context)
             )
  end

  test "context-bound create does not fabricate absent runner provenance" do
    assert {:ok, record} =
             Confirmations.create(
               base_attrs(),
               effect_context(%{user_id: "alice", channel: :test}),
               now: now()
             )

    assert record["objective_binding_kind"] == "ordinary"
    assert record["target_action"]["name"] == "external_network_request"
    refute Map.has_key?(record["target_action"], "module")
  end

  test "complete non-fan-out objective context is classified for durable verification" do
    assert {:ok, record} =
             Confirmations.create(
               base_attrs(),
               effect_context(%{objective_id: "obj-root", step_id: "step-root"}),
               now: now()
             )

    assert record["objective_binding_version"] == 2
    assert record["objective_binding_kind"] == "objective"
    assert record["objective_id"] == "obj-root"
    assert record["step_id"] == "step-root"
  end

  test "caller attributes cannot forge the internally derived binding kind" do
    attrs = Map.put(base_attrs(), :objective_binding_kind, "fanout_child")

    assert {:ok, record} = Confirmations.create(attrs, effect_context(), now: now())
    assert record["objective_binding_version"] == 2
    assert record["objective_binding_kind"] == "ordinary"
  end

  test "production confirmation creation has no uncarried callsites" do
    repo_root = Path.expand("../../../..", __DIR__)

    files =
      Path.wildcard(
        Path.join(repo_root, "apps/allbert_assist/lib/allbert_assist/actions/**/*.ex")
      ) ++
        Path.wildcard(Path.join(repo_root, "plugins/*/lib/**/*.ex")) ++
        [
          Path.join(repo_root, "apps/allbert_assist/lib/allbert_assist/plan_build.ex"),
          Path.join(repo_root, "apps/allbert_assist/lib/allbert_assist/runtime.ex")
        ] ++
        Path.wildcard(
          Path.join(repo_root, "apps/allbert_assist/lib/allbert_assist/plan_build/**/*.ex")
        )

    raw_sites =
      Enum.flat_map(files, fn path ->
        {:ok, ast} = path |> File.read!() |> Code.string_to_quoted(file: path)

        {_ast, sites} =
          Macro.prewalk(ast, [], fn
            {{:., meta, [{:__aliases__, _, [:Confirmations]}, :create]}, _, [_attrs]} = node,
            sites ->
              {node, [{path, meta[:line]} | sites]}

            node, sites ->
              {node, sites}
          end)

        sites
      end)

    assert raw_sites == []
  end

  test "resolve moves pending records to resolved state and keeps channel handoff", %{home: home} do
    assert {:ok, record} = Confirmations.create(base_attrs(), effect_context(), now: now())
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
               effect_context(),
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

  test "create and resolve tolerate malformed list tails in action metadata" do
    attrs =
      base_attrs()
      |> put_in([:runner_metadata, :messages], [%{api_key: "sk-runner"}, :visible | :tail])
      |> put_in([:params_summary, :resource_refs], [%{secret: "sk-param"} | :tail])

    assert {:ok, record} =
             Confirmations.create(attrs, effect_context(), ttl_minutes: 10, now: now())

    assert record["runner_metadata"]["messages"] == [
             %{"api_key" => "[REDACTED]"},
             "visible",
             "tail"
           ]

    assert record["params_summary"]["resource_refs"] == [
             %{"secret" => "[REDACTED]"},
             "tail"
           ]

    assert {:ok, resolved} =
             Confirmations.resolve(
               record["id"],
               :approved,
               %{
                 resolver_actor: "local",
                 resolver_channel: :discord,
                 target_status: "completed",
                 target_result: %{messages: [%{api_key: "sk-result"} | :tail]},
                 remembered_grants: [%{token: "sk-grant"} | :tail]
               },
               effect_context(),
               now: DateTime.add(now(), 60, :second)
             )

    assert resolved["operator_resolution"]["target_result"]["messages"] == [
             %{"api_key" => "[REDACTED]"},
             "tail"
           ]

    assert resolved["operator_resolution"]["remembered_grants"] == [
             %{"token" => "[REDACTED]"},
             "tail"
           ]
  end

  test "expire resolves only records past their ttl" do
    assert {:ok, expired} =
             Confirmations.create(base_attrs(), effect_context(), ttl_minutes: 1, now: now())

    assert {:ok, current} =
             Confirmations.create(
               Map.put(base_attrs(), :id, "conf_current"),
               effect_context(),
               ttl_minutes: 30,
               now: now()
             )

    assert {:ok, results} =
             Confirmations.expire(
               effect_context(),
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

  defp effect_context(context \\ %{}), do: ReadyEffectContext.attach(context)

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
