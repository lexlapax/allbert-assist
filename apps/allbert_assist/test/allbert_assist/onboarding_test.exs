defmodule AllbertAssist.OnboardingTest do
  use AllbertAssist.DataCase, async: false

  alias AllbertAssist.CLI.FirstRun
  alias AllbertAssist.Objectives
  alias AllbertAssist.Onboarding
  alias AllbertAssist.Paths
  alias AllbertAssist.Personas
  alias AllbertAssist.Plugin.Registry, as: PluginRegistry
  alias AllbertAssist.Settings
  alias AllbertAssist.TestSupport.ShippedRegistries

  @env_vars [
    "ALLBERT_HOME",
    "ALLBERT_HOME_DIR",
    "ALLBERT_SETTINGS_ROOT",
    "ALLBERT_SETTINGS_MASTER_KEY"
  ]

  setup do
    original_env = Map.new(@env_vars, &{&1, System.get_env(&1)})
    original_paths_config = Application.get_env(:allbert_assist, Paths)
    original_settings_config = Application.get_env(:allbert_assist, Settings)
    registered_diagnostics = PluginRegistry.diagnostics()

    Enum.each(@env_vars, &System.delete_env/1)
    Application.delete_env(:allbert_assist, Paths)
    Application.delete_env(:allbert_assist, Settings)

    home =
      Path.join(
        System.tmp_dir!(),
        "allbert-onboarding-#{System.unique_integer([:positive])}"
      )

    System.put_env("ALLBERT_HOME", home)

    ensure_channel_plugin!(AllbertAssist.Plugins.Telegram)
    ensure_channel_plugin!(AllbertAssist.Plugins.Email)

    on_exit(fn ->
      File.rm_rf!(home)
      restore_env(original_env)
      restore_app_env(Paths, original_paths_config)
      restore_app_env(Settings, original_settings_config)
      ShippedRegistries.restore!()
      Enum.each(registered_diagnostics, &restore_plugin_diagnostics/1)
    end)

    :ok
  end

  describe "v0.63 M1 guided-wizard state machine" do
    test "starts a track, advances the canonical 8 steps, and unifies completion on the marker" do
      state = Onboarding.wizard_start(:quickstart)
      assert state.started? and state.track == :quickstart
      assert state.step == "welcome"

      assert Onboarding.wizard_steps() ==
               ~w(welcome track_select model_path profile_select profile_review
                  health_check first_chat optional_connect)

      # Advance through to first_chat; QuickStart defers optional_connect.
      state =
        ~w(welcome track_select model_path profile_select)
        |> Enum.reduce(state, fn step, _acc ->
          assert {:ok, s} = Onboarding.wizard_advance(step)
          s
        end)

      assert state.step == "profile_review"
      refute state.profile_reviewed?

      assert {:ok, state} = Onboarding.wizard_advance("profile_review")
      assert state.profile_reviewed?
      assert state.step == "health_check"

      assert {:ok, state} = Onboarding.wizard_advance("health_check")
      assert state.step == "first_chat"
      refute state.complete?

      # Reaching first useful chat completes onboarding (optional_connect deferred).
      assert {:ok, state} = Onboarding.wizard_advance("first_chat")
      assert state.complete?
      assert FirstRun.read_marker()["onboarding_complete"] == true
    end

    test "advancing a non-current step is rejected" do
      Onboarding.wizard_start(:advanced)
      assert {:error, {:not_current_step, "welcome"}} = Onboarding.wizard_advance("model_path")
      assert {:error, {:unknown_step, "nope"}} = Onboarding.wizard_advance("nope")
    end

    test "reset clears the marker and returns a fresh state" do
      Onboarding.wizard_start(:quickstart)
      assert {:ok, _} = Onboarding.wizard_advance("welcome")
      state = Onboarding.wizard_reset()
      refute state.started?
      assert state.step == "welcome"
      assert FirstRun.read_marker() == %{}
    end

    test "readiness_label maps probe states per the contract (no :blocked)" do
      assert Onboarding.readiness_label(first_model_state: :local_ready) == :ready
      assert Onboarding.readiness_label(first_model_state: :byok_ready) == :ready
      assert Onboarding.readiness_label(first_model_state: :runtime_missing) == :needs_runtime
      assert Onboarding.readiness_label(first_model_state: :runtime_unhealthy) == :needs_runtime
      assert Onboarding.readiness_label(first_model_state: :model_missing) == :needs_model
      assert Onboarding.readiness_label(first_model_state: :below_hardware_floor) == :needs_review
    end
  end

  describe "v0.63 M8.5 QuickStart reaches a working first chat (no-dead-end enablement)" do
    test "model_path completing with a ready model enables model-backed answers" do
      Onboarding.wizard_start(:quickstart)
      assert {:ok, _} = Onboarding.wizard_advance("welcome")
      assert {:ok, _} = Onboarding.wizard_advance("track_select")

      # A ready model at model_path flips the gate so `allbert ask` works without a
      # manual settings edit (the operator-reported dead end).
      assert {:ok, s} =
               Onboarding.wizard_advance("model_path", %{}, first_model_state: :local_ready)

      assert s.readiness == :ready
      assert Settings.get("intent.direct_answer_model_enabled") == {:ok, true}
      # F5 Q1: a ready model also turns on model-assisted intent classification.
      assert Settings.get("intent.model_assist_enabled") == {:ok, true}
    end

    test "a non-ready model_path leaves model answers disabled (no dead model enabled)" do
      Onboarding.wizard_start(:quickstart)
      assert {:ok, _} = Onboarding.wizard_advance("welcome")
      assert {:ok, _} = Onboarding.wizard_advance("track_select")

      assert {:ok, s} =
               Onboarding.wizard_advance("model_path", %{}, first_model_state: :runtime_missing)

      assert s.readiness == :needs_runtime
      refute Settings.get("intent.direct_answer_model_enabled") == {:ok, true}
    end

    test "every persona also seeds the model-answer flag (belt-and-suspenders)" do
      for id <- ~w(general developer writer researcher ops) do
        {:ok, persona} = Personas.fetch(id)
        seeds = Map.new(Personas.settings_seeds(persona))
        assert seeds["intent.direct_answer_model_enabled"] == true
      end
    end
  end

  describe "v0.63 M7.1 Advanced-track completion + step consistency" do
    test "Advanced completes on optional_connect (the track's last step), not first_chat" do
      Onboarding.wizard_start(:advanced)

      state =
        ~w(welcome track_select model_path profile_select profile_review health_check)
        |> Enum.reduce(nil, fn step, _ ->
          assert {:ok, s} = Onboarding.wizard_advance(step)
          s
        end)

      assert state.step == "first_chat"

      # first_chat is NOT the last step in Advanced → not complete yet, and the
      # optional_connect step stays reachable (current == optional_connect after it).
      assert {:ok, state} = Onboarding.wizard_advance("first_chat")
      refute state.complete?
      assert state.step == "optional_connect"

      assert {:ok, state} = Onboarding.wizard_advance("optional_connect")
      assert state.complete?
      assert state.step == "optional_connect"
      assert FirstRun.read_marker()["onboarding_complete"] == true
    end

    test "QuickStart never derives optional_connect and stays consistent when complete" do
      state = Onboarding.wizard_start(:quickstart)

      state =
        ~w(welcome track_select model_path profile_select profile_review health_check first_chat)
        |> Enum.reduce(state, fn step, acc ->
          refute acc.step == "optional_connect"
          assert {:ok, s} = Onboarding.wizard_advance(step)
          s
        end)

      # Complete on first_chat (QuickStart's last step); step never becomes optional_connect.
      assert state.complete?
      assert state.step == "first_chat"
    end
  end

  describe "v0.63 M7.4 first-chat prompts" do
    test "first_chat_prompts uses the applied persona plus the launch-path local-knowledge set" do
      # No applied persona → general prompts + the v0.65 M5 local-knowledge set.
      prompts = Onboarding.first_chat_prompts()

      assert prompts ==
               Enum.uniq(
                 Personas.first_chat_prompts("general") ++ Onboarding.local_knowledge_prompts()
               )

      refute prompts == []

      # The launch-path local-knowledge prompts always surface, regardless of persona.
      assert "Ask about my notes" in prompts
      assert "Remember this after review" in prompts
      assert "Show what you remember" in prompts

      Onboarding.record_applied_persona("developer")
      assert Onboarding.applied_persona() == "developer"

      dev_prompts = Onboarding.first_chat_prompts()

      assert dev_prompts ==
               Enum.uniq(
                 Personas.first_chat_prompts("developer") ++ Onboarding.local_knowledge_prompts()
               )

      assert "Ask about my notes" in dev_prompts
    end
  end

  describe "v0.63 M7.6 first-launch reconcile" do
    test "cancels a stale in-flight onboarding objective once, idempotently" do
      # A leftover v0.62 onboarding objective (created directly — the framing flow is
      # retired). The reconcile identifies it by its source_intent.
      assert {:ok, objective} =
               Objectives.create_objective(%{
                 user_id: "alice",
                 status: "open",
                 title: "First-run onboarding",
                 objective: "legacy",
                 active_app: "allbert",
                 source_intent: "first_run_onboarding"
               })

      objective_id = objective.id

      assert :ok = Onboarding.reconcile_stale_objective(user_id: "alice")
      assert {:ok, objective} = Objectives.get_objective("alice", objective_id)
      assert objective.status == "cancelled"
      assert FirstRun.read_marker()["objective_reconciled_v063"] == true

      # Idempotent: a second call is a no-op (flag already set).
      assert :ok = Onboarding.reconcile_stale_objective(user_id: "alice")
    end

    test "a fresh Home with no stale objective records the flag without error" do
      assert :ok = Onboarding.reconcile_stale_objective(user_id: "bob")
      assert FirstRun.read_marker()["objective_reconciled_v063"] == true
    end
  end

  describe "v0.63 M7.2 guarded / injectable readiness" do
    @model_states ~w(local_ready byok_ready runtime_missing runtime_unhealthy
                     model_missing below_hardware_floor)a

    test "safe_first_model_state returns a valid state and never raises" do
      assert Onboarding.safe_first_model_state() in @model_states
    end

    test "an injected probe is honored without evaluating the live probe (get_lazy)" do
      assert Onboarding.readiness_label(first_model_state: :model_missing) == :needs_model

      assert Onboarding.model_path_guidance(first_model_state: :below_hardware_floor).readiness ==
               :needs_review
    end
  end

  describe "v0.63 M2 track-aware model_path guidance" do
    @all_probes ~w(local_ready byok_ready runtime_missing runtime_unhealthy
                   model_missing below_hardware_floor)a

    test "ready probes reach chat; every other probe is repairable with a concrete action" do
      for probe <- @all_probes, track <- [:quickstart, :advanced] do
        g = Onboarding.model_path_guidance(first_model_state: probe, track: track)

        if g.reaches_chat? do
          assert probe in [:local_ready, :byok_ready]
          assert g.action == :start_chat
        else
          # No dead ends: every non-ready outcome offers a specific repair action.
          assert g.repairable?
          assert g.action in [:install_runtime, :pull_model, :choose_provider]
          assert g.next_action =~ ~r/\S/
        end
      end
    end

    test "operator copy never leaks a raw probe atom or internal readiness atom" do
      for probe <- @all_probes, track <- [:quickstart, :advanced] do
        g = Onboarding.model_path_guidance(first_model_state: probe, track: track)
        blob = g.headline <> " " <> g.next_action

        for atom <- ~w(local_ready byok_ready runtime_missing runtime_unhealthy
                       model_missing below_hardware_floor needs_runtime needs_model
                       needs_review) do
          refute blob =~ atom, "leaked #{atom} in: #{blob}"
        end
      end
    end

    test "each readiness label maps to exactly one routed action" do
      assert Onboarding.model_guidance_for(:ready, :quickstart).action == :start_chat
      assert Onboarding.model_guidance_for(:needs_runtime, :quickstart).action == :install_runtime
      assert Onboarding.model_guidance_for(:needs_model, :quickstart).action == :pull_model
      assert Onboarding.model_guidance_for(:needs_review, :quickstart).action == :choose_provider
    end

    test "Advanced surfaces an extra provider/model affordance QuickStart omits" do
      qs = Onboarding.model_guidance_for(:needs_runtime, :quickstart)
      adv = Onboarding.model_guidance_for(:needs_runtime, :advanced)
      assert adv.next_action =~ "Advanced:"
      refute qs.next_action =~ "Advanced:"
      # Same routed action; Advanced only adds the choice affordance.
      assert qs.action == adv.action
    end
  end

  describe "v1.0 R2 wizard rewind" do
    test "first_chat_ready? requires both a ready model and enabled direct answers" do
      refute Onboarding.first_chat_ready?(%{readiness: :needs_model})
      refute Onboarding.first_chat_ready?(%{readiness: :ready})

      assert {:ok, _setting} =
               Settings.put("intent.direct_answer_model_enabled", true, %{audit?: false})

      assert Onboarding.first_chat_ready?(%{readiness: :ready})
      refute Onboarding.first_chat_ready?(%{readiness: :needs_runtime})
    end

    test "rewinding to an earlier done step truncates done and makes it current" do
      Onboarding.wizard_start(:quickstart)

      for step <- ~w(welcome track_select model_path) do
        assert {:ok, _} = Onboarding.wizard_advance(step)
      end

      assert {:ok, state} = Onboarding.wizard_rewind("track_select")
      assert state.step == "track_select"
      assert state.done == ["welcome"]
      assert state.next == "model_path"
      assert FirstRun.read_marker()["wizard_step"] == "track_select"
    end

    test "rewinding past profile_review clears the profile-reviewed state" do
      Onboarding.wizard_start(:quickstart)

      for step <- ~w(welcome track_select model_path profile_select profile_review) do
        assert {:ok, _} = Onboarding.wizard_advance(step)
      end

      assert FirstRun.read_marker()["profile_reviewed"] == true

      assert {:ok, state} = Onboarding.wizard_rewind("model_path")
      refute state.profile_reviewed?
      assert state.step == "model_path"
      assert state.done == ~w(welcome track_select)
    end

    test "rewinding to a step after profile_review keeps the profile-reviewed state" do
      Onboarding.wizard_start(:quickstart)

      for step <- ~w(welcome track_select model_path profile_select profile_review health_check) do
        assert {:ok, _} = Onboarding.wizard_advance(step)
      end

      assert {:ok, state} = Onboarding.wizard_rewind("health_check")
      assert state.profile_reviewed?
      assert state.step == "health_check"
    end

    test "rewinding after completion clears complete? but never revokes intent enablement" do
      Onboarding.wizard_start(:quickstart)
      assert {:ok, _} = Onboarding.wizard_advance("welcome")
      assert {:ok, _} = Onboarding.wizard_advance("track_select")

      assert {:ok, _} =
               Onboarding.wizard_advance("model_path", %{}, first_model_state: :local_ready)

      for step <- ~w(profile_select profile_review health_check first_chat) do
        assert {:ok, _} = Onboarding.wizard_advance(step)
      end

      assert FirstRun.read_marker()["onboarding_complete"] == true
      assert Settings.get("intent.direct_answer_model_enabled") == {:ok, true}

      assert {:ok, state} = Onboarding.wizard_rewind("first_chat")
      refute state.complete?
      assert state.step == "first_chat"
      assert FirstRun.read_marker()["onboarding_complete"] == false

      # Rewind is navigation, not consent revocation.
      assert Settings.get("intent.direct_answer_model_enabled") == {:ok, true}
      assert Settings.get("intent.model_assist_enabled") == {:ok, true}
    end

    test "rewind rejects unknown steps, not-yet-done steps, and off-track steps" do
      Onboarding.wizard_start(:quickstart)
      assert {:ok, _} = Onboarding.wizard_advance("welcome")

      assert {:error, {:unknown_step, "nope"}} = Onboarding.wizard_rewind("nope")

      assert {:error, {:not_rewindable, "health_check"}} =
               Onboarding.wizard_rewind("health_check")

      # QuickStart never includes optional_connect.
      assert {:error, {:not_rewindable, "optional_connect"}} =
               Onboarding.wizard_rewind("optional_connect")

      # The current step itself is not rewindable (nothing to rewind past).
      assert {:error, {:not_rewindable, "track_select"}} =
               Onboarding.wizard_rewind("track_select")
    end
  end

  describe "v1.0 R3 step-aware trust guidance" do
    test "every wizard step yields non-empty guidance plus a trust-spine subset" do
      for step <- Onboarding.wizard_steps() do
        guidance = Onboarding.step_guidance(step)
        assert guidance.guidance =~ ~r/\S/
        assert guidance.trust_lines != []
        assert Enum.all?(guidance.trust_lines, &(&1 in Onboarding.trust_spine()))
      end
    end

    test "each step surfaces the safety properties it exercises" do
      expectations = %{
        "welcome" => ["Confirmation:", "Permission:"],
        "track_select" => ["Local-first:"],
        "model_path" => ["Local-first:", "Hosted-provider egress:"],
        "profile_select" => ["Permission:"],
        "profile_review" => ["Permission:"],
        "health_check" => ["Traces:"],
        "first_chat" => ["Confirmation:", "Memory review:"],
        "optional_connect" => ["Hosted-provider egress:", "Secrets:"]
      }

      for {step, prefixes} <- expectations do
        lines = Onboarding.step_guidance(step).trust_lines
        assert length(lines) == length(prefixes)

        for prefix <- prefixes do
          assert Enum.any?(lines, &String.starts_with?(&1, prefix)),
                 "expected #{step} to surface #{prefix}"
        end
      end
    end

    test "the terminal trust_spine/0 surface is unchanged (all seven properties)" do
      spine = Onboarding.trust_spine()
      assert length(spine) == 7

      for prefix <- [
            "Confirmation:",
            "Permission:",
            "Traces:",
            "Local-first:",
            "Hosted-provider egress:",
            "Secrets:",
            "Memory review:"
          ] do
        assert Enum.any?(spine, &String.starts_with?(&1, prefix))
      end
    end
  end

  defp ensure_channel_plugin!(module) do
    case PluginRegistry.register_module(module) do
      {:ok, _plugin_id} -> :ok
      {:error, {:plugin_id_taken, _plugin_id}} -> :ok
    end
  end

  defp restore_plugin_diagnostics({plugin_id, diagnostics}) do
    PluginRegistry.put_diagnostics(plugin_id, diagnostics)
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
