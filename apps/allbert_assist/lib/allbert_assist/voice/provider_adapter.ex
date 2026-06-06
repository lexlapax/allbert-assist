defmodule AllbertAssist.Voice.ProviderAdapter do
  @moduledoc """
  Voice-provider adapter behaviour for STT/TTS/doctor calls.

  The resolver chooses a model profile. This module chooses the adapter for the
  profile's `media.deployment_mode`; adapters execute provider-specific voice
  work and never make permission decisions.
  """

  alias AllbertAssist.Voice.Adapters

  @type adapter_module ::
          Adapters.Fake
          | Adapters.LocalEndpoint
          | Adapters.BundledLocal
          | Adapters.RemoteCredentialed

  @type transcribe_request :: %{
          required(:input_path) => String.t(),
          required(:transcode_spec) => map()
        }

  @type transcript_packet :: %{
          required(:transcript) => String.t(),
          optional(:duration_ms) => non_neg_integer() | nil,
          optional(:usage) => map(),
          optional(:cost) => map()
        }

  @type synthesize_request :: %{
          required(:text) => String.t(),
          required(:output_format) => String.t(),
          optional(:voice) => String.t()
        }

  @type audio_packet :: %{
          required(:path) => String.t(),
          required(:resource_uri) => String.t(),
          required(:byte_size) => non_neg_integer(),
          required(:output_format) => String.t(),
          optional(:duration_ms) => non_neg_integer(),
          optional(:sample_rate_hz) => pos_integer(),
          optional(:channel_count) => pos_integer(),
          optional(:mime_type) => String.t(),
          optional(:usage) => map(),
          optional(:cost) => map()
        }

  @callback transcribe(map(), transcribe_request(), keyword()) ::
              {:ok, transcript_packet()} | {:error, term()}

  @callback synthesize(map(), synthesize_request(), keyword()) ::
              {:ok, audio_packet()} | {:error, term()}

  @callback doctor(map(), keyword()) :: {:ok, map()} | {:error, term()}

  @spec transcribe(map(), transcribe_request(), keyword()) ::
          {:ok, transcript_packet()} | {:error, term()}
  def transcribe(profile, request, opts \\ []) do
    with {:ok, adapter} <- for_profile(profile) do
      adapter.transcribe(profile, request, opts)
    end
  end

  @spec synthesize(map(), synthesize_request(), keyword()) ::
          {:ok, audio_packet()} | {:error, term()}
  def synthesize(profile, request, opts \\ []) do
    with {:ok, adapter} <- for_profile(profile) do
      adapter.synthesize(profile, request, opts)
    end
  end

  @spec doctor(map(), keyword()) :: {:ok, map()} | {:error, term()}
  def doctor(profile, opts \\ []) do
    with {:ok, adapter} <- for_profile(profile) do
      adapter.doctor(profile, opts)
    end
  end

  @spec for_profile(map()) ::
          {:ok, adapter_module()} | {:error, {:voice_adapter_unavailable, atom() | String.t()}}
  def for_profile(profile), do: profile |> deployment_mode() |> for_deployment_mode()

  @spec for_deployment_mode(term()) ::
          {:ok, adapter_module()} | {:error, {:voice_adapter_unavailable, atom() | String.t()}}
  def for_deployment_mode(mode) do
    case normalize_deployment_mode(mode) do
      :fake -> {:ok, Adapters.Fake}
      :local_endpoint -> {:ok, Adapters.LocalEndpoint}
      :bundled_local -> {:ok, Adapters.BundledLocal}
      :remote_credentialed -> {:ok, Adapters.RemoteCredentialed}
      mode -> {:error, {:voice_adapter_unavailable, mode || :unknown}}
    end
  end

  @spec deployment_mode(map()) :: atom() | String.t() | nil
  def deployment_mode(%{media: %{} = media}) do
    Map.get(media, "deployment_mode") || Map.get(media, :deployment_mode)
  end

  def deployment_mode(%{"media" => %{} = media}) do
    Map.get(media, "deployment_mode") || Map.get(media, :deployment_mode)
  end

  def deployment_mode(_profile), do: nil

  defp normalize_deployment_mode(mode)
       when mode in [:fake, :local_endpoint, :bundled_local, :remote_credentialed],
       do: mode

  defp normalize_deployment_mode("fake"), do: :fake
  defp normalize_deployment_mode("local_endpoint"), do: :local_endpoint
  defp normalize_deployment_mode("bundled_local"), do: :bundled_local
  defp normalize_deployment_mode("remote_credentialed"), do: :remote_credentialed

  defp normalize_deployment_mode(mode) when is_binary(mode) do
    case String.trim(mode) do
      "fake" -> :fake
      "local_endpoint" -> :local_endpoint
      "bundled_local" -> :bundled_local
      "remote_credentialed" -> :remote_credentialed
      "" -> nil
      value -> value
    end
  end

  defp normalize_deployment_mode(_mode), do: nil
end
