defmodule AllbertAssist.Voice.TranscodeTest do
  use ExUnit.Case, async: true
  @moduletag :home_fs_serial

  alias AllbertAssist.Voice.Transcode

  setup do
    root =
      Path.join(
        System.tmp_dir!(),
        "allbert-transcode-test-#{System.pid()}-#{System.unique_integer([:positive])}"
      )

    File.rm_rf!(root)
    File.mkdir_p!(root)

    on_exit(fn -> File.rm_rf!(root) end)

    {:ok, root: root}
  end

  test "builds a fixed ffmpeg spec with redacted path metadata", %{root: root} do
    input_path = Path.join(root, "hello.raw")
    output_root = Path.join(root, "out")
    File.write!(input_path, "audio")

    media = %{
      "audio_formats_supported" => ["wav", "mp3"],
      "max_audio_bytes" => 20,
      "max_audio_duration_ms" => 2_000
    }

    assert {:ok, spec} =
             Transcode.build_spec(input_path, media,
               output_root: output_root,
               max_bytes: 10,
               max_duration_ms: 1_000
             )

    assert spec.executable == "ffmpeg"
    assert spec.output_format == "wav"
    assert spec.max_bytes == 10
    assert spec.max_duration_ms == 1_000
    assert spec.input_size_bytes == 5
    assert spec.output_path |> Path.dirname() == Path.expand(output_root)

    assert spec.args == [
             "-nostdin",
             "-hide_banner",
             "-loglevel",
             "error",
             "-i",
             input_path,
             "-vn",
             "-y",
             "-f",
             "wav",
             spec.output_path
           ]

    assert "-nostdin" in spec.redacted_args
    assert "[REDACTED_AUDIO_PATH]" in spec.redacted_args
    refute inspect(spec.redacted_args) =~ root
    assert spec.input_path_redacted == "[REDACTED_AUDIO_PATH]"
    assert spec.output_path_redacted == "[REDACTED_AUDIO_PATH]"
  end

  test "honors requested provider-supported output format", %{root: root} do
    input_path = Path.join(root, "hello.raw")
    File.write!(input_path, "audio")

    assert {:ok, spec} =
             Transcode.build_spec(
               "file://#{input_path}",
               %{"audio_formats_supported" => ["wav", "mp3"]},
               format: :mp3,
               output_root: root
             )

    assert spec.output_format == "mp3"
  end

  test "materializes compatible files without arbitrary runner args", %{root: root} do
    input_path = Path.join(root, "hello.wav")
    File.write!(input_path, "wav audio")

    assert {:ok, spec} =
             Transcode.build_spec(
               input_path,
               %{"audio_formats_supported" => ["wav"], "max_audio_bytes" => 20},
               output_root: root
             )

    assert {:ok, output_path} = Transcode.materialize(spec)
    assert output_path == spec.output_path
    assert File.read!(output_path) == "wav audio"

    assert {:ok, output_path} =
             Transcode.materialize(spec,
               transcode_runner: fn runner_spec ->
                 File.write!(runner_spec.output_path, "runner audio")
                 :ok
               end
             )

    assert File.read!(output_path) == "runner audio"
  end

  test "rejects unsupported inputs, oversize files, and arbitrary codec args", %{root: root} do
    input_path = Path.join(root, "hello.raw")
    File.write!(input_path, "audio")
    media = %{"audio_formats_supported" => ["wav"], "max_audio_bytes" => 20}

    assert {:error, {:unsupported_audio_input_uri, "https"}} =
             Transcode.build_spec("https://example.test/hello.wav", media)

    assert {:error, {:audio_input_too_large, 5, 4}} =
             Transcode.build_spec(input_path, media, max_bytes: 4)

    assert {:error, :arbitrary_transcode_args_not_supported} =
             Transcode.build_spec(input_path, media, extra_args: ["-codec:a", "copy"])
  end
end
