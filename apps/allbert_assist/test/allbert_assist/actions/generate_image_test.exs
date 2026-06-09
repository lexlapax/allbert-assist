defmodule AllbertAssist.Actions.GenerateImageTest do
  use ExUnit.Case, async: false
  @moduletag :external_runtime_serial

  alias AllbertAssist.Actions.Image.GenerateImage
  alias AllbertAssist.Actions.Runner
  alias AllbertAssist.Artifacts
  alias AllbertAssist.Artifacts.MetadataIndex
  alias AllbertAssist.Artifacts.Store
  alias AllbertAssist.Paths
  alias AllbertAssist.Settings
  alias AllbertAssist.Settings.Secrets

  setup {Req.Test, :verify_on_exit!}

  @png Base.decode64!(
         "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADElEQVR42mNk+M9QDwADhgGAWjR9awAAAABJRU5ErkJggg=="
       )
  @jpeg <<0xFF, 0xD8, 0xFF, 0xC0, 0x00, 0x11, 0x08, 0x00, 0x01, 0x00, 0x01, 0x03, 0x01, 0x11,
          0x00, 0x02, 0x11, 0x00, 0x03, 0x11, 0x00, 0xFF, 0xD9>>

  @env_vars [
    "ALLBERT_HOME",
    "ALLBERT_HOME_DIR",
    "ALLBERT_SETTINGS_ROOT",
    "ALLBERT_SETTINGS_MASTER_KEY",
    "OPENAI_API_KEY",
    "OLLAMA_BASE_URL"
  ]

  setup do
    original_env = Map.new(@env_vars, &{&1, System.get_env(&1)})
    original_paths_config = Application.get_env(:allbert_assist, Paths)
    original_settings_config = Application.get_env(:allbert_assist, Settings)

    Enum.each(@env_vars, &System.delete_env/1)
    Application.delete_env(:allbert_assist, Paths)
    Application.delete_env(:allbert_assist, Settings)

    home =
      Path.join(
        System.tmp_dir!(),
        "allbert-generate-image-#{System.unique_integer([:positive])}"
      )

    System.put_env("ALLBERT_HOME", home)
    MetadataIndex.reset_cache!()

    on_exit(fn ->
      MetadataIndex.reset_cache!()
      File.rm_rf!(home)
      restore_env(original_env)
      restore_app_env(Paths, original_paths_config)
      restore_app_env(Settings, original_settings_config)
    end)

    {:ok, home: home}
  end

  test "fake image provider writes bounded output and redacted metadata", %{home: home} do
    enable_image!()
    use_fake_image!()

    assert {:ok, response} = GenerateImage.run(%{prompt: "draw a small square"}, context())

    assert response.status == :completed
    assert response.permission_decision.decision == :allowed
    assert response.image_file =~ Path.join([home, "tmp", "generated-images"])
    assert File.regular?(response.image_file)
    assert {:ok, "PNG"} = png_signature(response.image_file)
    assert response.output_resource_uri == "file://[REDACTED_IMAGE_PATH]"
    assert response.image_metadata.output_resource_uri == "file://[REDACTED_IMAGE_PATH]"
    assert response.image_metadata.generated_resource_uri == "file://[REDACTED_IMAGE_PATH]"
    assert response.image_metadata.provider_profile == "image_fake"
    assert response.image_metadata.provider == "fake_media"
    assert response.image_metadata.model == "fixture-image"
    assert response.image_metadata.image_format == "png"
    assert response.image_metadata.mime_type == "image/png"
    assert response.image_metadata.width == 1
    assert response.image_metadata.height == 1
    assert response.image_metadata.usage == %{source: :fixture}
    assert response.image_metadata.cost == %{source: :unavailable}
    assert response.image_metadata.redaction_status == "metadata_only"
    refute Map.has_key?(response.image_metadata, :path)

    assert [%{name: "generate_image", status: :completed, image_metadata: action_metadata}] =
             response.actions

    assert action_metadata.output_resource_uri == "file://[REDACTED_IMAGE_PATH]"
  end

  test "retained generated image output writes through Artifacts Central", %{home: home} do
    enable_image!()
    enable_artifacts!()
    use_fake_image!()

    assert {:ok, _setting} =
             Settings.put("image.generation.retention_enabled", true, %{audit?: false})

    assert {:ok, response} = GenerateImage.run(%{prompt: "draw retained image"}, context())

    assert response.status == :completed
    assert response.image_file =~ Path.join([home, "artifacts", "objects"])
    refute response.image_file =~ Path.join(home, "generated_images")
    assert File.regular?(response.image_file)

    assert {:ok, artifacts} = Artifacts.list(origin: "retained_generated_image")
    assert [%{sha256: sha256, metadata: metadata}] = artifacts
    assert metadata.mime == "image/png"
    assert metadata.provenance["media_retention"]["kind"] == "generated_image"
    assert response.image_file == Store.object_path!(sha256)
  end

  test "image generation is default-off until operator enables it" do
    assert {:ok, response} = GenerateImage.run(%{prompt: "hello"}, context())

    assert response.status == :denied
    assert response.error == :image_generation_disabled
    refute Map.has_key?(response, :image_file)
  end

  test "remote image provider requires confirmation before generation" do
    enable_image!()
    use_openai_image!()

    assert {:ok, pending} =
             Runner.run(
               "generate_image",
               %{prompt: "confirmation image"},
               context()
             )

    assert pending.status == :needs_confirmation
    assert pending.confirmation_id
    assert pending.permission_decision.decision == :needs_confirmation
    assert pending.image_metadata.provider_profile == "image_openai"
    refute pending.image_metadata[:prompt]
  end

  test "approved remote image confirmation returns redacted generated image output", %{home: home} do
    enable_image!()
    use_openai_image!()

    assert {:ok, _secret} =
             Secrets.put_secret("secret://providers/openai/api_key", "sk-test-openai", %{
               audit?: false
             })

    assert {:ok, pending} =
             Runner.run(
               "generate_image",
               %{prompt: "confirmation output image"},
               context()
             )

    assert pending.status == :needs_confirmation
    assert pending.confirmation_id

    Req.Test.expect(__MODULE__, fn %{request_path: "/v1/images/generations"} = conn ->
      assert Plug.Conn.get_req_header(conn, "authorization") == ["Bearer sk-test-openai"]

      {:ok, body, conn} = Plug.Conn.read_body(conn)
      decoded = Jason.decode!(body)
      assert decoded["model"] == "gpt-image-1.5"
      assert decoded["prompt"] == "confirmation output image"

      conn
      |> Plug.Conn.put_resp_content_type("application/json")
      |> Plug.Conn.send_resp(
        200,
        Jason.encode!(%{"data" => [%{"b64_json" => Base.encode64(@png)}]})
      )
    end)

    assert {:ok, approved} =
             Runner.run(
               "approve_confirmation",
               %{id: pending.confirmation_id, reason: "fixture image approval"},
               Map.put(context(), :req_http_options, plug: {Req.Test, __MODULE__})
             )

    assert approved.status == :completed
    assert approved.output_data.status == :completed
    assert approved.output_data.image_file =~ Path.join([home, "tmp", "generated-images"])
    assert File.regular?(approved.output_data.image_file)
    assert approved.output_data.output_resource_uri == "file://[REDACTED_IMAGE_PATH]"

    assert [%{kind: :image, local_path: image_path, mime_type: "image/png"}] =
             approved.media_outputs

    assert image_path == approved.output_data.image_file

    assert approved.output_data.image_metadata.output_resource_uri ==
             "file://[REDACTED_IMAGE_PATH]"

    assert approved.output_data.image_metadata.provider_profile == "image_openai"
    assert approved.confirmation["operator_resolution"]["target_resumed?"] == true
    assert approved.confirmation["operator_resolution"]["target_status"] == "completed"
  end

  test "approved remote image output accepts safe provider-returned format", %{home: home} do
    enable_image!()
    use_openai_image!()

    assert {:ok, _secret} =
             Secrets.put_secret("secret://providers/openai/api_key", "sk-test-openai", %{
               audit?: false
             })

    assert {:ok, pending} =
             Runner.run(
               "generate_image",
               %{prompt: "confirmation jpeg output"},
               context()
             )

    assert pending.status == :needs_confirmation

    Req.Test.expect(__MODULE__, fn %{request_path: "/v1/images/generations"} = conn ->
      {:ok, body, conn} = Plug.Conn.read_body(conn)
      decoded = Jason.decode!(body)

      assert decoded["model"] == "gpt-image-1.5"
      assert decoded["prompt"] == "confirmation jpeg output"

      conn
      |> Plug.Conn.put_resp_content_type("application/json")
      |> Plug.Conn.send_resp(
        200,
        Jason.encode!(%{
          "data" => [%{"b64_json" => Base.encode64(@jpeg), "media_type" => "image/jpeg"}]
        })
      )
    end)

    assert {:ok, approved} =
             Runner.run(
               "approve_confirmation",
               %{id: pending.confirmation_id, reason: "provider returned jpeg"},
               Map.put(context(), :req_http_options, plug: {Req.Test, __MODULE__})
             )

    assert approved.status == :completed
    assert approved.output_data.status == :completed
    assert approved.output_data.image_file =~ Path.join([home, "tmp", "generated-images"])
    assert Path.extname(approved.output_data.image_file) == ".jpeg"
    assert File.regular?(approved.output_data.image_file)
    assert approved.output_data.image_metadata.provider_profile == "image_openai"
    assert approved.output_data.image_metadata.image_format == "jpeg"
    assert approved.output_data.image_metadata.mime_type == "image/jpeg"
    assert approved.confirmation["operator_resolution"]["target_status"] == "completed"
  end

  test "approved local Ollama image output omits OpenAI output_format", %{home: home} do
    enable_image!()
    use_ollama_image!()
    System.put_env("OPENAI_API_KEY", "sk-test-must-not-leak")

    Req.Test.expect(__MODULE__, fn %{request_path: "/v1/images/generations"} = conn ->
      assert Plug.Conn.get_req_header(conn, "authorization") == ["Bearer ollama"]

      {:ok, body, conn} = Plug.Conn.read_body(conn)
      decoded = Jason.decode!(body)

      assert decoded["model"] == "x/z-image-turbo"
      assert decoded["prompt"] == "local ollama image"
      refute Map.has_key?(decoded, "output_format")

      conn
      |> Plug.Conn.put_resp_content_type("application/json")
      |> Plug.Conn.send_resp(
        200,
        Jason.encode!(%{"data" => [%{"b64_json" => Base.encode64(@png)}]})
      )
    end)

    assert {:ok, response} =
             GenerateImage.run(
               %{prompt: "local ollama image"},
               approved_context(req_http_options: [plug: {Req.Test, __MODULE__}])
             )

    assert response.status == :completed
    assert response.image_file =~ Path.join([home, "tmp", "generated-images"])
    assert File.regular?(response.image_file)
    assert response.image_metadata.provider_profile == "image_ollama"
    assert response.image_metadata.provider == "local_ollama"
    assert response.image_metadata.model == "x/z-image-turbo"
    assert response.image_metadata.image_format == "png"
    assert response.image_metadata.mime_type == "image/png"
  end

  test "approved retryable provider failure falls back once to next candidate" do
    enable_image!()
    use_openai_then_fake_image!()

    assert {:ok, _secret} =
             Secrets.put_secret("secret://providers/openai/api_key", "sk-test-openai", %{
               audit?: false
             })

    Req.Test.expect(__MODULE__, fn %{request_path: "/v1/images/generations"} = conn ->
      conn
      |> Plug.Conn.put_resp_content_type("application/json")
      |> Plug.Conn.send_resp(500, Jason.encode!(%{"error" => %{"message" => "try later"}}))
    end)

    assert {:ok, response} =
             GenerateImage.run(
               %{prompt: "fallback image"},
               approved_context(req_http_options: [plug: {Req.Test, __MODULE__}])
             )

    assert response.status == :completed
    assert response.image_metadata.provider_profile == "image_fake"
    assert [%{provider_profile: "image_openai"}] = response.image_metadata.fallback_attempts
  end

  defp enable_image! do
    assert {:ok, _resolved} = Settings.put("image.enabled", true, %{audit?: false})
  end

  defp enable_artifacts! do
    assert {:ok, _setting} = Settings.put("artifacts.enabled", true, %{audit?: false})
    assert {:ok, _setting} = Settings.put("artifacts.retention_enabled", true, %{audit?: false})
  end

  defp use_fake_image! do
    assert {:ok, _setting} =
             Settings.put("model_preferences.capabilities.image_generation", ["image_fake"], %{
               audit?: false
             })
  end

  defp use_openai_image! do
    assert {:ok, _provider} = Settings.put("providers.openai.enabled", true, %{audit?: false})

    assert {:ok, _setting} =
             Settings.put(
               "model_preferences.capabilities.image_generation",
               ["image_openai"],
               %{audit?: false}
             )
  end

  defp use_openai_then_fake_image! do
    assert {:ok, _provider} = Settings.put("providers.openai.enabled", true, %{audit?: false})

    assert {:ok, _setting} =
             Settings.put(
               "model_preferences.capabilities.image_generation",
               ["image_openai", "image_fake"],
               %{audit?: false}
             )
  end

  defp use_ollama_image! do
    assert {:ok, _setting} =
             Settings.put(
               "model_preferences.capabilities.image_generation",
               ["image_ollama"],
               %{audit?: false}
             )
  end

  defp context do
    %{actor: "local", channel: :cli, request: %{operator_id: "local", channel: :cli}}
  end

  defp approved_context(extra) do
    context()
    |> Map.merge(Map.new(extra))
    |> Map.put(:confirmation, %{approved?: true})
  end

  defp png_signature(path) do
    with {:ok, <<0x89, signature::binary-size(3), _rest::binary>>} <- File.read(path) do
      {:ok, signature}
    end
  end

  defp restore_env(env) do
    Enum.each(env, fn
      {key, nil} -> System.delete_env(key)
      {key, value} -> System.put_env(key, value)
    end)
  end

  defp restore_app_env(module, nil), do: Application.delete_env(:allbert_assist, module)
  defp restore_app_env(module, value), do: Application.put_env(:allbert_assist, module, value)
end
