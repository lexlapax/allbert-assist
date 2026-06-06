defmodule AllbertAssist.Voice.Adapters.LocalEndpoint do
  @moduledoc """
  Local endpoint voice adapter stub.

  v0.48 defines the adapter seam but ships deterministic fake voice as release
  authority. A concrete local endpoint call path remains a later implementation.
  """

  @behaviour AllbertAssist.Voice.ProviderAdapter

  @mode :local_endpoint

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
       local_runtime_present: nil,
       diagnostic_codes: [:voice_provider_probe_unavailable]
     }}
  end
end
