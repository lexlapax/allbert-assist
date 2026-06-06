defmodule AllbertAssist.Voice.Transcode do
  @moduledoc """
  Bounded ffmpeg-class audio transcode planning and execution.

  This module builds and materializes a fixed execution spec. The spec uses a
  fixed ffmpeg argument shape, chooses only provider-supported output formats,
  and carries a redacted command view for traces and audits.
  """

  alias AllbertAssist.Resources.ResourceURI
  alias AllbertAssist.Runtime.Paths
  alias AllbertAssist.Runtime.Redactor

  @allowed_output_formats ~w[wav flac mp3 m4a ogg webm]
  @default_max_bytes 10_485_760
  @default_max_duration_ms 300_000

  @blocked_arg_keys [
    :args,
    :argv,
    :codec_args,
    :extra_args,
    "args",
    "argv",
    "codec_args",
    "extra_args"
  ]

  @type spec :: %{
          required(:executable) => String.t(),
          required(:args) => [String.t()],
          required(:redacted_args) => [String.t()],
          required(:input_path) => String.t(),
          required(:input_path_redacted) => String.t(),
          required(:input_size_bytes) => non_neg_integer(),
          required(:output_path) => String.t(),
          required(:output_path_redacted) => String.t(),
          required(:output_format) => String.t(),
          required(:max_bytes) => pos_integer(),
          required(:max_duration_ms) => pos_integer()
        }

  @doc "Build a bounded audio transcode spec for a local input file."
  @spec build_spec(term(), map(), keyword() | map()) :: {:ok, spec()} | {:error, term()}
  def build_spec(input, model_profile_or_media, opts \\ []) do
    with :ok <- reject_arbitrary_args(opts),
         {:ok, media} <- media(model_profile_or_media),
         {:ok, input_path} <- input_path(input),
         {:ok, stat} <- File.stat(input_path),
         {:ok, max_bytes} <- effective_bound(:max_bytes, media, opts),
         {:ok, max_duration_ms} <- effective_bound(:max_duration_ms, media, opts),
         :ok <- validate_size(stat.size, max_bytes),
         :ok <- validate_duration(opts, max_duration_ms),
         {:ok, output_format} <- output_format(media, opts),
         {:ok, output_path} <- output_path(input_path, output_format, opts) do
      args = [
        "-nostdin",
        "-hide_banner",
        "-loglevel",
        "error",
        "-i",
        input_path,
        "-vn",
        "-y",
        "-f",
        output_format,
        output_path
      ]

      redacted_args =
        Enum.map(args, fn
          ^input_path -> Redactor.redact_audio_resource_uri(input_path)
          ^output_path -> Redactor.redact_audio_resource_uri(output_path)
          arg -> arg
        end)

      {:ok,
       %{
         executable: "ffmpeg",
         args: args,
         redacted_args: redacted_args,
         input_path: input_path,
         input_path_redacted: Redactor.redact_audio_resource_uri(input_path),
         input_size_bytes: stat.size,
         output_path: output_path,
         output_path_redacted: Redactor.redact_audio_resource_uri(output_path),
         output_format: output_format,
         max_bytes: max_bytes,
         max_duration_ms: max_duration_ms
       }}
    else
      {:error, reason} -> {:error, reason}
    end
  end

  @doc "Return the static output-format vocabulary accepted by this helper."
  @spec allowed_output_formats() :: [String.t()]
  def allowed_output_formats, do: @allowed_output_formats

  @doc """
  Materialize a transcode spec and return the bounded provider input path.

  Existing files whose extension already matches the selected provider format
  are copied to the planned output path. Other formats execute the fixed ffmpeg
  argv emitted by `build_spec/3`. Tests may pass `transcode_runner: :copy` or a
  one-arity function that writes `spec.output_path`.
  """
  @spec materialize(spec(), keyword() | map()) :: {:ok, String.t()} | {:error, term()}
  def materialize(%{} = spec, opts \\ []) do
    with :ok <- validate_materialize_spec(spec),
         :ok <- File.mkdir_p(Path.dirname(spec.output_path)) do
      runner = option(opts, :transcode_runner, option(opts, :runner, nil))

      cond do
        runner == :copy ->
          copy_input(spec)

        is_function(runner, 1) ->
          run_custom_runner(spec, runner)

        same_format?(spec.input_path, spec.output_format) ->
          copy_input(spec)

        true ->
          run_ffmpeg(spec)
      end
    end
  end

  defp reject_arbitrary_args(opts) do
    if Enum.any?(@blocked_arg_keys, &option_present?(opts, &1)) do
      {:error, :arbitrary_transcode_args_not_supported}
    else
      :ok
    end
  end

  defp input_path(input) when is_binary(input) do
    value = String.trim(input)
    uri = URI.parse(value)

    cond do
      value == "" ->
        {:error, :missing_audio_input}

      uri.scheme == "file" ->
        ResourceURI.path_from_file_uri(value)

      is_binary(uri.scheme) ->
        {:error, {:unsupported_audio_input_uri, uri.scheme}}

      true ->
        {:ok, Path.expand(value)}
    end
  end

  defp input_path(_input), do: {:error, :invalid_audio_input}

  defp media(%{media: media}) when is_map(media), do: {:ok, media}
  defp media(%{"media" => media}) when is_map(media), do: {:ok, media}
  defp media(media) when is_map(media), do: {:ok, media}
  defp media(_value), do: {:error, :missing_audio_media_metadata}

  defp effective_bound(:max_bytes, media, opts) do
    global_max =
      positive_bound(opts, :max_bytes) ||
        opts
        |> option(:settings, %{})
        |> dotted_positive_bound("voice.audio.max_bytes") ||
        @default_max_bytes

    global_max
    |> min_positive_bound(media_bound(media, "max_audio_bytes"))
    |> ok_positive_bound(:invalid_audio_max_bytes)
  end

  defp effective_bound(:max_duration_ms, media, opts) do
    global_max =
      positive_bound(opts, :max_duration_ms) ||
        opts
        |> option(:settings, %{})
        |> dotted_positive_bound("voice.audio.max_duration_ms") ||
        @default_max_duration_ms

    global_max
    |> min_positive_bound(media_bound(media, "max_audio_duration_ms"))
    |> ok_positive_bound(:invalid_audio_max_duration_ms)
  end

  defp validate_size(size, max_bytes) when size <= max_bytes, do: :ok
  defp validate_size(size, max_bytes), do: {:error, {:audio_input_too_large, size, max_bytes}}

  defp validate_duration(opts, max_duration_ms) do
    case positive_bound(opts, :duration_ms) do
      nil -> :ok
      duration_ms when duration_ms <= max_duration_ms -> :ok
      duration_ms -> {:error, {:audio_input_too_long, duration_ms, max_duration_ms}}
    end
  end

  defp output_format(media, opts) do
    supported_formats =
      media
      |> map_get("audio_formats_supported")
      |> normalize_formats()
      |> Enum.filter(&(&1 in @allowed_output_formats))

    requested = opts |> option(:format, nil) |> normalize_format()

    cond do
      supported_formats == [] ->
        {:error, :missing_supported_audio_formats}

      is_binary(requested) and requested not in supported_formats ->
        {:error, {:unsupported_audio_output_format, requested, supported_formats}}

      is_binary(requested) ->
        {:ok, requested}

      true ->
        {:ok, hd(supported_formats)}
    end
  end

  defp output_path(input_path, output_format, opts) do
    output_root =
      opts
      |> option(:output_root, Path.join(Paths.tmp_root(), "audio-transcode"))
      |> to_string()
      |> Path.expand()

    digest =
      :sha256
      |> :crypto.hash(input_path <> ":" <> output_format)
      |> Base.encode16(case: :lower)
      |> binary_part(0, 16)

    {:ok, Path.join(output_root, "#{digest}.#{output_format}")}
  end

  defp normalize_formats(formats) when is_list(formats) do
    formats
    |> Enum.map(&normalize_format/1)
    |> Enum.filter(&is_binary/1)
    |> Enum.uniq()
  end

  defp normalize_formats(_formats), do: []

  defp normalize_format(value) when is_binary(value) do
    value
    |> String.trim()
    |> String.trim_leading(".")
    |> String.downcase()
    |> case do
      "" -> nil
      format -> format
    end
  end

  defp normalize_format(nil), do: nil

  defp normalize_format(value) when is_atom(value),
    do: value |> Atom.to_string() |> normalize_format()

  defp normalize_format(_value), do: nil

  defp positive_bound(opts, key) do
    case option(opts, key, nil) do
      value when is_integer(value) and value > 0 ->
        value

      value when is_binary(value) ->
        case Integer.parse(value) do
          {integer, ""} when integer > 0 -> integer
          _other -> nil
        end

      _value ->
        nil
    end
  end

  defp dotted_positive_bound(settings, dotted_key) when is_map(settings) do
    settings
    |> dotted_get(dotted_key)
    |> positive_integer()
  end

  defp dotted_positive_bound(_settings, _dotted_key), do: nil

  defp media_bound(media, key), do: media |> map_get(key) |> positive_integer()

  defp positive_integer(value) when is_integer(value) and value > 0, do: value

  defp positive_integer(value) when is_binary(value) do
    case Integer.parse(value) do
      {integer, ""} when integer > 0 -> integer
      _other -> nil
    end
  end

  defp positive_integer(_value), do: nil

  defp min_positive_bound(value, nil), do: value
  defp min_positive_bound(value, bound), do: min(value, bound)

  defp ok_positive_bound(value, _reason) when is_integer(value) and value > 0, do: {:ok, value}
  defp ok_positive_bound(_value, reason), do: {:error, reason}

  defp option(opts, key, default) when is_map(opts) do
    Map.get(opts, key, Map.get(opts, Atom.to_string(key), default))
  end

  defp option(opts, key, default) when is_list(opts) do
    keys = [key, Atom.to_string(key)]

    case Enum.find(opts, fn
           {option_key, _value} -> option_key in keys
           _other -> false
         end) do
      {_option_key, value} -> value
      nil -> default
    end
  end

  defp option(_opts, _key, default), do: default

  defp option_present?(opts, key) when is_map(opts), do: Map.has_key?(opts, key)

  defp option_present?(opts, key) when is_list(opts) do
    Enum.any?(opts, fn
      {option_key, _value} -> option_key == key
      _other -> false
    end)
  end

  defp option_present?(_opts, _key), do: false

  defp map_get(map, key) when is_map(map),
    do: Map.get(map, key, Map.get(map, String.to_atom(key)))

  defp map_get(_map, _key), do: nil

  defp dotted_get(settings, dotted_key) do
    Enum.reduce_while(String.split(dotted_key, "."), settings, fn key, acc ->
      case map_get(acc, key) do
        nil -> {:halt, nil}
        value -> {:cont, value}
      end
    end)
  end

  defp validate_materialize_spec(%{
         executable: "ffmpeg",
         args: [
           "-nostdin",
           "-hide_banner",
           "-loglevel",
           "error",
           "-i",
           input_path,
           "-vn",
           "-y",
           "-f",
           output_format,
           output_path
         ],
         input_path: input_path,
         output_path: output_path,
         output_format: output_format,
         max_bytes: max_bytes
       })
       when is_binary(input_path) and is_binary(output_path) and is_binary(output_format) and
              is_integer(max_bytes) and max_bytes > 0,
       do: :ok

  defp validate_materialize_spec(_spec), do: {:error, :invalid_transcode_spec}

  defp same_format?(input_path, output_format) do
    input_path
    |> Path.extname()
    |> normalize_format()
    |> Kernel.==(normalize_format(output_format))
  end

  defp copy_input(spec) do
    with {:ok, bytes} <- File.read(spec.input_path),
         :ok <- validate_output_size(byte_size(bytes), spec.max_bytes),
         :ok <- File.write(spec.output_path, bytes) do
      {:ok, spec.output_path}
    end
  end

  defp run_custom_runner(spec, runner) do
    case runner.(spec) do
      :ok -> validate_output_file(spec)
      {:ok, path} when path == spec.output_path -> validate_output_file(spec)
      {:ok, _path} -> {:error, :invalid_transcode_runner_output}
      {:error, reason} -> {:error, reason}
      other -> {:error, {:invalid_transcode_runner_result, other}}
    end
  end

  defp run_ffmpeg(spec) do
    case system_cmd(spec.executable, spec.args) do
      {:ok, 0} -> validate_output_file(spec)
      {:ok, status} -> {:error, {:voice_transcode_failed, status}}
      {:error, reason} -> {:error, reason}
    end
  end

  defp system_cmd(executable, args) do
    {_output, status} = System.cmd(executable, args, stderr_to_stdout: true)
    {:ok, status}
  rescue
    _error in ErlangError -> {:error, :voice_transcode_unavailable}
  end

  defp validate_output_file(spec) do
    case File.stat(spec.output_path) do
      {:ok, %{size: size}} ->
        with :ok <- validate_output_size(size, spec.max_bytes) do
          {:ok, spec.output_path}
        end

      {:error, reason} ->
        {:error, {:voice_transcode_output_missing, reason}}
    end
  end

  defp validate_output_size(size, max_bytes) when size <= max_bytes, do: :ok

  defp validate_output_size(size, max_bytes),
    do: {:error, {:audio_output_too_large, size, max_bytes}}
end
