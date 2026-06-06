defmodule AllbertAssist.OnboardingTest do
  use AllbertAssist.DataCase, async: false

  alias AllbertAssist.Objectives
  alias AllbertAssist.Onboarding
  alias AllbertAssist.Plugin.Registry, as: PluginRegistry

  setup do
    registered_plugins = PluginRegistry.registered_plugins()
    registered_diagnostics = PluginRegistry.diagnostics()

    ensure_channel_plugin!(AllbertAssist.Plugins.Telegram)
    ensure_channel_plugin!(AllbertAssist.Plugins.Email)

    on_exit(fn -> restore_plugin_registry(registered_plugins, registered_diagnostics) end)

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
end
