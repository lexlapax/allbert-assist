defmodule AllbertAssist.Voice.LocalRuntimeTest do
  use ExUnit.Case, async: false
  @moduletag :external_runtime_serial

  import Plug.Test
  import Plug.Conn, only: [put_req_header: 3]

  alias AllbertAssist.Runtime.Paths
  alias AllbertAssist.Voice.LocalRuntime
  alias AllbertAssist.Voice.LocalRuntime.Auth
  alias AllbertAssist.Voice.LocalRuntime.Backends.OllamaSTT
  alias AllbertAssist.Voice.LocalRuntime.Config
  alias AllbertAssist.Voice.LocalRuntime.Router
  alias AllbertAssist.Voice.LocalRuntime.Server
  alias AllbertAssist.Voice.ProviderHTTP

  setup {Req.Test, :verify_on_exit!}

  defmodule STTBackend do
    def doctor(_config), do: %{available?: true, diagnostic_codes: [], backend: :test_stt}

    def transcribe(path, _params, _config) do
      {:ok, %{transcript: "voice testing one two three", path_seen?: File.regular?(path)}}
    end
  end

  defmodule TTSBackend do
    def doctor(_config), do: %{available?: true, diagnostic_codes: [], backend: :test_tts}

    def synthesize(_text, _params, _config) do
      {:ok, %{audio: <<"RIFF", 0::32, "WAVE">>, mime_type: "audio/wav"}}
    end
  end

  defmodule MissingBackend do
    def doctor(_config), do: %{available?: false, diagnostic_codes: [:missing], backend: :missing}
  end

  test "models only lists locally available STT and TTS aliases" do
    assert %{"data" => [stt, tts]} =
             :get
             |> conn("/v1/models")
             |> call_router(router_opts())
             |> json_body()

    assert stt["id"] == "whisper-local"
    assert stt["capabilities"] == ["speech_to_text"]
    assert tts["id"] == "tts-local"
    assert tts["capabilities"] == ["text_to_speech"]

    assert %{"data" => []} =
             :get
             |> conn("/v1/models")
             |> call_router(router_opts(stt_backend: MissingBackend, tts_backend: MissingBackend))
             |> json_body()
  end

  test "speech endpoint requires local runtime token and returns bounded audio" do
    Auth.ensure_token!()

    unauthorized =
      :post
      |> conn("/v1/audio/speech", Jason.encode!(%{"model" => "tts-local", "input" => "hello"}))
      |> put_req_header("content-type", "application/json")
      |> call_router(router_opts())

    assert unauthorized.status == 401

    authorized =
      :post
      |> conn("/v1/audio/speech", Jason.encode!(%{"model" => "tts-local", "input" => "hello"}))
      |> put_req_header("content-type", "application/json")
      |> put_req_header(Auth.header_name(), Auth.ensure_token!())
      |> call_router(router_opts())

    assert authorized.status == 200
    assert authorized.resp_body == <<"RIFF", 0::32, "WAVE">>
  end

  test "transcription endpoint accepts authorized multipart upload" do
    Auth.ensure_token!()
    audio_path = Path.join(Paths.tmp_root(), "local-runtime-router.wav")
    File.mkdir_p!(Path.dirname(audio_path))
    File.write!(audio_path, <<"RIFF", 0::32, "WAVE">>)

    upload = %Plug.Upload{path: audio_path, filename: "voice.wav", content_type: "audio/wav"}

    response =
      :post
      |> conn("/v1/audio/transcriptions", %{"model" => "whisper-local", "file" => upload})
      |> put_req_header(Auth.header_name(), Auth.ensure_token!())
      |> call_router(router_opts())

    assert response.status == 200
    assert %{"text" => "voice testing one two three"} = json_body(response)
  end

  test "local provider HTTP attaches the Allbert local runtime token" do
    token = Auth.ensure_token!()

    assert {:ok, endpoint} =
             ProviderHTTP.endpoint(
               %{
                 provider_endpoint_kind: "local_endpoint",
                 provider_base_url: "http://127.0.0.1:5050/v1"
               },
               "/models"
             )

    assert {Auth.header_name(), token} in endpoint.headers
  end

  test "local runtime server starts a Bandit loopback endpoint" do
    port = free_loopback_port()

    assert {:ok, %{pid: pid, config: %{base_url: base_url}}} =
             Server.start(router_opts(port: port))

    on_exit(fn ->
      if Process.alive?(pid), do: Process.exit(pid, :normal)
    end)

    assert base_url == "http://127.0.0.1:#{port}/v1"

    assert {:ok, %{status: 200, body: %{"data" => data}}} =
             Req.get("#{base_url}/models", retry: false)

    assert Enum.map(data, & &1["id"]) == ["whisper-local", "tts-local"]
  end

  test "Ollama STT backend doctors and transcribes through OpenAI-compatible local routes" do
    Req.Test.stub(__MODULE__, fn
      %{request_path: "/v1/models"} = conn ->
        Req.Test.json(conn, %{"data" => [%{"id" => "gemma4:e2b"}]})

      %{request_path: "/v1/audio/transcriptions"} = conn ->
        conn
        |> Plug.Conn.put_resp_content_type("application/x-ndjson")
        |> Plug.Conn.send_resp(
          200,
          Jason.encode!(%{"text" => "local transcript", "duration" => 1.2})
        )
    end)

    config = Config.build(enabled?: true, req_options: [plug: {Req.Test, __MODULE__}])
    assert %{available?: true, diagnostic_codes: []} = OllamaSTT.doctor(config)

    audio_path = Path.join(Paths.tmp_root(), "ollama-stt.wav")
    File.mkdir_p!(Path.dirname(audio_path))
    File.write!(audio_path, <<"RIFF", 0::32, "WAVE">>)

    assert {:ok, %{transcript: "local transcript", duration_ms: 1200}} =
             OllamaSTT.transcribe(audio_path, %{}, config)
  end

  test "loopback URL validation rejects non-loopback backends" do
    assert_raise ArgumentError, ~r/must point to loopback/, fn ->
      Config.validate_loopback_base_url!("http://192.168.1.10:11434/v1")
    end

    assert_raise ArgumentError, ~r/must not contain credentials/, fn ->
      Config.validate_loopback_base_url!("http://user:pass@127.0.0.1:11434/v1")
    end
  end

  test "local runtime facade refuses unavailable local backend" do
    assert {:error, {:local_voice_backend_unavailable, :speech_to_text, [:missing]}} =
             LocalRuntime.transcribe(
               "missing.wav",
               %{"model" => "whisper-local"},
               Config.build(router_opts(stt_backend: MissingBackend))
             )
  end

  defp router_opts(overrides \\ []) do
    Keyword.merge(
      [
        enabled?: true,
        stt_backend: STTBackend,
        tts_backend: TTSBackend,
        say_executable: "/usr/bin/say",
        ffmpeg_executable: "/usr/local/bin/ffmpeg"
      ],
      overrides
    )
  end

  defp call_router(conn, opts), do: Router.call(conn, Router.init(opts))

  defp json_body(conn), do: Jason.decode!(conn.resp_body)

  defp free_loopback_port do
    {:ok, socket} = :gen_tcp.listen(0, [:binary, active: false, ip: {127, 0, 0, 1}])
    {:ok, {{127, 0, 0, 1}, port}} = :inet.sockname(socket)
    :ok = :gen_tcp.close(socket)
    port
  end
end
