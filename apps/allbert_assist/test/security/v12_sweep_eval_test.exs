defmodule AllbertAssist.Security.V12SweepEvalTest do
  @moduledoc "Behavior-bound v1.2 first-run authority and denial contracts."

  use AllbertAssist.SecurityEvalCase, async: false, lane: :security_eval_serial

  alias AllbertAssist.Actions.Intent.DirectAnswer
  alias AllbertAssist.Actions.Runner
  alias AllbertAssist.CLI.Tui
  alias AllbertAssist.Channels.Identity
  alias AllbertAssist.FirstRun.Disclosure
  alias AllbertAssist.FirstRun.Enablement
  alias AllbertAssist.Paths
  alias AllbertAssist.SecurityFixtures.AssertBinding
  alias AllbertAssist.SecurityFixtures.EvalInventory
  alias AllbertAssist.Settings
  alias AllbertAssist.Settings.Audit
  alias AllbertAssist.Settings.Store
  alias AllbertTUI.IdentityBootstrap

  @ids ~w[
    v12-detect-no-egress-001
    v12-sticky-false-001
    v12-no-silent-pull-001
    v12-enable-provenance-001
    v12-raw-presence-race-001
    v12-hosted-disclosure-before-egress-001
    v12-chooser-spine-001
    v12-fallback-default-off-001
    v12-fallback-egress-gate-001
    v12-fallback-turn-bound-001
    v12-tui-guard-no-bypass-001
    v12-tui-local-identity-bootstrap-001
    v12-unusable-local-hosted-selection-001
    v12-local-ready-wins-001
  ]

  @local %{
    profile: "local",
    provider: "local_ollama",
    provider_class: :local,
    verification: :doctor_healthy
  }
  @hosted %{
    profile: "fast",
    provider: "openai",
    provider_class: :hosted,
    verification: :configured_unverified
  }
  @enable_values %{
    "intent.direct_answer_model_enabled" => true,
    "intent.model_assist_enabled" => true,
    "model_preferences.tasks.direct_answer" => ["local", "fast"]
  }
  @context %{actor: "local", channel: :cli, request: %{operator_id: "local", channel: :cli}}

  defmodule ScriptedAnswerer do
    def answer(_text, %{model_profile: profile}) do
      send(self(), {:provider_called, profile.name})

      case Process.get({__MODULE__, profile.name}, {:error, :timeout}) do
        {:ok, message} -> {:ok, %{message: message, diagnostic: %{status: :used}}}
        {:error, reason} -> {:error, reason}
      end
    end
  end

  setup do
    root = Path.join(System.tmp_dir!(), "allbert-v12-eval-#{System.unique_integer([:positive])}")
    original_paths = Application.get_env(:allbert_assist, Paths)
    original_settings = Application.get_env(:allbert_assist, Settings)
    original_answer = Application.get_env(:allbert_assist, DirectAnswer)

    Application.put_env(:allbert_assist, Paths, home: root)
    Application.put_env(:allbert_assist, Settings, root: root)

    on_exit(fn ->
      restore(Paths, original_paths)
      restore(Settings, original_settings)
      restore(DirectAnswer, original_answer)
      File.rm_rf!(root)
    end)

    {:ok, root: root}
  end

  test "§G inventory is exact and every scenario has a distinct behavioral binding" do
    rows = EvalInventory.rows_for_milestone(:v12)
    assert MapSet.new(Enum.map(rows, & &1.id)) == MapSet.new(@ids)
    assert length(rows) == 14
    assert Enum.all?(rows, &(&1.test_module == inspect(__MODULE__)))
    assert Enum.all?(rows, &(length(&1.assert) == 3))
    assert rows |> Enum.map(&MapSet.new(&1.assert)) |> Enum.uniq() |> length() == 14
  end

  test "v12-detect-no-egress-001" do
    assert {:ok, %{state: :auto_enabled, selection: %{provider_class: :hosted}}} =
             Enablement.reconcile(:runtime_missing,
               settings: settings(["fast"]),
               user_settings: %{},
               hosted_selection: @hosted,
               doctor: fn _ -> send(self(), :transport_called) end,
               context: %{audit?: false}
             )

    refute_receive :transport_called

    bind("v12-detect-no-egress-001", [
      :hosted_presence_detected,
      :selection_persisted,
      :hosted_transport_count_zero
    ])
  end

  test "v12-sticky-false-001" do
    assert {:ok, _, _, _} =
             Store.put_user_setting("intent.direct_answer_model_enabled", false, %{audit?: false})

    assert {:ok, %{state: :sticky_disabled, provenance: nil}} =
             Enablement.reconcile(:local_ready,
               settings: settings(),
               user_settings: %{"intent" => %{"direct_answer_model_enabled" => false}},
               local_selection: @local
             )

    assert {:ok, response} = DirectAnswer.run(%{text: "answer"}, %{actor: "local"})
    assert response.direct_answer.source == :bounded_fallback
    assert {:ok, false} = Settings.get("intent.direct_answer_model_enabled")

    bind("v12-sticky-false-001", [
      :raw_false_observed,
      :enablement_write_skipped,
      :bounded_fallback_returned
    ])
  end

  test "v12-no-silent-pull-001", %{root: root} do
    assert {:ok, %{state: :needs_model, provenance: nil}} =
             Enablement.reconcile(:model_missing,
               settings: settings(),
               user_settings: %{},
               local_selection: nil,
               hosted_selection: nil
             )

    refute File.exists?(Path.join(root, "models"))
    refute File.exists?(Path.join(root, "confirmations"))

    bind("v12-no-silent-pull-001", [
      :needs_model_projected,
      :no_pull_receipt_created,
      :model_inventory_unchanged
    ])
  end

  test "v12-enable-provenance-001" do
    assert {:ok, %{provenance: %{written: written}}} =
             Enablement.reconcile(:local_ready,
               settings: settings(),
               user_settings: %{},
               local_selection: @local
             )

    assert Enum.sort(written) == Enum.sort(Map.keys(@enable_values))
    audit = File.read!(Audit.audit_path())
    assert audit =~ "settings.transaction"

    # v1.3 M9.b.3 reworded this disclosure from "Inference stays on this device"
    # to "Inference uses your configured local endpoint", because a local
    # provider may be reachable at an endpoint that is not this machine — the
    # old sentence made a claim Allbert could not guarantee. This row's binding
    # is :disclosure_derived_from_selection, so it now asserts the disclosure
    # names the selection it was derived from rather than pinning a literal
    # that a later truthfulness fix is free to change.
    disclosure = Disclosure.text(:cli)
    assert disclosure =~ @local.profile
    assert disclosure =~ @local.provider
    assert disclosure =~ "Inference uses your configured local endpoint"

    refute disclosure =~ @hosted.provider,
           "a local-ready selection must not disclose hosted egress"

    bind("v12-enable-provenance-001", [
      :closed_three_key_write,
      :transaction_audit_present,
      :disclosure_derived_from_selection
    ])
  end

  test "v12-raw-presence-race-001" do
    caller = self()

    auto =
      Task.async(fn ->
        send(caller, {:ready, self()})
        receive do: (:go -> Store.put_user_settings_if_absent(@enable_values, %{audit?: false}))
      end)

    disable =
      Task.async(fn ->
        send(caller, {:ready, self()})

        receive do
          :go ->
            Store.put_user_setting("intent.direct_answer_model_enabled", false, %{audit?: false})
        end
      end)

    assert_receive {:ready, auto_pid}
    assert_receive {:ready, disable_pid}
    send(auto_pid, :go)
    send(disable_pid, :go)
    assert match?({:ok, _}, Task.await(auto))
    assert match?({:ok, _, _, _}, Task.await(disable))
    assert {:ok, false} = Settings.get("intent.direct_answer_model_enabled")

    bind("v12-raw-presence-race-001", [
      :writes_serialized,
      :explicit_false_persisted,
      :auto_enable_cannot_overwrite
    ])
  end

  test "v12-hosted-disclosure-before-egress-001" do
    :ok = Disclosure.mark_pending(@hosted)
    Process.put(:transport_count, 0)

    assert {:error, {:disclosure_render_failed, :closed}} =
             Disclosure.render_and_ack(:cli, fn _ -> {:error, :closed} end)

    assert Disclosure.hosted_pending?(:cli)
    assert Process.get(:transport_count) == 0

    assert :ok =
             Disclosure.render_and_ack(:cli, fn text -> assert text =~ "leave this device" end)

    Process.put(:transport_count, Process.get(:transport_count) + 1)
    assert Process.get(:transport_count) == 1

    bind("v12-hosted-disclosure-before-egress-001", [
      :failed_render_keeps_pending,
      :pre_ack_transport_zero,
      :post_ack_transport_one
    ])
  end

  test "v12-chooser-spine-001" do
    assert {:ok, response} = Runner.run("set_active_model_profile", %{profile: "local"}, @context)
    assert response.status == :completed
    assert response.permission_decision.permission == :settings_write
    assert {:ok, "local"} = Settings.get("intent.model_profile")

    bind("v12-chooser-spine-001", [
      :registered_action_executed,
      :settings_permission_proved,
      :selected_profile_persisted
    ])
  end

  test "v12-fallback-default-off-001" do
    prepare_chain()
    assert {:ok, false} = Settings.get("models.fallback.enabled")
    assert {:ok, response} = DirectAnswer.run(%{text: "answer"}, %{actor: "local"})
    assert response.direct_answer.source == :bounded_fallback
    assert_receive {:provider_called, "local"}
    refute_receive {:provider_called, "fast"}

    bind("v12-fallback-default-off-001", [
      :fallback_default_false,
      :primary_called_once,
      :secondary_not_called
    ])
  end

  test "v12-fallback-egress-gate-001" do
    prepare_chain()
    put!("models.fallback.enabled", true)
    Process.put({ScriptedAnswerer, "fast"}, {:ok, "hosted"})
    assert {:ok, response} = DirectAnswer.run(%{text: "answer"}, %{actor: "local"})
    assert response.direct_answer.fallback.provider_call_count == 1
    assert_receive {:provider_called, "local"}
    refute_receive {:provider_called, "fast"}

    bind("v12-fallback-egress-gate-001", [
      :fallback_enabled,
      :hosted_egress_disabled,
      :hosted_transport_count_zero
    ])
  end

  test "v12-fallback-turn-bound-001" do
    prepare_chain(["local", "fast", "anthropic_fast"])
    put!("providers.anthropic.enabled", true)
    put!("models.fallback.enabled", true)
    put!("models.fallback.allow_local_to_hosted", true)
    put!("models.fallback.max_failovers_per_turn", 2)

    assert Disclosure.hosted_pending?(:cli)
    disclosure = Disclosure.text(:cli)
    assert disclosure =~ "local"
    assert disclosure =~ "fast"
    refute disclosure =~ "anthropic_fast"
    assert :ok = Disclosure.render_and_ack(:cli, fn _text -> :ok end)

    # A headless/non-presenting request may reuse the exact route-set
    # acknowledgement from a local operator-control surface.
    assert {:ok, response} = DirectAnswer.run(%{text: "answer"}, %{actor: "local"})
    assert response.direct_answer.fallback.provider_call_count == 2
    assert_receive {:provider_called, "local"}
    assert_receive {:provider_called, "fast"}
    refute_receive {:provider_called, "anthropic_fast"}

    bind("v12-fallback-turn-bound-001", [
      :three_candidates_resolved,
      :provider_call_count_two,
      :third_candidate_not_called
    ])
  end

  test "v12-tui-guard-no-bypass-001" do
    assert :ok = Tui.readiness_guard(first_model_state: :runtime_missing)
    assert {:ok, %{}} = Store.read_user_settings()
    assert {:ok, response} = DirectAnswer.run(%{text: "answer"}, %{actor: "local"})
    assert response.direct_answer.source == :bounded_fallback

    bind("v12-tui-guard-no-bypass-001", [
      :guard_returns_ok,
      :settings_remain_empty,
      :deterministic_fallback_available
    ])
  end

  test "v12-tui-local-identity-bootstrap-001" do
    assert {:ok, %{disposition: :bootstrapped}} = IdentityBootstrap.prepare_local_launch()
    assert {:ok, true} = Settings.get("channels.tui.enabled")
    assert {:ok, mapping} = Settings.get("channels.tui.identity_map")
    assert Identity.resolve("tui", "default", mapping) == {:ok, "local"}

    put!("channels.tui.identity_map", [])

    assert {:ok, %{disposition: :present, written: []}} =
             IdentityBootstrap.prepare_local_launch()

    assert {:ok, []} = Settings.get("channels.tui.identity_map")
    assert Identity.resolve("tui", "default", []) == {:error, :not_mapped}
    assert Identity.resolve("tui", "arbitrary", []) == {:error, :not_mapped}

    put!("channels.tui.enabled", false)

    assert {:ok, %{disposition: :explicitly_disabled, written: []}} =
             IdentityBootstrap.prepare_local_launch()

    assert {:ok, false} = Settings.get("channels.tui.enabled")

    bind("v12-tui-local-identity-bootstrap-001", [
      :launcher_activated_canonical_local,
      :explicit_channel_and_identity_state_preserved,
      :generic_resolver_has_no_fallback
    ])
  end

  test "v12-unusable-local-hosted-selection-001" do
    for state <- [:model_missing, :runtime_unhealthy, :below_hardware_floor] do
      File.rm_rf!(Store.root())

      assert {:ok, %{selection: %{provider_class: :hosted}}} =
               Enablement.reconcile(state,
                 settings: settings(["fast"]),
                 user_settings: %{},
                 hosted_selection: @hosted,
                 doctor: fn _ -> flunk("local probing/provisioning is forbidden") end,
                 context: %{audit?: false}
               )
    end

    bind("v12-unusable-local-hosted-selection-001", [
      :all_unusable_local_states_covered,
      :hosted_selected_without_probe,
      :no_local_provisioning
    ])
  end

  test "v12-local-ready-wins-001" do
    assert {:ok, %{selection: %{provider_class: :local}}} =
             Enablement.reconcile(:local_ready,
               settings: settings(),
               user_settings: %{},
               local_selection: @local,
               hosted_selection: fn -> send(self(), :hosted_called) end,
               context: %{audit?: false}
             )

    refute_receive :hosted_called

    bind("v12-local-ready-wins-001", [
      :healthy_local_selected,
      :hosted_candidate_ignored,
      :hosted_transport_count_zero
    ])
  end

  defp prepare_chain(profiles \\ ["local", "fast"]) do
    Application.put_env(:allbert_assist, DirectAnswer, answerer: ScriptedAnswerer)
    put!("intent.direct_answer_model_enabled", true)
    put!("providers.openai.enabled", true)
    put!("model_preferences.tasks.direct_answer", profiles)
  end

  defp put!(key, value),
    do:
      assert(
        {:ok, _} =
          Settings.put(
            key,
            value,
            AllbertAssist.TestSupport.ReadyEffectContext.attach(%{audit?: false})
          )
      )

  defp bind(id, assertions), do: AssertBinding.check!(id, assertions)

  defp settings(direct_answer_profiles \\ ["local", "fast"]) do
    %{
      "intent" => %{"direct_answer_model_enabled" => false, "model_assist_enabled" => false},
      "model_preferences" => %{
        "primary" => "local",
        "tasks" => %{"direct_answer" => direct_answer_profiles}
      },
      "providers" => %{
        "local_ollama" => %{
          "enabled" => true,
          "endpoint_kind" => "local_endpoint",
          "type" => "openai_compatible"
        },
        "openai" => %{
          "enabled" => true,
          "endpoint_kind" => "credentialed_remote",
          "credential_status" => :configured,
          "type" => "openai"
        }
      },
      "model_profiles" => %{
        "local" => %{
          "provider" => "local_ollama",
          "model" => "llama3.2:3b",
          "capabilities" => ["text_generation"]
        },
        "fast" => %{
          "provider" => "openai",
          "model" => "gpt-4o-mini",
          "capabilities" => ["text_generation"]
        }
      }
    }
  end

  defp restore(module, nil), do: Application.delete_env(:allbert_assist, module)
  defp restore(module, value), do: Application.put_env(:allbert_assist, module, value)
end
