defmodule AllbertAssist.Voice.Adapters.LocalEndpoint do
  @moduledoc """
  Local OpenAI-compatible voice endpoint adapter.

  Local voice endpoints must be explicit loopback URLs and use the
  OpenAI-compatible `/v1/audio/transcriptions` and `/v1/audio/speech`
  request-file contract.
  """

  @behaviour AllbertAssist.Voice.ProviderAdapter

  alias AllbertAssist.Voice.Adapters.OpenAICompatible

  @impl true
  def transcribe(profile, request, opts), do: OpenAICompatible.transcribe(profile, request, opts)

  @impl true
  def synthesize(profile, request, opts), do: OpenAICompatible.synthesize(profile, request, opts)

  @impl true
  def doctor(profile, opts), do: OpenAICompatible.doctor(profile, opts)
end
