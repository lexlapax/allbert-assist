defmodule AllbertAssist.Voice.Adapters.BundledLocal do
  @moduledoc """
  Bundled-local voice adapter stub for the v0.48 contract.
  """

  @behaviour AllbertAssist.Voice.ProviderAdapter

  @mode :bundled_local

  @impl true
  def transcribe(_profile, _request, _opts), do: unavailable()

  @impl true
  def synthesize(_profile, _request, _opts), do: unavailable()

  @impl true
  def doctor(_profile, _opts), do: stub_doctor()

  defp unavailable, do: {:error, {:voice_adapter_unavailable, @mode}}

  defp stub_doctor do
    {:ok,
     %{
       endpoint_ok: false,
       model_available: :unknown,
       provider_usage_metadata_available: :unknown,
       local_runtime_present: false,
       diagnostic_codes: [:voice_provider_probe_unavailable]
     }}
  end
end
