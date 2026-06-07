defmodule AllbertAssist.Voice.Adapters.Fake do
  @moduledoc """
  Deterministic fake STT/TTS adapter for automated fixture tests only.
  """

  @behaviour AllbertAssist.Voice.ProviderAdapter

  alias AllbertAssist.Resources.ResourceURI
  alias AllbertAssist.Runtime.Paths

  @sample_rate_hz 16_000
  @duration_ms 250
  @bits_per_sample 16
  @channel_count 1

  @impl true
  def transcribe(%{model: "fake-stt-retryable-error"}, _request, _opts),
    do: {:error, {:voice_http_error, 503}}

  def transcribe(%{model: "fake-stt-nonretryable-error"}, _request, _opts),
    do: {:error, {:voice_http_error, 401}}

  def transcribe(_profile, %{input_path: path}, _opts) when is_binary(path) do
    {:ok,
     %{
       transcript: fake_transcript(path),
       duration_ms: nil,
       usage: unavailable_packet(),
       cost: unavailable_packet()
     }}
  end

  def transcribe(_profile, _request, _opts), do: {:error, :missing_audio_input}

  @impl true
  def synthesize(_profile, %{text: text, output_format: "wav"}, _opts) when is_binary(text) do
    audio = fake_wav()
    path = output_path(text, "wav")

    with :ok <- File.mkdir_p(Path.dirname(path)),
         :ok <- File.write(path, audio),
         {:ok, resource_uri} <- ResourceURI.file(path) do
      {:ok,
       %{
         path: path,
         resource_uri: resource_uri,
         byte_size: byte_size(audio),
         output_format: "wav",
         duration_ms: @duration_ms,
         sample_rate_hz: @sample_rate_hz,
         channel_count: @channel_count,
         mime_type: "audio/wav",
         usage: unavailable_packet(),
         cost: unavailable_packet()
       }}
    end
  end

  def synthesize(_profile, %{output_format: format}, _opts),
    do: {:error, {:unsupported_fake_tts_format, format}}

  def synthesize(_profile, _request, _opts), do: {:error, :missing_text}

  @impl true
  def doctor(_profile, _opts) do
    {:ok,
     %{
       endpoint_ok: true,
       model_available: true,
       provider_usage_metadata_available: false,
       fixture_probe_ok: true,
       redacted_host: "fixture",
       diagnostic_codes: []
     }}
  end

  defp fake_transcript(path) do
    case path |> Path.basename() |> Path.rootname() |> String.downcase() do
      "hello" -> "hello from fixture audio"
      stem when stem != "" -> "transcribed fixture audio #{stem}"
      _stem -> "transcribed fixture audio"
    end
  end

  defp fake_wav do
    sample_count = div(@sample_rate_hz * @duration_ms, 1000)
    data = :binary.copy(<<0, 0>>, sample_count)
    data_size = byte_size(data)
    byte_rate = @sample_rate_hz * @channel_count * div(@bits_per_sample, 8)
    block_align = @channel_count * div(@bits_per_sample, 8)

    "RIFF" <>
      <<36 + data_size::little-unsigned-integer-size(32)>> <>
      "WAVE" <>
      "fmt " <>
      <<16::little-unsigned-integer-size(32)>> <>
      <<1::little-unsigned-integer-size(16)>> <>
      <<@channel_count::little-unsigned-integer-size(16)>> <>
      <<@sample_rate_hz::little-unsigned-integer-size(32)>> <>
      <<byte_rate::little-unsigned-integer-size(32)>> <>
      <<block_align::little-unsigned-integer-size(16)>> <>
      <<@bits_per_sample::little-unsigned-integer-size(16)>> <>
      "data" <>
      <<data_size::little-unsigned-integer-size(32)>> <>
      data
  end

  defp output_path(text, output_format) do
    digest = :crypto.hash(:sha256, text) |> Base.encode16(case: :lower) |> binary_part(0, 16)
    Path.join([Paths.tmp_root(), "voice-synthesis", "voice-#{digest}.#{output_format}"])
  end

  defp unavailable_packet, do: %{source: :unavailable}
end
