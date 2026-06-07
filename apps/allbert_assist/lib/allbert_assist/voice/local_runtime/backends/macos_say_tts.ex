defmodule AllbertAssist.Voice.LocalRuntime.Backends.MacOSSayTTS do
  @moduledoc """
  Local TTS backend for the Allbert local voice runtime.

  v0.48 uses macOS `say` as the smallest real offline TTS backend available on
  the operator's current platform, then materializes a requested audio format
  through the existing bounded `ffmpeg` dependency.
  """

  alias AllbertAssist.Runtime.Paths
  alias AllbertAssist.Voice.LocalRuntime.Config

  @formats ~w[wav mp3]

  @spec doctor(Config.t()) :: map()
  def doctor(config) do
    codes =
      []
      |> maybe_missing(config.say_executable, :local_tts_say_missing)
      |> maybe_missing(config.ffmpeg_executable, :local_tts_ffmpeg_missing)

    %{
      backend: :macos_say,
      available?: codes == [],
      model: config.tts_model_alias,
      supported_formats: @formats,
      diagnostic_codes: Enum.reverse(codes)
    }
  end

  @spec synthesize(String.t(), map(), Config.t()) :: {:ok, map()} | {:error, term()}
  def synthesize(text, params, config) when is_binary(text) and is_map(params) do
    with :ok <- backend_ready(config),
         {:ok, format} <- output_format(params),
         {:ok, paths} <- paths(format),
         :ok <- write_text(paths.text, text),
         :ok <- run_say(config.say_executable, paths.text, paths.aiff),
         :ok <- run_ffmpeg(config.ffmpeg_executable, paths.aiff, paths.output),
         {:ok, audio} <- read_bounded(paths.output, config.max_audio_bytes) do
      {:ok,
       %{
         audio: audio,
         mime_type: mime_type(format),
         output_format: format,
         byte_size: byte_size(audio),
         usage: %{source: :unavailable}
       }}
    end
  end

  defp backend_ready(config) do
    cond do
      not is_binary(config.say_executable) -> {:error, :local_tts_say_missing}
      not is_binary(config.ffmpeg_executable) -> {:error, :local_tts_ffmpeg_missing}
      true -> :ok
    end
  end

  defp output_format(%{"response_format" => format}), do: normalize_format(format)
  defp output_format(%{response_format: format}), do: normalize_format(format)
  defp output_format(%{"output_format" => format}), do: normalize_format(format)
  defp output_format(%{output_format: format}), do: normalize_format(format)
  defp output_format(_params), do: {:ok, "wav"}

  defp normalize_format(format) when is_binary(format) do
    format = format |> String.trim() |> String.downcase()

    if format in @formats do
      {:ok, format}
    else
      {:error, {:local_tts_format_unsupported, format}}
    end
  end

  defp normalize_format(_format), do: {:error, :local_tts_format_invalid}

  defp paths(format) do
    nonce = System.unique_integer([:positive, :monotonic])
    root = Path.join([Paths.tmp_root(), "local-voice-runtime", "tts", Integer.to_string(nonce)])

    with :ok <- File.mkdir_p(root) do
      {:ok,
       %{
         text: Path.join(root, "input.txt"),
         aiff: Path.join(root, "speech.aiff"),
         output: Path.join(root, "speech.#{format}")
       }}
    end
  end

  defp write_text(path, text) do
    case File.write(path, text) do
      :ok -> :ok
      {:error, reason} -> {:error, {:local_tts_temp_write_failed, reason}}
    end
  end

  defp run_say(say, input_path, output_path) do
    case System.cmd(say, ["-f", input_path, "-o", output_path], stderr_to_stdout: true) do
      {_output, 0} -> :ok
      {_output, status} -> {:error, {:local_tts_say_failed, status}}
    end
  end

  defp run_ffmpeg(ffmpeg, input_path, output_path) do
    args = [
      "-nostdin",
      "-hide_banner",
      "-loglevel",
      "error",
      "-y",
      "-i",
      input_path,
      "-ac",
      "1",
      "-ar",
      "24000",
      output_path
    ]

    case System.cmd(ffmpeg, args, stderr_to_stdout: true) do
      {_output, 0} -> :ok
      {_output, status} -> {:error, {:local_tts_ffmpeg_failed, status}}
    end
  end

  defp read_bounded(path, max_bytes) do
    case File.read(path) do
      {:ok, audio} when byte_size(audio) <= max_bytes ->
        {:ok, audio}

      {:ok, audio} ->
        {:error, {:audio_output_too_large, byte_size(audio), max_bytes}}

      {:error, reason} ->
        {:error, {:local_tts_output_read_failed, reason}}
    end
  end

  defp mime_type("wav"), do: "audio/wav"
  defp mime_type("mp3"), do: "audio/mpeg"

  defp maybe_missing(codes, nil, code), do: [code | codes]
  defp maybe_missing(codes, "", code), do: [code | codes]
  defp maybe_missing(codes, _path, _code), do: codes
end
