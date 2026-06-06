defmodule AllbertAssist.Voice.Adapters.RemoteCredentialed do
  @moduledoc """
  Remote credentialed voice adapter dispatcher.

  v0.48 implements OpenAI remote STT/TTS and Gemini remote STT/TTS. Anthropic
  is deliberately not selectable for STT/TTS until it exposes native voice APIs.
  """

  @behaviour AllbertAssist.Voice.ProviderAdapter

  alias AllbertAssist.Voice.Adapters.Gemini
  alias AllbertAssist.Voice.Adapters.OpenAICompatible

  @impl true
  def transcribe(profile, request, opts) do
    with {:ok, adapter} <- provider_adapter(profile) do
      adapter.transcribe(profile, request, opts)
    end
  end

  @impl true
  def synthesize(profile, request, opts) do
    with {:ok, adapter} <- provider_adapter(profile) do
      adapter.synthesize(profile, request, opts)
    end
  end

  @impl true
  def doctor(profile, opts) do
    case provider_adapter(profile) do
      {:ok, adapter} ->
        adapter.doctor(profile, opts)

      {:error, {:voice_capability_not_native, provider_type}} ->
        {:ok,
         %{
           endpoint_ok: false,
           model_available: false,
           provider_usage_metadata_available: false,
           diagnostic_codes: [{:voice_capability_not_native, provider_type}]
         }}

      {:error, reason} ->
        {:ok,
         %{
           endpoint_ok: false,
           model_available: :unknown,
           provider_usage_metadata_available: :unknown,
           diagnostic_codes: [reason]
         }}
    end
  end

  defp provider_adapter(%{provider_type: "openai"}), do: {:ok, OpenAICompatible}
  defp provider_adapter(%{provider_type: "openai_compatible"}), do: {:ok, OpenAICompatible}
  defp provider_adapter(%{provider_type: "google"}), do: {:ok, Gemini}

  defp provider_adapter(%{provider_type: "anthropic"}),
    do: {:error, {:voice_capability_not_native, "anthropic"}}

  defp provider_adapter(%{provider_type: provider_type}),
    do: {:error, {:voice_adapter_unavailable, provider_type}}

  defp provider_adapter(_profile), do: {:error, {:voice_adapter_unavailable, :unknown}}
end
