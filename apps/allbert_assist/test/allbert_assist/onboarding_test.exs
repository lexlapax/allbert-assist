defmodule AllbertAssist.OnboardingTest do
  use AllbertAssist.DataCase, async: false

  alias AllbertAssist.CLI.FirstRun
  alias AllbertAssist.Objectives
  alias AllbertAssist.Onboarding
  alias AllbertAssist.Paths
  alias AllbertAssist.Plugin.Registry, as: PluginRegistry
  alias AllbertAssist.Settings

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
    registered_plugins = PluginRegistry.registered_plugins()
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
      restore_plugin_registry(registered_plugins, registered_diagnostics)
    end)

    :ok
  end

  test "frames one resumable onboarding objective with planned steps" do
    assert {:ok, state} = Onboarding.frame_or_resume("alice")

    assert state.created? == true
    assert state.objective.title == "First-run onboarding"
    assert state.objective.source_intent == Onboarding.source_intent()
    assert state.objective.status == "running"
    assert length(state.steps) == 9
    assert state.current_step.key == "welcome_scope"
    assert state.current_step.evidence =~ "Active model profile: local"
    assert state.current_step.next_command == "mix allbert.onboard complete welcome_scope"
    assert state.evidence.active_model_profile == "local"
    assert state.evidence.model_preferences.primary == "local"

    assert state.evidence.model_preferences.speech_to_text == [
             "voice_stt_local",
             "voice_stt_openai",
             "voice_stt_gemini"
           ]

    assert Enum.map(state.steps, & &1.index) == Enum.to_list(1..9)

    model_step = Enum.find(state.steps, &(&1.key == "pick_model_profile"))

    assert model_step.evidence =~
             "speech_to_text=[\"voice_stt_local\", \"voice_stt_openai\", \"voice_stt_gemini\"]"

    assert model_step.evidence =~
             "text_to_speech=[\"voice_tts_local\", \"voice_tts_openai\", \"voice_tts_gemini\"]"

    channel_step = Enum.find(state.steps, &(&1.key == "optional_channel_registration"))
    assert channel_step.evidence =~ "credentials="
    assert channel_step.evidence =~ "missing"
    refute channel_step.evidence =~ "%{"

    assert {:ok, resumed} = Onboarding.frame_or_resume("alice")

    assert resumed.created? == false
    assert resumed.objective.id == state.objective.id
    assert resumed.current_step.id == state.current_step.id
  end

  test "records completed and skipped onboarding progress" do
    assert {:ok, state} = Onboarding.frame_or_resume("alice")
    first = state.current_step

    assert {:ok, advanced} =
             Onboarding.complete_step("alice", state.objective.id, first.id, %{
               outcome: "completed",
               note: "scope accepted"
             })

    assert advanced.completed_step.status == "completed"
    assert advanced.current_step.key == "pick_provider_profile"
    assert advanced.objective.progress_summary =~ "1/9"

    optional =
      Enum.find(advanced.steps, &(&1.key == "optional_channel_registration"))

    assert {:ok, skipped} =
             Onboarding.complete_step("alice", state.objective.id, optional.id, %{
               outcome: "skipped"
             })

    assert skipped.completed_step.status == "skipped"

    assert {:ok, channel_state} = Onboarding.frame_or_resume("bob")

    selected_optional =
      Enum.find(channel_state.steps, &(&1.key == "optional_channel_registration"))

    assert {:ok, selected} =
             Onboarding.complete_step("bob", channel_state.objective.id, selected_optional.id, %{
               outcome: "selected"
             })

    assert selected.completed_step.status == "selected"
    assert selected.objective.progress_summary =~ "0/9"

    events = Objectives.list_events(state.objective.id, limit: 10)
    assert Enum.any?(events, &(&1.kind == "step_completed"))
    channel_events = Objectives.list_events(channel_state.objective.id, limit: 10)
    assert Enum.any?(channel_events, &(&1.kind == "step_selected"))
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

  defp ensure_channel_plugin!(module) do
    case PluginRegistry.register_module(module) do
      {:ok, _plugin_id} -> :ok
      {:error, {:plugin_id_taken, _plugin_id}} -> :ok
    end
  end

  defp restore_plugin_registry(plugins, diagnostics) do
    PluginRegistry.clear()
    Enum.each(plugins, &PluginRegistry.register_entry/1)
    Enum.each(diagnostics, &restore_plugin_diagnostics/1)
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
