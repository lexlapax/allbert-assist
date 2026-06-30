defmodule AllbertAssist.Actions.Intent.DirectAnswer do
  @moduledoc """
  Side-effect-free response action for plain assistant prompts.
  """

  use AllbertAssist.Action,
    permission: :read_only,
    exposure: :agent,
    execution_mode: :read_only,
    skill_backed?: true,
    confirmation: :not_required,
    name: "direct_answer",
    description:
      "Answer a plain prompt without effectful tools; model mode may read bounded reviewed memory.",
    category: "intent",
    tags: ["intent", "safe", "read_only"],
    schema: [
      text: [type: :string, required: true, doc: "User prompt to answer."]
    ],
    output_schema: [
      message: [type: :string, required: true],
      status: [type: :atom, required: true],
      permission_decision: [type: :map, required: true],
      actions: [type: {:list, :map}, required: true]
    ]

  alias AllbertAssist.Actions.Runner
  alias AllbertAssist.Coding.Config, as: CodingConfig
  alias AllbertAssist.Coding.StreamingTurn
  alias AllbertAssist.Memory.ActiveMemory
  alias AllbertAssist.Resources.{ImageBounds, ImageMetadata}
  alias AllbertAssist.Runtime.Redactor
  alias AllbertAssist.Runtime.SafeTerm
  alias AllbertAssist.Security.PermissionGate
  alias AllbertAssist.Settings
  alias AllbertAssist.Settings.Models
  alias AllbertAssist.Settings.Schema
  alias AllbertAssist.Settings.Store

  @answerer_config __MODULE__
  @default_answerer __MODULE__.ReqLLMAnswerer
  @fallback_source :bounded_fallback
  @max_reason_bytes 240

  @impl true
  def run(%{text: text}, context) do
    image_inputs = image_inputs(context)
    permission_decision = permission_decision(context, image_inputs)
    answer = answer(text, context, permission_decision, image_inputs)

    direct_answer_action = %{
      name: "direct_answer",
      status: :completed,
      permission: :read_only,
      permission_decision: permission_decision,
      direct_answer: answer.direct_answer
    }

    attrs = answer.attrs

    response =
      %{
        message: answer.message,
        status: PermissionGate.response_status(permission_decision),
        permission_decision: permission_decision,
        direct_answer: answer.direct_answer,
        actions: [direct_answer_action]
      }
      |> Map.merge(Map.delete(attrs, :actions))
      |> Map.update!(:actions, &(&1 ++ Map.get(attrs, :actions, [])))

    {:ok, response}
  end

  defp answer(text, context, permission_decision, image_inputs) do
    if PermissionGate.allowed?(permission_decision) do
      model_answer(text, context, image_inputs)
    else
      fallback(:permission_denied)
    end
  end

  defp model_answer(text, context, []) do
    if coding_streaming_request?(context) do
      coding_streaming_answer(text, context)
    else
      direct_text_model_answer(text, context)
    end
  end

  defp model_answer(text, context, image_inputs),
    do: vision_model_answer(text, context, image_inputs)

  defp direct_text_model_answer(text, context) do
    case Settings.get("intent.direct_answer_model_enabled") do
      {:ok, true} -> text_model_answer(text, context)
      {:ok, false} -> fallback(:model_disabled)
      {:error, reason} -> fallback({:settings_unavailable, reason})
    end
  end

  defp text_model_answer(text, context) do
    with {:ok, resolution} <- Models.for(:direct_answer, context),
         profile <- resolution.profile,
         active_memory <- retrieve_active_memory(text, context),
         {:ok, response} <-
           answerer().answer(
             text,
             Map.merge(context, %{model_profile: profile, active_memory: active_memory.chunks})
           ) do
      answer_result(
        response.message,
        %{
          source: :model,
          model_profile: profile.name,
          provider: profile.provider,
          model: profile.model,
          model_resolution: resolution_metadata(resolution),
          active_memory: ActiveMemory.trace_metadata(active_memory),
          diagnostic: Map.get(response, :diagnostic, %{status: :used})
        }
      )
    else
      {:error, reason} -> fallback({:model_unavailable, reason})
    end
  end

  defp coding_streaming_answer(text, context) do
    case StreamingTurn.answer(text, context) do
      {:ok, response} ->
        %{
          message: response.message,
          direct_answer: response.direct_answer,
          attrs:
            Map.take(response, [
              :status,
              :model_payload,
              :surface_payload,
              :approval_handoff,
              :stream_events,
              :turn_id,
              :coding_turn,
              :coding_session_context,
              :actions,
              :diagnostics
            ])
        }

      {:error, reason} ->
        if CodingConfig.streaming_turn_complete_fallback?() do
          fallback({:coding_stream_unavailable, reason})
        else
          fallback({:model_unavailable, reason})
        end
    end
  end

  defp vision_model_answer(text, context, image_inputs) do
    result =
      with {:ok, true} <- Settings.get("vision.enabled"),
           {:ok, settings, _user_settings} <- Store.resolved_settings(),
           {:ok, resolution} <- Models.for(:vision_input, context),
           profile <- resolution.profile,
           {:ok, bounded_inputs} <- validate_image_inputs(image_inputs, profile, settings),
           active_memory <- retrieve_active_memory(text, context),
           {:ok, response} <-
             answerer().answer(
               text,
               Map.merge(context, %{
                 model_profile: profile,
                 active_memory: active_memory.chunks,
                 image_inputs: bounded_inputs
               })
             ) do
        answer_result(
          response.message,
          %{
            source: :model,
            model_profile: profile.name,
            provider: profile.provider,
            model: profile.model,
            model_resolution: resolution_metadata(resolution),
            active_memory: ActiveMemory.trace_metadata(active_memory),
            media: %{image_inputs: Enum.map(bounded_inputs, &Redactor.redact_image_metadata/1)},
            diagnostic: Map.get(response, :diagnostic, %{status: :used})
          }
        )
      else
        {:ok, false} -> fallback(:vision_disabled)
        {:error, reason} -> fallback({:model_unavailable, reason})
      end

    cleanup_transient_image_inputs(image_inputs)
    result
  end

  defp retrieve_active_memory(text, context) do
    params = %{
      query: text,
      user_id: context_value(context, :user_id) || context_value(context, :actor),
      thread_id: context_value(context, :thread_id),
      active_app: context_value(context, :active_app),
      now: active_memory_now(context)
    }

    case Runner.run("retrieve_active_memory", params, context) do
      {:ok, %{status: :completed, active_memory: active_memory}} ->
        active_memory

      {:ok, %{active_memory: active_memory}} when is_map(active_memory) ->
        Map.merge(empty_active_memory(), active_memory)

      _other ->
        empty_active_memory()
    end
  end

  defp empty_active_memory do
    %{
      status: :unavailable,
      enabled?: false,
      query_terms_normalized: [],
      scope: %{},
      candidate_count_before_filter: 0,
      candidate_chunk_count_before_filter: 0,
      candidate_count_after_filter: 0,
      chunks: [],
      retrieved_chunks: [],
      excluded_chunks_sample: []
    }
  end

  defp resolution_metadata(resolution) do
    %{
      request: resolution.request,
      request_kind: resolution.request_kind,
      capability: resolution.capability,
      source: resolution.source,
      diagnostics: resolution.diagnostics
    }
  end

  defp context_value(context, key) do
    Map.get(context, key) ||
      get_in(context, [:request, key]) ||
      get_in(context, [:request, Atom.to_string(key)])
  end

  defp coding_streaming_request?(context) do
    request = Map.get(context, :request) || Map.get(context, "request") || %{}
    metadata = field(request, :metadata) || %{}

    truthy?(field(request, :coding_turn?)) ||
      truthy?(field(request, :coding_turn)) ||
      truthy?(field(metadata, :coding_turn?)) ||
      truthy?(field(metadata, :coding_turn)) ||
      field(metadata, :surface) in ["pi_mode", "coding", "tui_pi_mode"]
  end

  defp truthy?(value) when value in [true, "true", "1", 1], do: true
  defp truthy?(_value), do: false

  defp active_memory_now(context) do
    [:now, :request_started_at, :started_at, :requested_at]
    |> Enum.find_value(&context_timestamp(context, &1))
    |> case do
      nil -> DateTime.utc_now() |> DateTime.truncate(:second) |> DateTime.to_iso8601()
      timestamp -> timestamp
    end
  end

  defp context_timestamp(context, key) do
    context
    |> context_value(key)
    |> normalize_timestamp()
  end

  defp normalize_timestamp(%DateTime{} = datetime) do
    datetime
    |> DateTime.truncate(:second)
    |> DateTime.to_iso8601()
  end

  defp normalize_timestamp(value) when is_binary(value) do
    case DateTime.from_iso8601(value) do
      {:ok, datetime, _offset} -> normalize_timestamp(datetime)
      _error -> nil
    end
  end

  defp normalize_timestamp(_value), do: nil

  defp fallback(reason) do
    %{
      message: fallback_message(reason),
      direct_answer: %{
        source: @fallback_source,
        reason: bounded_reason(reason),
        model_enabled?: model_enabled?(),
        diagnostic: %{status: :fallback}
      },
      attrs: %{}
    }
  end

  defp fallback_message(reason) do
    detail =
      case reason do
        :model_disabled ->
          "The direct-answer model is disabled."

        :permission_denied ->
          "The read-only answer boundary was denied."

        :vision_disabled ->
          "Vision input is disabled."

        {:settings_unavailable, _reason} ->
          "The direct-answer settings could not be read."

        {:model_unavailable, _reason} ->
          "The configured direct-answer model was unavailable."

        {:coding_stream_unavailable, _reason} ->
          "The configured coding stream was unavailable."
      end

    """
    I kept this turn side-effect-free and did not run tools, app actions, memory writes, shell commands, package installs, browser actions, or resource requests.

    #{detail}
    """
    |> String.trim()
  end

  defp answer_result(message, direct_answer) do
    %{message: message, direct_answer: direct_answer, attrs: %{}}
  end

  defp answerer do
    :allbert_assist
    |> Application.get_env(@answerer_config, [])
    |> Keyword.get(:answerer, @default_answerer)
  end

  defp model_enabled? do
    case Settings.get("intent.direct_answer_model_enabled") do
      {:ok, enabled?} -> enabled?
      _other -> false
    end
  rescue
    _exception -> false
  end

  defp permission_decision(context, []), do: PermissionGate.authorize(:read_only, context)

  defp permission_decision(context, _image_inputs) do
    read_only = PermissionGate.authorize(:read_only, context)
    image_input = PermissionGate.authorize(:image_input, context)

    if PermissionGate.allowed?(read_only), do: image_input, else: read_only
  end

  defp image_inputs(context) do
    metadata =
      get_in(context, [:request, :metadata]) ||
        get_in(context, ["request", "metadata"]) ||
        Map.get(context, :metadata) ||
        Map.get(context, "metadata") ||
        %{}

    metadata
    |> image_input_values()
    |> SafeTerm.filter_list(&is_map/1)
  end

  defp image_input_values(metadata) when is_map(metadata) do
    cond do
      is_list(field(metadata, :image_inputs)) -> field(metadata, :image_inputs)
      is_map(field(metadata, :image_input)) -> [field(metadata, :image_input)]
      is_list(field(metadata, :images)) -> field(metadata, :images)
      true -> []
    end
  end

  defp image_input_values(_metadata), do: []

  defp validate_image_inputs(image_inputs, profile, settings) do
    image_inputs
    |> SafeTerm.to_list()
    |> Enum.reduce_while({:ok, []}, fn image_input, {:ok, acc} ->
      case validate_image_input(image_input, profile, settings) do
        {:ok, metadata} -> {:cont, {:ok, [metadata | acc]}}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
    |> case do
      {:ok, inputs} -> {:ok, Enum.reverse(inputs)}
      {:error, reason} -> {:error, reason}
    end
  end

  defp validate_image_input(image_input, profile, settings) do
    max_bytes = image_read_max_bytes(profile, settings)

    with {:ok, metadata} <-
           ImageMetadata.from_path(field(image_input, :path),
             max_bytes: max_bytes,
             resource_uri: field(image_input, :resource_uri),
             filename: field(image_input, :filename),
             transient?: field(image_input, :transient?)
           ),
         metadata <- put_image_input_provenance(metadata, image_input),
         metadata <- Map.put(metadata, :provider_profile, profile.name),
         {:ok, _bounds} <- ImageBounds.validate_input(metadata, profile, settings: settings) do
      {:ok, metadata}
    else
      {:error, reason} -> {:error, reason}
    end
  end

  defp image_read_max_bytes(%{media: media}, settings) do
    settings
    |> Schema.get_dotted("vision.media.max_bytes")
    |> positive_integer(20_971_520)
    |> min_positive_bound(media_bound(media, "max_image_bytes"))
  end

  defp media_bound(media, key) when is_map(media) do
    media
    |> Map.get(key, Map.get(media, String.to_atom(key)))
    |> positive_integer(nil)
  end

  defp media_bound(_media, _key), do: nil

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

  defp put_image_input_provenance(metadata, image_input) do
    metadata
    |> maybe_put_image_input_field(:source, field(image_input, :source))
    |> maybe_put_image_input_field(:origin_kind, field(image_input, :origin_kind))
    |> maybe_put_image_input_field(:screenshot_ref, field(image_input, :screenshot_ref))
    |> maybe_put_image_input_field(
      :redacted_credential_inputs?,
      field(image_input, :redacted_credential_inputs?)
    )
  end

  defp maybe_put_image_input_field(metadata, _key, nil), do: metadata
  defp maybe_put_image_input_field(metadata, _key, ""), do: metadata
  defp maybe_put_image_input_field(metadata, key, value), do: Map.put(metadata, key, value)

  defp cleanup_transient_image_inputs(image_inputs) do
    image_inputs
    |> SafeTerm.to_list()
    |> Enum.each(&cleanup_transient_image_input/1)
  end

  defp cleanup_transient_image_input(image_input) do
    if field(image_input, :transient?) == true do
      cleanup_image_input_path(field(image_input, :path))
    end
  end

  defp cleanup_image_input_path(path) when is_binary(path), do: File.rm(path)
  defp cleanup_image_input_path(_path), do: :ok

  defp bounded_reason(reason) do
    reason
    |> Redactor.redact()
    |> inspect()
    |> then(fn value ->
      if byte_size(value) <= @max_reason_bytes do
        value
      else
        binary_part(value, 0, @max_reason_bytes) <> "...[truncated]"
      end
    end)
  end

  defp field(map, key) when is_map(map) and is_atom(key) do
    Map.get(map, key) || Map.get(map, Atom.to_string(key))
  end

  defp field(_map, _key), do: nil
end
