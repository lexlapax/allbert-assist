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
  alias AllbertAssist.FirstRun.Disclosure
  alias AllbertAssist.Intent.FanoutManager
  alias AllbertAssist.Maps
  alias AllbertAssist.Memory.ActiveMemory
  alias AllbertAssist.Models.Failure
  alias AllbertAssist.Models.FallbackAudit
  alias AllbertAssist.Resources.{ImageBounds, ImageMetadata}
  alias AllbertAssist.Runtime.FanoutDiagnostics
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
  @fanout_worker_policy %{
    version: 1,
    provider_failover: :disabled,
    conversation_fanout: :disabled
  }
  @max_reason_bytes 240
  @max_active_memory_prompt_bytes 8_000

  @impl true
  def run(%{text: text}, context) do
    image_inputs = image_inputs(context)
    permission_decision = permission_decision(context, image_inputs)

    answer =
      text
      |> answer(context, permission_decision, image_inputs)
      |> put_fanout_worker_result(context)

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
    with {:ok, resolution} <- Models.for(:direct_answer, context) do
      active_memory = retrieve_active_memory(text, context)

      text
      |> call_text_model(context, active_memory, resolution)
      |> resolve_text_model_result(text, context, active_memory, resolution)
    else
      {:error, reason} -> fallback({:model_unavailable, reason})
    end
  end

  defp resolve_text_model_result({:ok, response}, _text, _context, active_memory, resolution),
    do: model_answer_result(response, resolution, active_memory)

  defp resolve_text_model_result(
         {:fanout_worker_provider_result, {:ok, response}},
         _text,
         _context,
         active_memory,
         resolution
       ) do
    response
    |> model_answer_result(resolution, active_memory)
    |> put_fanout_worker_count(1)
  end

  defp resolve_text_model_result(
         {:fanout_worker_provider_result, {:error, {:transport_denied, reason}}},
         _text,
         _context,
         _active_memory,
         _resolution
       ) do
    {:disclosure_required, reason}
    |> fallback()
    |> put_fanout_worker_count(1)
  end

  defp resolve_text_model_result(
         {:fanout_worker_provider_result, {:error, reason}},
         _text,
         _context,
         _active_memory,
         _resolution
       ) do
    {:model_unavailable, reason}
    |> fallback()
    |> put_fanout_worker_count(1)
  end

  defp resolve_text_model_result(
         {:manager_answer, response, diagnostic},
         _text,
         _context,
         active_memory,
         resolution
       ) do
    response
    |> model_answer_result(resolution, active_memory)
    |> put_answer_diagnostic(diagnostic)
  end

  defp resolve_text_model_result(
         {:fanout, response, plan, diagnostic},
         _text,
         _context,
         active_memory,
         resolution
       ) do
    response
    |> model_answer_result(resolution, active_memory)
    |> put_answer_attrs(%{
      parallel_work_plan: plan,
      fanout_manager: diagnostic,
      diagnostics: [FanoutDiagnostics.manager(:fanout, diagnostic)]
    })
  end

  defp resolve_text_model_result(
         {:clarify, response, clarification, diagnostic},
         _text,
         _context,
         active_memory,
         resolution
       ) do
    response
    |> model_answer_result(resolution, active_memory)
    |> put_answer_attrs(%{
      parallel_work_clarification: clarification,
      fanout_manager: diagnostic,
      diagnostics: [FanoutDiagnostics.manager(:clarify, diagnostic)]
    })
  end

  defp resolve_text_model_result(
         {:manager_fallback, {:ok, response}, diagnostic},
         _text,
         _context,
         active_memory,
         resolution
       ) do
    response
    |> model_answer_result(resolution, active_memory)
    |> put_answer_diagnostic(diagnostic)
  end

  defp resolve_text_model_result(
         {:manager_fallback, {:error, {:transport_denied, reason}}, diagnostic},
         _text,
         _context,
         _active_memory,
         _resolution
       ) do
    {:disclosure_required, reason}
    |> fallback()
    |> put_answer_diagnostic(diagnostic)
  end

  defp resolve_text_model_result(
         {:manager_fallback, {:error, reason}, diagnostic},
         text,
         context,
         active_memory,
         resolution
       ) do
    text
    |> maybe_failover(context, active_memory, resolution, reason)
    |> put_answer_diagnostic(diagnostic)
  end

  defp resolve_text_model_result(
         {:error, {:transport_denied, reason}},
         _text,
         _context,
         _active_memory,
         _resolution
       ),
       do: fallback({:disclosure_required, reason})

  defp resolve_text_model_result(
         {:error, reason},
         text,
         context,
         active_memory,
         resolution
       ),
       do: maybe_failover(text, context, active_memory, resolution, reason)

  defp call_text_model(text, context, active_memory, resolution) do
    if fanout_manager_enabled?(context) do
      case call_fanout_manager(text, context, active_memory, resolution) do
        {:ok, %{kind: :answer, message: message, diagnostic: diagnostic}} ->
          {:manager_answer, %{message: message, diagnostic: manager_answer_diagnostic()},
           FanoutDiagnostics.manager(:answer, diagnostic)}

        {:ok,
         %{
           kind: :fanout,
           fallback_answer: message,
           plan: plan,
           diagnostic: diagnostic
         }} ->
          {:fanout, %{message: message, diagnostic: manager_answer_diagnostic()}, plan,
           diagnostic}

        {:ok,
         %{
           kind: :clarify,
           fallback_answer: message,
           clarification: clarification,
           diagnostic: diagnostic
         }} ->
          {:clarify, %{message: message, diagnostic: manager_answer_diagnostic()}, clarification,
           diagnostic}

        {:error, _reason} ->
          {:manager_fallback, call_answerer(text, context, active_memory, resolution),
           FanoutDiagnostics.manager_error()}
      end
    else
      call_answerer(text, context, active_memory, resolution)
    end
  end

  defp call_fanout_manager(text, context, active_memory, resolution) do
    manager_context =
      context
      |> Map.delete(:model_profile)
      |> Map.merge(%{
        model_enabled?: true,
        active_memory: active_memory.chunks,
        max_children_per_fanout: fanout_max_children(context),
        timeout_ms: fanout_manager_timeout(context, resolution.profile)
      })

    fanout_manager().respond(
      fanout_manager_text(text, context),
      manager_context
    )
  end

  defp fanout_manager_timeout(context, profile) do
    case get_in(context, [:request, :timeout_ms]) do
      value when is_integer(value) and value > 0 -> value
      _missing -> Map.get(profile, :timeout_ms, 10_000)
    end
  end

  defp fanout_manager_enabled?(context) do
    request = Map.get(context, :request, %{})

    not fanout_worker_context?(context) and
      request[:fanout_manager_mode] in [:automatic, :shadow] and
      not (Map.has_key?(request, :operator_text) and is_nil(request.operator_text))
  end

  defp fanout_manager_text(text, context) do
    case get_in(context, [:request, :operator_text]) do
      operator_text when is_binary(operator_text) -> operator_text
      _missing -> text
    end
  end

  defp fanout_max_children(context) do
    case get_in(context, [:request, :fanout_max_children]) do
      value when is_integer(value) and value >= 2 ->
        value

      _other ->
        case Settings.get("objectives.fanout.max_children_per_fanout") do
          {:ok, value} when is_integer(value) -> value
          _unavailable -> 8
        end
    end
  end

  defp manager_answer_diagnostic, do: %{status: :used}

  defp put_answer_attrs(answer, attrs), do: %{answer | attrs: Map.merge(answer.attrs, attrs)}

  defp put_fanout_worker_result(answer, context) do
    if fanout_worker_context?(context) do
      if Map.has_key?(answer.attrs, :fanout_worker),
        do: answer,
        else: put_fanout_worker_count(answer, 0)
    else
      answer
    end
  end

  defp put_fanout_worker_count(answer, count) when count in [0, 1] do
    put_answer_attrs(answer, %{
      fanout_worker: %{version: 1, provider_call_count: count}
    })
  end

  defp fanout_worker_context?(context),
    do: Map.get(context, :fanout_worker_policy) == @fanout_worker_policy

  defp put_answer_diagnostic(answer, diagnostic) do
    attrs = Map.update(answer.attrs, :diagnostics, [diagnostic], &(&1 ++ [diagnostic]))
    %{answer | attrs: attrs}
  end

  defp call_answerer(text, context, active_memory, resolution) do
    with :ok <- Disclosure.authorize_transport(resolution.profile, context) do
      result =
        answerer().answer(
          text,
          Map.merge(context, %{
            model_profile: resolution.profile,
            active_memory: active_memory.chunks
          })
        )

      if fanout_worker_context?(context),
        do: {:fanout_worker_provider_result, result},
        else: result
    else
      {:error, reason} -> {:error, {:transport_denied, reason}}
    end
  end

  defp model_answer_result(response, resolution, active_memory, fallback_metadata \\ nil) do
    profile = resolution.profile

    metadata = %{
      source: :model,
      model_profile: profile.name,
      provider: profile.provider,
      model: profile.model,
      model_resolution: resolution_metadata(resolution),
      active_memory: ActiveMemory.trace_metadata(active_memory),
      diagnostic: Map.get(response, :diagnostic, %{status: :used})
    }

    metadata =
      if fallback_metadata, do: Map.put(metadata, :fallback, fallback_metadata), else: metadata

    answer_result(response.message, metadata)
  end

  defp maybe_failover(text, context, active_memory, primary, reason) do
    case Settings.get("models.fallback.enabled") do
      {:ok, true} -> attempt_failover(text, context, active_memory, primary, reason)
      _disabled_or_unavailable -> fallback({:model_unavailable, reason})
    end
  end

  defp attempt_failover(text, context, active_memory, primary, reason) do
    classification = Failure.classify(reason)

    with true <- classification in [:definitive, :ambiguous],
         {:ok, candidates} <- Models.candidates_for(:direct_answer, context),
         {:ok, candidate} <- next_failover_candidate(primary, candidates),
         :ok <- allow_fallback_step(primary.profile, candidate.profile) do
      case call_answerer(text, context, active_memory, candidate) do
        {:ok, response} ->
          audit_path =
            audit_fallback(:answered, primary, classification, candidate.profile.name, context)

          model_answer_result(response, candidate, active_memory, %{
            used?: true,
            failed_profile: primary.profile.name,
            classification: classification,
            answered_profile: candidate.profile.name,
            provider_call_count: 2,
            audit_path: audit_path
          })

        {:error, {:transport_denied, fallback_reason}} ->
          audit_path = audit_fallback(:egress_denied, primary, classification, nil, context)

          disclosure_chain_fallback(primary, classification, fallback_reason, audit_path)

        {:error, fallback_reason} ->
          audit_path = audit_fallback(:chain_failed, primary, classification, nil, context)

          chain_fallback(primary, candidate, classification, fallback_reason, audit_path)
      end
    else
      false ->
        audit_path = audit_fallback(:not_retried, primary, classification, nil, context)
        chain_fallback(primary, nil, classification, reason, audit_path)

      {:error, :local_to_hosted_not_allowed} ->
        audit_path = audit_fallback(:egress_denied, primary, classification, nil, context)
        chain_fallback(primary, nil, classification, :local_to_hosted_not_allowed, audit_path)

      {:error, _reason} ->
        audit_path = audit_fallback(:chain_exhausted, primary, classification, nil, context)
        chain_fallback(primary, nil, classification, reason, audit_path)
    end
  end

  defp next_failover_candidate(primary, candidates) do
    candidates
    |> Enum.reject(&(&1.profile.name == primary.profile.name))
    |> List.first()
    |> case do
      nil -> {:error, :no_fallback_candidate}
      candidate -> {:ok, candidate}
    end
  end

  defp allow_fallback_step(primary, candidate) do
    if local_profile?(primary) and not local_profile?(candidate) do
      case Settings.get("models.fallback.allow_local_to_hosted") do
        {:ok, true} -> :ok
        _other -> {:error, :local_to_hosted_not_allowed}
      end
    else
      :ok
    end
  end

  defp local_profile?(profile), do: profile.provider_endpoint_kind == "local_endpoint"

  defp audit_fallback(event, primary, classification, answered_profile, context) do
    attrs = %{
      failed_profile: primary.profile.name,
      classification: classification,
      answered_profile: answered_profile,
      outcome: event
    }

    case FallbackAudit.append(event, attrs, context) do
      {:ok, path} -> path
      {:error, _reason} -> nil
    end
  end

  defp chain_fallback(primary, candidate, classification, reason, audit_path) do
    chain = [primary.profile.name] ++ if(candidate, do: [candidate.profile.name], else: [])

    %{
      message: "The configured model chain failed: #{Enum.join(chain, " → ")}.",
      direct_answer: %{
        source: @fallback_source,
        reason: bounded_reason(reason),
        model_enabled?: model_enabled?(),
        diagnostic: %{status: :fallback},
        fallback: %{
          used?: false,
          failed_chain: chain,
          classification: classification,
          provider_call_count: length(chain),
          audit_path: audit_path
        }
      },
      attrs: %{}
    }
  end

  defp disclosure_chain_fallback(primary, classification, reason, audit_path) do
    %{
      message: disclosure_required_message(reason),
      direct_answer: %{
        source: @fallback_source,
        reason: bounded_reason(reason),
        model_enabled?: model_enabled?(),
        diagnostic: %{status: :fallback},
        fallback: %{
          used?: false,
          failed_chain: [primary.profile.name],
          classification: classification,
          provider_call_count: 1,
          audit_path: audit_path
        }
      },
      attrs: %{}
    }
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
      user_id: string_param(context_value(context, :user_id) || context_value(context, :actor)),
      thread_id: string_param(context_value(context, :thread_id)),
      active_app: string_param(context_value(context, :active_app)),
      now: active_memory_now(context)
    }

    case Runner.run("retrieve_active_memory", params, context) do
      {:ok, %{status: :completed, active_memory: active_memory}} ->
        enforce_memory_prompt_budget(active_memory)

      {:ok, %{active_memory: active_memory}} when is_map(active_memory) ->
        empty_active_memory()
        |> Map.merge(active_memory)
        |> enforce_memory_prompt_budget()

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
      excluded_chunks_sample: [],
      prompt_budget_bytes: @max_active_memory_prompt_bytes,
      prompt_bytes: 0,
      prompt_truncated?: false
    }
  end

  defp enforce_memory_prompt_budget(active_memory) do
    original_chunks = Map.get(active_memory, :chunks, [])

    {chunks, prompt_bytes} =
      Enum.reduce_while(original_chunks, {[], 0}, fn chunk, {bounded, used} ->
        reduce_prompt_chunk(chunk, bounded, used)
      end)

    active_memory
    |> Map.put(:chunks, chunks)
    |> Map.put(:prompt_budget_bytes, @max_active_memory_prompt_bytes)
    |> Map.put(:prompt_bytes, prompt_bytes)
    |> Map.put(:prompt_truncated?, chunks != original_chunks)
  end

  defp reduce_prompt_chunk(chunk, bounded, used) do
    body = Map.get(chunk, :body, "")

    case bounded_body(body, @max_active_memory_prompt_bytes - used) do
      "" ->
        {:halt, {bounded, used}}

      bounded_body ->
        bytes = byte_size(bounded_body)
        next = {bounded ++ [Map.put(chunk, :body, bounded_body)], used + bytes}
        if bytes < byte_size(body), do: {:halt, next}, else: {:cont, next}
    end
  end

  defp bounded_body(_body, remaining) when remaining <= 0, do: ""

  defp bounded_body(body, remaining) when is_binary(body) and byte_size(body) <= remaining,
    do: body

  defp bounded_body(body, remaining) when is_binary(body) do
    body
    |> String.graphemes()
    |> Enum.reduce_while({[], 0}, fn grapheme, {graphemes, used} ->
      size = byte_size(grapheme)

      if used + size <= remaining,
        do: {:cont, {[grapheme | graphemes], used + size}},
        else: {:halt, {graphemes, used}}
    end)
    |> elem(0)
    |> Enum.reverse()
    |> IO.iodata_to_binary()
  end

  defp bounded_body(_body, _remaining), do: ""

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

  defp string_param(nil), do: nil
  defp string_param(value) when is_binary(value), do: value
  defp string_param(value) when is_atom(value), do: Atom.to_string(value)
  defp string_param(value), do: to_string(value)

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

        {:disclosure_required, reason} ->
          disclosure_required_message(reason)
      end

    """
    I kept this turn side-effect-free and did not run tools, app actions, memory writes, shell commands, package installs, browser actions, or resource requests.

    #{detail}
    """
    |> String.trim()
  end

  defp disclosure_required_message({:hosted_disclosure_required, %{surface: surface}}) do
    case surface do
      "web" ->
        "The selected hosted model is waiting for its provider disclosure. Review the Web disclosure banner, then retry."

      "tui" ->
        "The selected hosted model is waiting for its provider disclosure. Detach and run `allbert tui` again to review it, then retry."

      "cli" ->
        "The selected hosted model is waiting for its provider disclosure. Retry with `allbert ask` so the CLI can display it before transport."
    end
  end

  defp disclosure_required_message({:hosted_disclosure_unavailable, _route}) do
    "The hosted model cannot run from this surface because no pre-egress disclosure channel is available. Use Web, TUI, or `allbert ask`."
  end

  defp disclosure_required_message(_reason) do
    "The selected hosted model is waiting for its provider disclosure on this surface. Review it, then retry."
  end

  defp answer_result(message, direct_answer) do
    %{message: message, direct_answer: direct_answer, attrs: %{}}
  end

  defp answerer do
    :allbert_assist
    |> Application.get_env(@answerer_config, [])
    |> Keyword.get(:answerer, @default_answerer)
  end

  defp fanout_manager do
    :allbert_assist
    |> Application.get_env(@answerer_config, [])
    |> Keyword.get(:fanout_manager, FanoutManager)
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

  defp field(map, key), do: Maps.field_truthy(map, key)
end
