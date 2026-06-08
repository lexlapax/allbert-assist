defmodule AllbertAssist.Actions.Image.GenerateImage do
  @moduledoc false

  use AllbertAssist.Action,
    permission: :image_generate,
    exposure: :agent,
    execution_mode: :image_provider_call,
    skill_backed?: false,
    confirmation: :required,
    resumable?: true,
    name: "generate_image",
    description: "Generate a bounded image through an image-generation profile.",
    category: "image",
    tags: ["image", "image_generation", "text_to_image"],
    schema: [
      prompt: [type: :string, required: true],
      output_format: [type: :string, required: false],
      size: [type: :string, required: false]
    ],
    output_schema: [
      message: [type: :string, required: true],
      status: [type: :atom, required: true],
      actions: [type: {:list, :map}, required: true]
    ]

  alias AllbertAssist.Confirmations
  alias AllbertAssist.Confirmations.Origin
  alias AllbertAssist.Artifacts.MediaRetention
  alias AllbertAssist.Resources.{ImageBounds, ImageMetadata, ResourceURI}
  alias AllbertAssist.Runtime.Paths, as: RuntimePaths
  alias AllbertAssist.Runtime.Redactor
  alias AllbertAssist.Security.PermissionGate
  alias AllbertAssist.Settings
  alias AllbertAssist.Settings.{ModelRuntime, Models, Schema, Store}

  @permission :image_generate
  @action_name "generate_image"
  @default_format "png"
  @fixture_png Base.decode64!(
                 "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADElEQVR42mNk+M9QDwADhgGAWjR9awAAAABJRU5ErkJggg=="
               )

  @impl true
  def run(params, context) do
    with {:ok, prompt} <- prompt(params),
         :ok <- image_enabled?(),
         {:ok, resolutions} <- Models.candidates_for(:image_generation, context) do
      run_allowed(prompt, resolutions, context, params)
    else
      {:error, reason} ->
        {:ok, failed(reason, nil, %{})}
    end
  end

  defp run_allowed(prompt, resolutions, context, params) do
    with {:ok, settings, _user_settings} <- Store.resolved_settings() do
      attempt_generation(resolutions, prompt, settings, context, params, [])
    else
      {:error, reason} ->
        {:ok, failed(reason, nil, %{})}
    end
  end

  defp attempt_generation([resolution | rest], prompt, settings, context, params, attempts) do
    permission_decision =
      PermissionGate.authorize(@permission, image_context(context, resolution.profile))

    cond do
      permission_decision.decision == :denied ->
        {:ok,
         stopped(permission_decision, :permission_denied, %{
           provider_attempts: Enum.reverse(attempts)
         })}

      PermissionGate.allowed?(permission_decision) or approved_resume?(context) ->
        attempt_allowed_generation(
          resolution,
          rest,
          prompt,
          settings,
          context,
          params,
          attempts,
          permission_decision
        )

      permission_decision.decision == :needs_confirmation ->
        create_confirmation(prompt, resolution, params, attempts, context, permission_decision)

      true ->
        {:ok,
         stopped(permission_decision, :permission_denied, %{
           provider_attempts: Enum.reverse(attempts)
         })}
    end
  end

  defp attempt_generation([], _prompt, _settings, _context, _params, attempts),
    do:
      {:ok,
       failed(:image_provider_candidates_exhausted, nil, %{
         provider_attempts: Enum.reverse(attempts)
       })}

  defp attempt_allowed_generation(
         resolution,
         rest,
         prompt,
         settings,
         context,
         params,
         attempts,
         permission_decision
       ) do
    with {:ok, output_format} <- output_format(resolution.profile, params),
         {:ok, generated} <- generate(resolution.profile, prompt, output_format, context, params),
         {:ok, output} <-
           generated_image_metadata(
             generated,
             resolution,
             output_format,
             settings,
             context,
             attempts
           ) do
      {:ok, completed(output, permission_decision)}
    else
      {:error, reason} ->
        attempts = [attempt_record(resolution, reason) | attempts]

        if retryable_provider_error?(reason) and rest != [] do
          attempt_generation(rest, prompt, settings, context, params, attempts)
        else
          {:ok,
           failed(reason, permission_decision, %{
             provider_attempts: Enum.reverse(attempts)
           })}
        end
    end
  end

  defp generate(
         %{provider_type: "fake_media"} = profile,
         _prompt,
         output_format,
         _context,
         _params
       ) do
    if "image_generation" in Map.get(profile, :capabilities, []) and output_format == "png" do
      {:ok,
       %{
         bytes: @fixture_png,
         mime_type: "image/png",
         usage: %{source: :fixture},
         cost: %{source: :unavailable}
       }}
    else
      {:error, {:unsupported_fake_media_image_generation, profile.name, output_format}}
    end
  end

  defp generate(profile, prompt, output_format, context, params) do
    with :ok <- ensure_req_llm!(),
         {:ok, model} <- ModelRuntime.model_spec(profile),
         {:ok, response} <-
           generate_image_response(
             profile,
             model,
             prompt,
             request_opts(profile, context, output_format, params)
           ),
         {:ok, bytes, mime_type} <- image_bytes(response, output_format) do
      {:ok,
       %{
         bytes: bytes,
         mime_type: mime_type,
         usage: usage(response) || %{source: :unavailable},
         cost: %{source: :unavailable}
       }}
    else
      {:error, reason} -> {:error, reason}
    end
  end

  defp generate_image_response(%{provider_type: "openai_compatible"}, model, prompt, opts) do
    with {:ok, model} <- ReqLLM.model(model),
         {:ok, provider_module} <- ReqLLM.provider(model.provider),
         {:ok, request} <- provider_module.prepare_request(:image, model, prompt, opts),
         request <- Req.Request.merge_options(request, output_format: nil),
         {:ok, %Req.Response{status: status, body: response}} when status in 200..299 <-
           Req.request(request) do
      {:ok, response}
    else
      {:ok, %Req.Response{status: status, body: body}} ->
        {:error,
         ReqLLM.Error.API.Request.exception(
           reason: "HTTP #{status}: Request failed",
           status: status,
           response_body: body
         )}

      {:error, error} ->
        {:error, error}
    end
  end

  defp generate_image_response(_profile, model, prompt, opts) do
    with {:ok, model} <- ReqLLM.model(model) do
      ReqLLM.generate_image(model, prompt, opts)
    end
  end

  defp generated_image_metadata(generated, resolution, output_format, settings, context, attempts) do
    with {:ok, storage_format} <- generated_storage_format(generated, output_format),
         {:ok, path} <- write_generated_image(generated.bytes, storage_format, settings, context),
         {:ok, resource_uri} <- ResourceURI.file(path),
         {:ok, metadata} <-
           ImageMetadata.from_path(path,
             max_bytes: image_read_max_bytes(resolution.profile, settings),
             resource_uri: resource_uri,
             filename: Path.basename(path),
             transient?: image_retention_enabled?(settings) != true
           ),
         mime_type <- generated_mime_type(generated, metadata),
         metadata <-
           metadata
           |> Map.put(:generated_resource_uri, resource_uri)
           |> Map.put(:output_resource_uri, resource_uri)
           |> Map.put(:provider_profile, resolution.profile_name)
           |> Map.put(:provider, Map.get(resolution.profile, :provider))
           |> Map.put(:model, Map.get(resolution.profile, :model))
           |> Map.put(:mime_type, mime_type)
           |> Map.put(:usage, Map.get(generated, :usage, %{source: :unavailable}))
           |> Map.put(:cost, Map.get(generated, :cost, %{source: :unavailable})),
         {:ok, _bounds} <-
           ImageBounds.validate_generated(metadata, generated_output_profile(resolution.profile),
             settings: settings
           ) do
      {:ok,
       %{
         path: path,
         metadata: metadata |> Redactor.redact_image_metadata() |> maybe_put_attempts(attempts)
       }}
    end
  end

  defp write_generated_image(bytes, output_format, settings, context) when is_binary(bytes) do
    if image_retention_enabled?(settings) do
      write_retained_generated_image(bytes, output_format, context)
    else
      write_transient_generated_image(bytes, output_format, settings)
    end
  end

  defp write_transient_generated_image(bytes, output_format, settings) do
    id = generated_image_id()
    root = generated_image_root(settings)
    path = Path.join([root, id, "image.#{output_format}"])

    with :ok <- File.mkdir_p(Path.dirname(path)),
         :ok <- File.write(path, bytes) do
      {:ok, path}
    end
  end

  defp write_retained_generated_image(bytes, output_format, context) do
    attrs = %{
      filename: "image.#{output_format}",
      mime: "image/#{output_format}"
    }

    with {:ok, artifact} <- MediaRetention.put(:generated_image, bytes, attrs, context: context) do
      {:ok, artifact.path}
    end
  end

  defp completed(%{path: path, metadata: metadata}, permission_decision) do
    %{
      message: "Image generated with #{metadata.provider_profile}.",
      status: :completed,
      image_file: path,
      output_resource_uri: Map.get(metadata, :output_resource_uri),
      image_metadata: metadata,
      permission_decision: permission_decision,
      actions: [
        action(:completed, permission_decision, %{
          provider_profile: metadata.provider_profile,
          output_resource_uri: Map.get(metadata, :output_resource_uri),
          image_metadata: metadata
        })
      ]
    }
  end

  defp stopped(permission_decision, reason, metadata) do
    %{
      message: permission_decision.reason,
      status: PermissionGate.response_status(permission_decision),
      error: reason,
      image_metadata: metadata,
      permission_decision: permission_decision,
      actions: [
        action(PermissionGate.response_status(permission_decision), permission_decision, metadata)
      ]
    }
  end

  defp failed(reason, permission_decision, metadata) do
    redacted_reason = safe_redact(reason)

    %{
      message: "Image generation failed: #{inspect(redacted_reason)}",
      status: failed_status(reason),
      error: redacted_reason,
      image_metadata: metadata,
      permission_decision: permission_decision,
      actions: [
        action(
          failed_status(reason),
          permission_decision,
          Map.put(metadata, :error, redacted_reason)
        )
      ]
    }
  end

  defp action(status, permission_decision, metadata) do
    %{
      name: @action_name,
      status: status,
      permission: @permission,
      permission_decision: permission_decision,
      image_metadata:
        metadata
        |> Map.get(:image_metadata, metadata)
        |> Redactor.redact_image_metadata()
    }
  end

  defp create_confirmation(prompt, resolution, params, attempts, context, permission_decision) do
    with {:ok, output_format} <- output_format(resolution.profile, params) do
      summary = confirmation_summary(prompt, resolution, output_format, params, attempts)

      attrs = %{
        origin: Origin.from_context(context, @action_name),
        target_action: %{name: @action_name, module: inspect(__MODULE__)},
        target_permission: @permission,
        target_execution_mode: :image_provider_call,
        security_decision: permission_decision,
        source_signal_id: source_signal_id(context),
        source_trace_id: source_trace_id(context),
        runner_metadata: runner_metadata(context, resolution),
        params_summary: summary,
        resume_params_ref: %{
          prompt: prompt,
          output_format: output_format,
          size: field(params, :size)
        }
      }

      case Confirmations.create(attrs) do
        {:ok, confirmation} ->
          confirmation_id = confirmation_id(confirmation)

          {:ok,
           %{
             message: "Image generation needs confirmation.",
             status: :needs_confirmation,
             error: :permission_denied,
             image_metadata: summary,
             permission_decision: permission_decision,
             confirmation: Confirmations.redact_for_output(confirmation),
             confirmation_id: confirmation_id,
             actions: [
               action(:needs_confirmation, permission_decision, %{
                 provider_profile: resolution.profile_name,
                 confirmation_id: confirmation_id,
                 image_metadata: summary
               })
               |> Map.put(:confirmation_metadata, confirmation_metadata(confirmation))
             ]
           }}

        {:error, reason} ->
          {:ok, failed(reason, permission_decision, %{provider_attempts: Enum.reverse(attempts)})}
      end
    else
      {:error, reason} ->
        {:ok, failed(reason, permission_decision, %{provider_attempts: Enum.reverse(attempts)})}
    end
  end

  defp prompt(params) do
    value = field(params, :prompt) || field(params, :text) || field(params, :input)

    case value do
      value when is_binary(value) ->
        value = String.trim(value)
        if value == "", do: {:error, :missing_prompt}, else: {:ok, value}

      _value ->
        {:error, :missing_prompt}
    end
  end

  defp image_enabled? do
    case Settings.get("image.enabled") do
      {:ok, true} -> :ok
      {:ok, false} -> {:error, :image_generation_disabled}
      {:error, reason} -> {:error, reason}
    end
  end

  defp output_format(profile, params) do
    requested =
      params
      |> field(:output_format)
      |> normalize_format()

    supported =
      profile
      |> media_field("image_formats_supported")
      |> normalize_formats()

    cond do
      supported == [] ->
        {:error, :missing_supported_image_formats}

      is_binary(requested) and requested in supported ->
        {:ok, requested}

      is_binary(requested) ->
        {:error, {:unsupported_image_output_format, requested, supported}}

      @default_format in supported ->
        {:ok, @default_format}

      true ->
        {:ok, hd(supported)}
    end
  end

  defp request_opts(profile, context, output_format, params) do
    profile
    |> ModelRuntime.request_opts()
    |> Keyword.merge(
      size: field(params, :size),
      receive_timeout: Map.get(profile, :timeout_ms, 120_000)
    )
    |> maybe_put_image_output_format(profile, output_format)
    |> maybe_put_keyword(:req_http_options, req_http_options(context))
    |> Enum.reject(fn {_key, value} -> is_nil(value) end)
  end

  defp image_bytes(response, output_format) do
    image = safe_image(response)
    bytes = safe_image_data(response)

    if is_binary(bytes) and byte_size(bytes) > 0 do
      {:ok, bytes, image_media_type(image, output_format)}
    else
      {:error, :image_generation_no_binary_output}
    end
  end

  defp safe_image(response) do
    if function_exported?(ReqLLM.Response, :image, 1) do
      ReqLLM.Response.image(response)
    end
  rescue
    _exception -> nil
  end

  defp safe_image_data(response) do
    if function_exported?(ReqLLM.Response, :image_data, 1) do
      ReqLLM.Response.image_data(response)
    end
  rescue
    _exception -> nil
  end

  defp image_media_type(%{media_type: media_type}, _output_format) when is_binary(media_type),
    do: media_type

  defp image_media_type(_image, "jpeg"), do: "image/jpeg"
  defp image_media_type(_image, "webp"), do: "image/webp"
  defp image_media_type(_image, _output_format), do: "image/png"

  defp generated_storage_format(generated, output_format) do
    [
      format_from_bytes(Map.get(generated, :bytes)),
      format_from_mime(Map.get(generated, :mime_type)),
      normalize_format(output_format)
    ]
    |> Enum.find(&safe_image_format?/1)
    |> case do
      nil -> {:error, :unsupported_generated_image_format}
      format -> {:ok, format}
    end
  end

  defp generated_output_profile(%{media: media} = profile) when is_map(media) do
    %{profile | media: generated_output_media(media)}
  end

  defp generated_output_profile(%{"media" => media} = profile) when is_map(media) do
    Map.put(profile, "media", generated_output_media(media))
  end

  defp generated_output_profile(profile), do: profile

  defp generated_output_media(media) do
    Map.put(media, "image_formats_supported", ImageBounds.allowed_formats())
  end

  defp safe_image_format?(format) when is_binary(format),
    do: format in ImageBounds.allowed_formats()

  defp safe_image_format?(_format), do: false

  defp format_from_mime(value) when is_binary(value) do
    case String.split(String.downcase(String.trim(value)), "/", parts: 2) do
      ["image", subtype] -> normalize_format(subtype)
      _other -> nil
    end
  end

  defp format_from_mime(_value), do: nil

  defp format_from_bytes(<<0x89, ?P, ?N, ?G, _rest::binary>>), do: "png"
  defp format_from_bytes(<<0xFF, 0xD8, _rest::binary>>), do: "jpeg"
  defp format_from_bytes(<<"RIFF", _size::little-32, "WEBP", _rest::binary>>), do: "webp"
  defp format_from_bytes(_bytes), do: nil

  defp generated_image_root(_settings), do: Path.join(RuntimePaths.tmp_root(), "generated-images")

  defp image_retention_enabled?(settings) do
    Schema.get_dotted(settings, "image.generation.retention_enabled") == true
  end

  defp image_read_max_bytes(profile, settings) do
    settings
    |> Schema.get_dotted("image.generation.max_bytes")
    |> positive_integer(20_971_520)
    |> min_positive_bound(media_bound(Map.get(profile, :media), "max_image_bytes"))
  end

  defp media_bound(media, key) when is_map(media) do
    media
    |> Map.get(key, Map.get(media, String.to_atom(key)))
    |> positive_integer(nil)
  end

  defp media_bound(_media, _key), do: nil

  defp image_context(context, profile) do
    context
    |> Map.drop([:req_http_options, "req_http_options", :req_options, "req_options"])
    |> Map.merge(%{
      model_profile: profile,
      provider_deployment_mode: deployment_mode(profile)
    })
  end

  defp deployment_mode(%{media: %{} = media}) do
    Map.get(media, "deployment_mode") || Map.get(media, :deployment_mode)
  end

  defp deployment_mode(_profile), do: nil

  defp confirmation_summary(prompt, resolution, output_format, params, attempts) do
    %{
      provider_profile: resolution.profile_name,
      provider: Map.get(resolution.profile, :provider),
      model: Map.get(resolution.profile, :model),
      output_format: output_format,
      size: field(params, :size),
      prompt_byte_size: byte_size(prompt),
      prompt_sha256: sha256(prompt),
      redaction_status: "metadata_only"
    }
    |> drop_nil_values()
    |> maybe_put_confirmation_attempts(attempts)
  end

  defp attempt_record(resolution, reason) do
    %{
      provider_profile: resolution.profile_name,
      provider: Map.get(resolution.profile, :provider),
      model: Map.get(resolution.profile, :model),
      error: safe_redact(reason)
    }
  end

  defp maybe_put_attempts(metadata, []), do: metadata
  defp maybe_put_attempts(metadata, attempts), do: Map.put(metadata, :fallback_attempts, attempts)

  defp maybe_put_confirmation_attempts(metadata, []), do: metadata

  defp maybe_put_confirmation_attempts(metadata, attempts) do
    Map.put(metadata, :fallback_attempts, attempts |> Enum.reverse() |> Enum.map(&safe_attempt/1))
  end

  defp safe_attempt(%{} = attempt), do: Map.update(attempt, :error, nil, &inspect/1)

  defp retryable_provider_error?({:image_http_error, status})
       when status >= 500 and status <= 599,
       do: true

  defp retryable_provider_error?({:image_transport_error, _reason}), do: true
  defp retryable_provider_error?(%{status: status}) when status >= 500 and status <= 599, do: true
  defp retryable_provider_error?(%Req.TransportError{}), do: true
  defp retryable_provider_error?(_reason), do: false

  defp req_http_options(context) do
    context
    |> field(:req_http_options)
    |> normalize_keyword()
    |> case do
      [] -> context |> field(:req_options) |> normalize_keyword()
      opts -> opts
    end
  end

  defp normalize_keyword(value) when is_list(value), do: value
  defp normalize_keyword(value) when is_map(value), do: Map.to_list(value)
  defp normalize_keyword(_value), do: []

  defp maybe_put_keyword(opts, _key, []), do: opts
  defp maybe_put_keyword(opts, key, value), do: Keyword.put(opts, key, value)

  defp maybe_put_image_output_format(opts, %{provider_type: "openai_compatible"}, _output_format),
    do: opts

  defp maybe_put_image_output_format(opts, _profile, output_format),
    do: Keyword.put(opts, :output_format, output_format_option(output_format))

  defp generated_mime_type(_generated, metadata) do
    metadata.mime_type
  end

  defp ensure_req_llm! do
    if Code.ensure_loaded?(ReqLLM) and Code.ensure_loaded?(ReqLLM.Response) do
      :ok
    else
      {:error, :req_llm_unavailable}
    end
  end

  defp usage(response) do
    if function_exported?(ReqLLM.Response, :usage, 1) do
      ReqLLM.Response.usage(response)
    end
  rescue
    _exception -> nil
  end

  defp generated_image_id do
    "gen_" <> Base.url_encode64(:crypto.strong_rand_bytes(8), padding: false)
  end

  defp positive_integer(value, _fallback) when is_integer(value) and value > 0, do: value

  defp positive_integer(value, fallback) when is_binary(value) do
    case Integer.parse(value) do
      {integer, ""} when integer > 0 -> integer
      _other -> fallback
    end
  end

  defp positive_integer(_value, fallback), do: fallback

  defp min_positive_bound(value, nil), do: value
  defp min_positive_bound(value, bound), do: min(value, bound)

  defp media_field(%{media: %{} = media}, key),
    do: Map.get(media, key) || Map.get(media, String.to_atom(key))

  defp media_field(%{"media" => %{} = media}, key),
    do: Map.get(media, key) || Map.get(media, String.to_atom(key))

  defp media_field(_profile, _key), do: nil

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
      "jpg" -> "jpeg"
      format -> format
    end
  end

  defp normalize_format(nil), do: nil

  defp normalize_format(value) when is_atom(value),
    do: value |> Atom.to_string() |> normalize_format()

  defp normalize_format(_value), do: nil

  defp output_format_option("png"), do: :png
  defp output_format_option("jpeg"), do: :jpeg
  defp output_format_option("webp"), do: :webp
  defp output_format_option(format), do: format

  defp failed_status(:image_generation_disabled), do: :denied
  defp failed_status(:missing_prompt), do: :denied
  defp failed_status({:unsupported_image_output_format, _format, _supported}), do: :denied
  defp failed_status({:unsupported_fake_media_image_generation, _profile, _format}), do: :denied
  defp failed_status({:image_output_too_large, _size, _max}), do: :denied
  defp failed_status({:image_output_too_many_pixels, _pixels, _max}), do: :denied
  defp failed_status(_reason), do: :error

  defp source_signal_id(context),
    do: field(context, :input_signal_id) || field(context, :source_signal_id)

  defp source_trace_id(context), do: field(context, :trace_id) || field(context, :source_trace_id)

  defp runner_metadata(context, resolution) do
    context
    |> Map.take([:actor, :user_id, :operator_id, :channel, :surface, :response_target])
    |> Enum.reject(fn {_key, value} -> is_nil(value) end)
    |> Map.new()
    |> Map.put(:selected_action, @action_name)
    |> Map.put(:provider_profile, resolution.profile_name)
  end

  defp confirmation_id(%{"id" => id}), do: id
  defp confirmation_id(%{id: id}), do: id

  defp confirmation_metadata(confirmation) do
    %{
      id: confirmation_id(confirmation),
      status: field(confirmation, :status),
      target_action: get_in(confirmation, ["target_action", "name"]) || @action_name
    }
  end

  defp drop_nil_values(map) when is_map(map) do
    map
    |> Enum.reject(fn {_key, value} -> is_nil(value) end)
    |> Map.new()
  end

  defp safe_redact(reason) do
    Redactor.redact(reason)
  rescue
    _exception -> inspect(reason)
  end

  defp approved_resume?(%{confirmation: %{approved?: true}}), do: true
  defp approved_resume?(%{"confirmation" => %{"approved?" => true}}), do: true
  defp approved_resume?(_context), do: false

  defp field(map, key) when is_map(map),
    do: Map.get(map, key) || Map.get(map, Atom.to_string(key))

  defp field(_map, _key), do: nil

  defp sha256(value), do: :crypto.hash(:sha256, value) |> Base.encode16(case: :lower)
end
