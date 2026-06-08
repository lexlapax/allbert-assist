defmodule Allbert.V049VisionLiveSmoke do
  @moduledoc false

  alias AllbertAssist.Actions.Runner
  alias AllbertAssist.Resources.{ImageMetadata, ResourceURI}
  alias AllbertAssist.Runtime.Redactor
  alias AllbertAssist.Settings
  alias AllbertAssist.Settings.Secrets

  @providers ~w[openai gemini]
  @default_prompt "Describe the validation image in one concise sentence."
  @default_image_prompt "Generate a simple 1024x1024 validation image of a labeled blue square."

  def run(argv) do
    unless System.get_env("ALLBERT_V049_LIVE_SMOKE") == "1" do
      Mix.raise("""
      Refusing to run live vision/image smoke without ALLBERT_V049_LIVE_SMOKE=1.

      This script can upload an image to the selected provider and can run
      billable image generation. Use a disposable ALLBERT_HOME.
      """)
    end

    home = validate_allbert_home!()
    provider = System.get_env("ALLBERT_V049_PROVIDER") || "openai"
    validate_provider!(provider)

    image_file =
      System.get_env("ALLBERT_V049_IMAGE")
      |> Kernel.||(List.first(argv))
      |> validate_image_file!()

    context = context(provider)

    Mix.Task.run("app.start")

    configure_provider!(provider)
    configure_media_loop!(provider)

    Mix.shell().info("Provider: #{provider}")
    Mix.shell().info("Image file: [redacted local path]")
    Mix.shell().info("ALLBERT_HOME: #{home}")

    vision_doctor = doctor!(vision_profile(provider), context)
    image_doctor = doctor!(image_profile(provider), context)
    vision_response = vision!(image_file, provider, context)
    approved_image = generate_image!(context)

    evidence =
      evidence(
        provider,
        home,
        image_file,
        vision_doctor,
        image_doctor,
        vision_response,
        approved_image
      )

    path = write_evidence!(home, evidence)
    Mix.shell().info("v0.49 live vision/image smoke completed.")
    Mix.shell().info("Evidence: #{path}")
  end

  defp validate_allbert_home! do
    home = System.get_env("ALLBERT_HOME")

    unless is_binary(home) and String.trim(home) != "" do
      Mix.raise("Set ALLBERT_HOME to a disposable temporary directory before running this smoke.")
    end

    expanded = Path.expand(home)
    real_home = Path.expand("~/.allbert")
    tmp_roots = [System.tmp_dir!(), "/tmp", "/private/tmp"] |> Enum.map(&Path.expand/1)

    cond do
      expanded == real_home ->
        Mix.raise("Refusing to use real ~/.allbert for live smoke validation.")

      not Enum.any?(tmp_roots, &tmp_child?(expanded, &1)) ->
        Mix.raise("ALLBERT_HOME must be under a temporary directory for live smoke validation.")

      true ->
        expanded
    end
  end

  defp tmp_child?(path, root), do: path == root or String.starts_with?(path, root <> "/")

  defp validate_provider!(provider) when provider in @providers, do: :ok

  defp validate_provider!(other) do
    Mix.raise("Unknown ALLBERT_V049_PROVIDER=#{inspect(other)}; expected openai or gemini.")
  end

  defp validate_image_file!(image_file) when is_binary(image_file) do
    image_file = image_file |> String.trim() |> Path.expand()

    if File.regular?(image_file) do
      image_file
    else
      Mix.raise("Image file does not exist: #{image_file}")
    end
  end

  defp validate_image_file!(_image_file) do
    Mix.raise("Set ALLBERT_V049_IMAGE=/path/to/input.png or pass the image path as argv[0].")
  end

  defp configure_provider!("openai") do
    put!("providers.openai.enabled", true)
    put_secret_from_env!("secret://providers/openai/api_key", "OPENAI_API_KEY")
  end

  defp configure_provider!("gemini") do
    put!("providers.gemini.enabled", true)
    put_secret_from_env!("secret://providers/gemini/api_key", "GEMINI_API_KEY", "GOOGLE_API_KEY")
  end

  defp configure_media_loop!(provider) do
    put!("intent.direct_answer_model_enabled", true)
    put!("vision.enabled", true)
    put!("image.enabled", true)
    put!("model_preferences.capabilities.vision_input", [vision_profile(provider)])
    put!("model_preferences.capabilities.image_generation", [image_profile(provider)])
  end

  defp doctor!(profile, context) do
    response =
      run!("doctor_model_profile", %{profile: profile}, context, fn response ->
        response.status == :completed
      end)

    doctor = response.doctor

    Mix.shell().info(
      "Doctor #{profile}: endpoint_ok=#{doctor.endpoint_ok} model_available=#{inspect(doctor.model_available)} host=#{doctor.redacted_host}"
    )

    unless doctor.endpoint_ok == true and doctor.model_available == true do
      Mix.raise("""
      Doctor #{profile} is not live-smoke ready.

      Expected endpoint_ok=true and model_available=true before invoking provider calls.
      Doctor response:
      #{inspect(doctor, pretty: true)}
      """)
    end

    response
  end

  defp vision!(image_file, provider, context) do
    image_metadata = image_metadata!(image_file, provider)

    response =
      run!(
        "direct_answer",
        %{text: System.get_env("ALLBERT_V049_VISION_PROMPT") || @default_prompt},
        put_in(context, [:request, :metadata], %{image_inputs: [image_metadata]}),
        fn response ->
          response.status == :completed and
            get_in(response, [:direct_answer, :source]) == :model and
            get_in(response, [:direct_answer, :model_profile]) == vision_profile(provider)
        end
      )

    Mix.shell().info(
      "Vision #{vision_profile(provider)}: answer_chars=#{String.length(response.message)}"
    )

    response
  end

  defp image_metadata!(image_file, provider) do
    {:ok, resource_uri} = ResourceURI.image_capture("live_#{provider}_#{short_hash(image_file)}")

    case ImageMetadata.from_path(image_file,
           resource_uri: resource_uri,
           filename: Path.basename(image_file),
           transient?: false
         ) do
      {:ok, metadata} -> metadata
      {:error, reason} -> Mix.raise("Image metadata extraction failed: #{inspect(reason)}")
    end
  end

  defp generate_image!(context) do
    prompt = System.get_env("ALLBERT_V049_IMAGE_PROMPT") || @default_image_prompt

    pending =
      run!("generate_image", %{prompt: prompt}, context, fn response ->
        response.status == :needs_confirmation
      end)

    Mix.shell().info("Image generation confirmation: #{pending.confirmation_id}")

    approved =
      run!(
        "approve_confirmation",
        %{id: pending.confirmation_id, reason: "v0.49 live image smoke"},
        context,
        fn response -> response.status == :completed end
      )

    output_data = output_data(approved)
    image_file = field(output_data, :image_file)

    unless is_binary(image_file) and File.regular?(image_file) do
      Mix.raise(
        "Image approval completed but did not return an existing image_file in transient output_data: #{inspect(output_data, pretty: true)}"
      )
    end

    Mix.shell().info("Generated image: [redacted local path]")
    Mix.shell().info("Generated resource: #{field(output_data, :output_resource_uri) || "none"}")
    approved
  end

  defp evidence(
         provider,
         home,
         input_image_file,
         vision_doctor,
         image_doctor,
         vision_response,
         approved_image
       ) do
    output_data = output_data(approved_image)

    evidence = %{
      version: "0.49.0",
      provider: provider,
      allbert_home: home,
      profiles: %{
        vision_input: vision_profile(provider),
        image_generation: image_profile(provider)
      },
      doctors: %{
        vision_input: doctor_summary(vision_doctor),
        image_generation: doctor_summary(image_doctor)
      },
      vision_input: %{
        status: vision_response.status,
        answer_chars: String.length(vision_response.message || ""),
        direct_answer: direct_answer_summary(vision_response)
      },
      image_generation: %{
        status: field(output_data, :status),
        output_resource_uri: field(output_data, :output_resource_uri),
        image_metadata: output_data |> field(:image_metadata) |> Redactor.redact_image_metadata(),
        confirmation: confirmation_summary(approved_image)
      },
      redaction_scan: %{
        evidence_contains_secret?: false,
        evidence_contains_input_path?: false,
        evidence_contains_generated_path?: false
      }
    }

    redaction_scan!(provider, evidence, input_image_file, output_data)
  end

  defp doctor_summary(response) do
    doctor = response.doctor

    %{
      profile: response.profile,
      provider: response.provider,
      model: response.model,
      endpoint_kind: doctor.endpoint_kind,
      endpoint_ok: doctor.endpoint_ok,
      model_available: doctor.model_available,
      redacted_host: doctor.redacted_host,
      diagnostics: doctor.diagnostics
    }
  end

  defp direct_answer_summary(response) do
    answer = response.direct_answer

    %{
      source: answer.source,
      model_profile: answer.model_profile,
      provider: answer.provider,
      model: answer.model,
      media: Map.get(answer, :media)
    }
  end

  defp confirmation_summary(response) do
    confirmation = response.confirmation || %{}
    resolution = Map.get(confirmation, "operator_resolution", %{})

    %{
      id: field(confirmation, :id),
      status: field(confirmation, :status),
      target_resumed?: Map.get(resolution, "target_resumed?"),
      target_status: Map.get(resolution, "target_status")
    }
  end

  defp redaction_scan!(provider, evidence, input_image_file, output_data) do
    encoded = Jason.encode!(json_safe(evidence))
    secret_values = provider_secret_values(provider)
    generated_path = field(output_data, :image_file)

    leaks = %{
      evidence_contains_secret?: Enum.any?(secret_values, &String.contains?(encoded, &1)),
      evidence_contains_input_path?:
        is_binary(input_image_file) and String.contains?(encoded, input_image_file),
      evidence_contains_generated_path?:
        is_binary(generated_path) and String.contains?(encoded, generated_path)
    }

    if Enum.any?(Map.values(leaks), &(&1 == true)) do
      Mix.raise("Live-smoke evidence failed redaction scan: #{inspect(leaks)}")
    end

    put_in(evidence, [:redaction_scan], leaks)
  end

  defp write_evidence!(home, evidence) do
    dir = Path.join(home, "release_evidence/v049")
    File.mkdir_p!(dir)

    path =
      Path.join(
        dir,
        "live-vision-#{evidence.provider}-#{DateTime.utc_now() |> DateTime.to_unix()}.json"
      )

    File.write!(path, Jason.encode!(json_safe(evidence), pretty: true))
    path
  end

  defp json_safe(%{} = map) do
    Map.new(map, fn {key, value} -> {json_key(key), json_safe(value)} end)
  end

  defp json_safe(values) when is_list(values), do: Enum.map(values, &json_safe/1)
  defp json_safe(nil), do: nil
  defp json_safe(value) when is_boolean(value), do: value
  defp json_safe(value) when is_atom(value), do: Atom.to_string(value)
  defp json_safe(value), do: value

  defp json_key(key) when is_atom(key), do: Atom.to_string(key)
  defp json_key(key), do: key

  defp run!(action, params, context, ok?) do
    case Runner.run(action, params, context) do
      {:ok, response} ->
        if ok?.(response) do
          response
        else
          Mix.raise("#{action} returned unexpected response: #{inspect(response, pretty: true)}")
        end

      {:error, reason} ->
        Mix.raise("#{action} failed: #{inspect(reason)}")
    end
  end

  defp output_data(response), do: field(response, :output_data) || %{}

  defp field(map, key) when is_map(map) and is_atom(key) do
    Map.get(map, key) || Map.get(map, Atom.to_string(key))
  end

  defp field(map, key) when is_map(map), do: Map.get(map, key)
  defp field(_value, _key), do: nil

  defp put!(key, value) do
    case Settings.put(key, value, %{audit?: false}) do
      {:ok, _setting} -> :ok
      {:error, reason} -> Mix.raise("Failed to set #{key}: #{inspect(reason)}")
    end
  end

  defp put_secret_from_env!(ref, primary_env, fallback_env \\ nil) do
    value =
      System.get_env(primary_env) ||
        if(is_binary(fallback_env), do: System.get_env(fallback_env), else: nil)

    unless is_binary(value) and String.trim(value) != "" do
      env_names = [primary_env, fallback_env] |> Enum.reject(&is_nil/1) |> Enum.join(" or ")
      Mix.raise("Missing #{env_names} for #{ref}.")
    end

    case Secrets.put_secret(ref, value, %{audit?: false}) do
      {:ok, _secret} -> :ok
      {:error, reason} -> Mix.raise("Failed to store #{ref}: #{inspect(reason)}")
    end
  end

  defp provider_secret_values("openai"), do: secret_env_values(["OPENAI_API_KEY"])

  defp provider_secret_values("gemini"),
    do: secret_env_values(["GEMINI_API_KEY", "GOOGLE_API_KEY"])

  defp secret_env_values(names) do
    names
    |> Enum.map(&System.get_env/1)
    |> Enum.filter(&(is_binary(&1) and String.trim(&1) != ""))
  end

  defp context(provider) do
    %{
      actor: "local",
      channel: :cli,
      surface: "scripts/v049_vision_live_smoke.exs",
      request: %{operator_id: "local", channel: :cli, provider: provider}
    }
  end

  defp short_hash(path) do
    :crypto.hash(:sha256, path)
    |> Base.encode16(case: :lower)
    |> binary_part(0, 12)
  end

  defp vision_profile("openai"), do: "vision_openai"
  defp vision_profile("gemini"), do: "vision_gemini"

  defp image_profile("openai"), do: "image_openai"
  defp image_profile("gemini"), do: "image_gemini"
end

Allbert.V049VisionLiveSmoke.run(System.argv())
