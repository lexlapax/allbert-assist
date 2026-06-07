defmodule Allbert.V048VoiceLiveSmoke do
  @moduledoc false

  alias AllbertAssist.Actions.Runner
  alias AllbertAssist.Runtime
  alias AllbertAssist.Settings
  alias AllbertAssist.Settings.Secrets

  def run(argv) do
    Mix.Task.run("app.start")

    unless System.get_env("ALLBERT_V048_LIVE_SMOKE") == "1" do
      Mix.raise("""
      Refusing to run live voice smoke without ALLBERT_V048_LIVE_SMOKE=1.

      This script can upload audio to the selected provider and can synthesize
      billable audio output. Use a disposable ALLBERT_HOME.
      """)
    end

    provider = System.get_env("ALLBERT_V048_PROVIDER") || "openai"
    audio_file = System.get_env("ALLBERT_V048_AUDIO") || List.first(argv)
    audio_file = validate_audio_file!(audio_file)
    context = context()

    configure_provider!(provider)
    configure_voice_loop!()

    Mix.shell().info("Provider: #{provider}")
    Mix.shell().info("Audio: #{audio_file}")
    Mix.shell().info("ALLBERT_HOME: #{System.get_env("ALLBERT_HOME") || "~/.allbert"}")

    doctor!(stt_profile(provider), context)
    doctor!(tts_profile(provider), context)

    transcript = transcribe!(audio_file, context)
    Mix.shell().info("Transcript: #{transcript}")

    runtime_response = runtime_turn!(transcript)
    Mix.shell().info("Runtime response: #{runtime_response.message}")

    synthesize!(runtime_response.message, context)
    Mix.shell().info("v0.48 live voice smoke completed.")
  end

  defp validate_audio_file!(audio_file) when is_binary(audio_file) do
    audio_file = audio_file |> String.trim() |> Path.expand()

    if File.regular?(audio_file) do
      audio_file
    else
      Mix.raise("Audio file does not exist: #{audio_file}")
    end
  end

  defp validate_audio_file!(_audio_file) do
    Mix.raise("Set ALLBERT_V048_AUDIO=/path/to/input.wav or pass the audio path as argv[0].")
  end

  defp configure_provider!("local") do
    put!("providers.local_voice.enabled", true)

    put!(
      "providers.local_voice.base_url",
      System.get_env("LOCAL_VOICE_BASE_URL") || "http://localhost:5050/v1"
    )

    select_voice_profiles!("voice_stt_local", "voice_tts_local")
  end

  defp configure_provider!("openai") do
    put!("providers.openai.enabled", true)
    put_secret_from_env!("secret://providers/openai/api_key", "OPENAI_API_KEY")
    select_voice_profiles!("voice_stt_openai", "voice_tts_openai")
  end

  defp configure_provider!("gemini") do
    put!("providers.gemini.enabled", true)
    put_secret_from_env!("secret://providers/gemini/api_key", "GEMINI_API_KEY", "GOOGLE_API_KEY")
    select_voice_profiles!("voice_stt_gemini", "voice_tts_gemini")
  end

  defp configure_provider!(other) do
    Mix.raise(
      "Unknown ALLBERT_V048_PROVIDER=#{inspect(other)}; expected local, openai, or gemini."
    )
  end

  defp configure_voice_loop! do
    put!("voice.enabled", true)
    put!("providers.local_ollama.enabled", true)
    put!("model_preferences.tasks.direct_answer", ["voice_text_local", "local"])
    put!("model_preferences.capabilities.text_generation", ["voice_text_local", "local"])
  end

  defp select_voice_profiles!(stt_profile, tts_profile) do
    put!("model_preferences.capabilities.speech_to_text", [stt_profile])
    put!("model_preferences.capabilities.text_to_speech", [tts_profile])
  end

  defp doctor!(profile, context) do
    response =
      run!("doctor_voice_provider", %{profile: profile}, context, fn response ->
        response.status == :completed
      end)

    Mix.shell().info(
      "Doctor #{profile}: endpoint_ok=#{response.doctor.endpoint_ok} model_available=#{inspect(response.doctor.model_available)}"
    )

    response
  end

  defp transcribe!(audio_file, context) do
    pending_stt =
      run!("transcribe_voice", %{audio_file: audio_file}, context, fn response ->
        response.status == :needs_confirmation
      end)

    Mix.shell().info("STT confirmation: #{pending_stt.confirmation_id}")

    approved_stt =
      run!(
        "approve_confirmation",
        %{id: pending_stt.confirmation_id, reason: "v0.48 live STT smoke"},
        context,
        fn response -> response.status == :completed end
      )

    transcript = get_in(approved_stt, [:output_data, :transcript])

    if is_binary(transcript) and String.trim(transcript) != "" do
      transcript
    else
      Mix.raise(
        "STT approval completed but did not return a transcript in transient output_data."
      )
    end
  end

  defp runtime_turn!(transcript) do
    case Runtime.submit_user_input(%{text: transcript, channel: :cli, operator_id: "local"}) do
      {:ok, %{status: status, message: message} = response}
      when status in [:completed, "completed"] and is_binary(message) ->
        response

      {:ok, response} ->
        Mix.raise(
          "Runtime text turn did not complete: #{inspect(Map.take(response, [:status, :message]))}"
        )

      {:error, reason} ->
        Mix.raise("Runtime text turn failed: #{inspect(reason)}")
    end
  end

  defp synthesize!(text, context) do
    pending_tts =
      run!("synthesize_voice", %{text: text}, context, fn response ->
        response.status == :needs_confirmation
      end)

    Mix.shell().info("TTS confirmation: #{pending_tts.confirmation_id}")

    approved_tts =
      run!(
        "approve_confirmation",
        %{id: pending_tts.confirmation_id, reason: "v0.48 live TTS smoke"},
        context,
        fn response -> response.status == :completed end
      )

    audio_out = get_in(approved_tts, [:output_data, :audio_file])
    resource_uri = get_in(approved_tts, [:output_data, :output_resource_uri])

    Mix.shell().info("Speech resource: #{resource_uri || "none"}")
    Mix.shell().info("Speech file: #{audio_out || "none"}")
  end

  defp run!(action, params, context, ok?) do
    case Runner.run(action, params, context) do
      {:ok, response} ->
        if ok?.(response) do
          response
        else
          Mix.raise("#{action} returned unexpected response: #{inspect(response, pretty: true)}")
        end

      {:error, reason} ->
        Mix.raise("#{action} failed: #{inspect(reason)}")
    end
  end

  defp put!(key, value) do
    case Settings.put(key, value, %{audit?: false}) do
      {:ok, _setting} -> :ok
      {:error, reason} -> Mix.raise("Failed to set #{key}: #{inspect(reason)}")
    end
  end

  defp put_secret_from_env!(ref, primary_env, fallback_env \\ nil) do
    value =
      System.get_env(primary_env) ||
        if(is_binary(fallback_env), do: System.get_env(fallback_env), else: nil)

    unless is_binary(value) and String.trim(value) != "" do
      env_names = [primary_env, fallback_env] |> Enum.reject(&is_nil/1) |> Enum.join(" or ")
      Mix.raise("Missing #{env_names} for #{ref}.")
    end

    case Secrets.put_secret(ref, value, %{audit?: false}) do
      {:ok, _secret} -> :ok
      {:error, reason} -> Mix.raise("Failed to store #{ref}: #{inspect(reason)}")
    end
  end

  defp context do
    %{
      actor: "local",
      channel: :cli,
      surface: "scripts/v048_voice_live_smoke.exs",
      request: %{operator_id: "local", channel: :cli}
    }
  end

  defp stt_profile("local"), do: "voice_stt_local"
  defp stt_profile("openai"), do: "voice_stt_openai"
  defp stt_profile("gemini"), do: "voice_stt_gemini"

  defp tts_profile("local"), do: "voice_tts_local"
  defp tts_profile("openai"), do: "voice_tts_openai"
  defp tts_profile("gemini"), do: "voice_tts_gemini"
end

Allbert.V048VoiceLiveSmoke.run(System.argv())
