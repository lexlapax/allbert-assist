defmodule AllbertAssist.Intent.Ranker do
  @moduledoc """
  Deterministic scoring helpers for intent candidates.

  v0.19 keeps scoring conservative and context-only. `active_app` and surface
  text matches can move a candidate up, but they do not grant execution
  authority.
  """

  alias AllbertAssist.App.Registry, as: AppRegistry
  alias AllbertAssist.Intent.Candidate

  @spec rank([Candidate.t() | map()], map()) :: [Candidate.t() | map()]
  def rank(candidates, context \\ %{}) when is_list(candidates) do
    ranking_context = ranking_context(context)

    candidates
    |> Enum.map(&score_candidate(&1, ranking_context))
    |> Enum.sort_by(&score_for_sort/1, :desc)
  end

  @spec selected([Candidate.t() | map()]) :: Candidate.t() | map() | nil
  def selected(candidates) when is_list(candidates) do
    candidates
    |> rank(%{})
    |> Enum.find(fn candidate ->
      field(candidate, :status) in [:selected, :candidate]
    end)
  end

  @spec score(term()) :: float()
  def score(candidate), do: normalize_score(field(candidate, :score, 0.0))

  @spec exact_text_match?(String.t(), String.t() | nil) :: boolean()
  def exact_text_match?(text, value) when is_binary(text) and is_binary(value) do
    text
    |> String.downcase()
    |> String.contains?(String.downcase(value))
  end

  def exact_text_match?(_text, _value), do: false

  defp score_candidate(candidate, context) do
    candidate
    |> apply_active_app_affinity(context)
    |> apply_descriptor_text_match(context)
    |> apply_surface_text_match(context)
    |> apply_action_text_match(context)
    |> apply_skill_text_match(context)
    |> apply_job_text_match(context)
    |> apply_channel_text_match(context)
    |> apply_memory_keyword_match(context)
    |> apply_objective_text_match(context)
    |> apply_refusal_keyword_match(context)
  end

  defp apply_active_app_affinity(candidate, %{active_app: active_app})
       when is_atom(active_app) and active_app not in [nil, :allbert] do
    if field(candidate, :app_id) == active_app do
      boost(candidate, 0.35, :app_affinity, "Active app #{active_app} matched candidate app.")
    else
      candidate
    end
  end

  defp apply_active_app_affinity(candidate, _context), do: candidate

  defp apply_descriptor_text_match(candidate, %{text: text}) when is_binary(text) do
    match_score = descriptor_text_match_score(candidate, text)

    if field(candidate, :kind) == :app_intent and match_score > 0 and
         get_in_trace(candidate, :ranking_reason) != :descriptor_text_match do
      boost(
        candidate,
        0.45 + min(match_score * 0.05, 0.25),
        :descriptor_text_match,
        "Request text matched an app intent descriptor."
      )
    else
      candidate
    end
  end

  defp apply_descriptor_text_match(candidate, _context), do: candidate

  defp apply_surface_text_match(candidate, %{text: text}) do
    if field(candidate, :kind) == :surface and surface_text_match?(candidate, text) do
      boost(candidate, 0.45, :surface_text_match, "Request text matched a registered surface.")
    else
      candidate
    end
  end

  defp apply_action_text_match(candidate, context) do
    text = Map.get(context, :text)

    if field(candidate, :kind) == :action and action_text_match?(candidate, text) do
      boost(candidate, 0.3, :action_text_match, "Request text matched a registered action.")
    else
      candidate
    end
  end

  defp apply_skill_text_match(candidate, context) do
    text = Map.get(context, :text)

    if field(candidate, :kind) == :skill and skill_text_match?(candidate, text) do
      boost(candidate, 0.25, :skill_text_match, "Request text matched a trusted skill.")
    else
      candidate
    end
  end

  defp apply_job_text_match(candidate, context) do
    text = Map.get(context, :text)

    if field(candidate, :kind) == :job and job_text_match?(candidate, text) do
      boost(candidate, 0.25, :job_text_match, "Request text matched a scheduled job.")
    else
      candidate
    end
  end

  defp apply_channel_text_match(candidate, context) do
    text = Map.get(context, :text)

    if field(candidate, :kind) == :channel and channel_text_match?(candidate, text) do
      boost(candidate, 0.25, :channel_text_match, "Request text matched a registered channel.")
    else
      candidate
    end
  end

  defp apply_memory_keyword_match(candidate, context) do
    text = Map.get(context, :text)

    if field(candidate, :kind) == :memory and memory_text_match?(candidate, text) do
      boost(candidate, 0.25, :memory_keyword_match, "Request text matched memory keywords.")
    else
      candidate
    end
  end

  defp apply_objective_text_match(candidate, context) do
    text = Map.get(context, :text)

    if field(candidate, :kind) == :objective and objective_text_match?(candidate, text) do
      boost(
        candidate,
        0.25,
        :objective_text_match,
        "Request text matched an active objective."
      )
    else
      candidate
    end
  end

  defp apply_refusal_keyword_match(candidate, context) do
    text = Map.get(context, :text)

    if field(candidate, :kind) == :refusal and refusal_text_match?(text) do
      boost(
        candidate,
        0.25,
        :refusal_keyword_match,
        "Request text matched unsupported resource workflow keywords."
      )
    else
      candidate
    end
  end

  defp surface_text_match?(candidate, text) when is_binary(text) do
    navigation_request?(text) and
      Enum.any?(
        [
          field(candidate, :label),
          field(candidate, :surface_id),
          field(candidate, :app_id),
          get_in_trace(candidate, :path)
        ],
        &text_match?(text, &1)
      )
  end

  defp surface_text_match?(_candidate, _text), do: false

  defp descriptor_text_match_score(candidate, text) when is_binary(text) do
    descriptor = get_in_trace(candidate, :descriptor) || %{}
    vocabulary = field(descriptor, :vocabulary, %{}) || %{}

    values =
      [
        field(candidate, :label),
        field(descriptor, :label),
        field(descriptor, :action_name)
      ] ++ field(descriptor, :examples, []) ++ field(descriptor, :synonyms, [])

    vocabulary_values =
      (field(vocabulary, :phrases, []) || []) ++ (field(vocabulary, :positive_phrases, []) || [])

    negative_values = field(vocabulary, :negative_phrases, []) || []
    allow_single? = field(vocabulary, :allow_single_token_match, true) != false

    if Enum.any?(negative_values, &(descriptor_phrase_match_score(text, &1, true) > 0)) do
      0
    else
      (values ++ vocabulary_values)
      |> Enum.map(&descriptor_phrase_match_score(text, &1, allow_single?))
      |> Enum.max(fn -> 0 end)
    end
  end

  defp descriptor_phrase_match_score(text, value, allow_single?) when is_binary(value) do
    normalized_text = normalize_text(text)
    normalized_value = normalize_text(value)
    text_tokens = String.split(normalized_text, " ", trim: true)
    value_tokens = String.split(normalized_value, " ", trim: true)

    cond do
      normalized_value == "" ->
        0

      phrase_token_match?(normalized_text, normalized_value) ->
        length(value_tokens)

      length(value_tokens) > 1 and ordered_token_match?(text_tokens, value_tokens) ->
        length(value_tokens)

      allow_single? and length(value_tokens) == 1 ->
        [token] = value_tokens

        if String.length(token) >= 4 and token in text_tokens do
          1
        else
          0
        end

      true ->
        0
    end
  end

  defp descriptor_phrase_match_score(_text, _value, _allow_single?), do: 0

  defp phrase_token_match?(normalized_text, normalized_value) do
    text_tokens = String.split(normalized_text, " ", trim: true)
    value_tokens = String.split(normalized_value, " ", trim: true)

    value_tokens != [] and
      text_tokens
      |> Enum.chunk_every(length(value_tokens), 1, :discard)
      |> Enum.any?(&(&1 == value_tokens))
  end

  defp ordered_token_match?(_text_tokens, []), do: false
  defp ordered_token_match?(text_tokens, tokens), do: do_ordered_token_match?(text_tokens, tokens)

  defp do_ordered_token_match?(_text_tokens, []), do: true

  defp do_ordered_token_match?(text_tokens, [token | rest]) do
    case Enum.drop_while(text_tokens, &(&1 != token)) do
      [_matched | remaining] -> do_ordered_token_match?(remaining, rest)
      [] -> false
    end
  end

  defp action_text_match?(candidate, text) when is_binary(text) do
    Enum.any?(
      [
        field(candidate, :label),
        field(candidate, :id),
        field(candidate, :action_name)
      ],
      &compound_text_match?(text, &1)
    ) or keyword_action_match?(text, field(candidate, :action_name))
  end

  defp action_text_match?(_candidate, _text), do: false

  defp skill_text_match?(candidate, text) when is_binary(text) do
    Enum.any?(
      [
        field(candidate, :label),
        field(candidate, :id),
        field(candidate, :skill_name)
      ],
      &compound_text_match?(text, &1)
    )
  end

  defp skill_text_match?(_candidate, _text), do: false

  defp job_text_match?(candidate, text) when is_binary(text) do
    job_request?(text) and
      Enum.any?([field(candidate, :label), field(candidate, :id), field(candidate, :job_id)], fn
        nil -> true
        value -> compound_text_match?(text, value)
      end)
  end

  defp job_text_match?(_candidate, _text), do: false

  defp channel_text_match?(candidate, text) when is_binary(text) do
    channel_request?(text) and
      Enum.any?(
        [
          field(candidate, :label),
          field(candidate, :id),
          field(candidate, :channel_id),
          field(candidate, :plugin_id)
        ],
        &compound_text_match?(text, &1)
      )
  end

  defp channel_text_match?(_candidate, _text), do: false

  defp memory_text_match?(_candidate, text), do: memory_request?(text)

  defp objective_text_match?(candidate, text) when is_binary(text) do
    objective_request?(text) or
      Enum.any?(
        [
          field(candidate, :label),
          field(candidate, :id),
          get_in_trace(candidate, :title),
          get_in_trace(candidate, :objective)
        ],
        &compound_text_match?(text, &1)
      )
  end

  defp objective_text_match?(_candidate, _text), do: false

  defp navigation_request?(text) do
    normalized = String.downcase(text)

    Enum.any?(["open", "show", "go to", "take me to", "navigate"], fn word ->
      String.contains?(normalized, word)
    end)
  end

  defp job_request?(text), do: text_has_any?(text, ["job", "jobs", "schedule", "scheduled"])

  defp channel_request?(text) do
    text_has_any?(text, ["channel", "channels", "telegram", "email", "sms"])
  end

  defp memory_request?(text) do
    is_binary(text) and
      not sensitive_memory_text?(text) and
      text_has_any?(text, ["remember", "memory", "recall", "what is my name", "i prefer"])
  end

  defp sensitive_memory_text?(text) do
    Regex.match?(~r/\b(password|passphrase|secret|api[_ -]?key|token|private key)\b/i, text)
  end

  defp objective_request?(text) do
    text_has_any?(text, ["objective", "objectives", "goal", "goals", "continue"])
  end

  defp refusal_text_match?(text) do
    text_has_any?(text, ["read local file", "agent://", "crawl"])
  end

  defp keyword_action_match?(text, "list_skills") do
    text_has_any?(text, ["skills", "capabilities", "what can you do"])
  end

  defp keyword_action_match?(text, "read_recent_memory"), do: memory_request?(text)
  defp keyword_action_match?(text, "append_memory"), do: memory_request?(text)
  defp keyword_action_match?(text, "list_channels"), do: channel_request?(text)
  defp keyword_action_match?(text, "show_channel"), do: channel_request?(text)

  defp keyword_action_match?(text, "generate_image") do
    normalized = normalize_text(text)

    text_has_phrase_any?(normalized, [
      "generate image",
      "create image",
      "make an image",
      "text to image"
    ]) or
      Regex.match?(~r/\b(generate|create|make|draw)\b.*\b(image|picture)\b/, normalized)
  end

  defp keyword_action_match?(text, "synthesize_voice") do
    text_has_phrase_any?(text, [
      "speak",
      "read aloud",
      "say this aloud",
      "text to speech",
      "tts",
      "voice output",
      "audio output"
    ])
  end

  defp keyword_action_match?(text, "external_network_request"),
    do: text_has_any?(text, ["http", "https", "fetch", "url", "internet"])

  defp keyword_action_match?(text, "run_shell_command"),
    do: text_has_any?(text, ["run", "execute", "shell", "command"])

  defp keyword_action_match?(text, "plan_shell_command"),
    do: text_has_any?(text, ["plan command", "shell command"])

  defp keyword_action_match?(text, "list_settings"),
    do: text_has_any?(text, ["settings", "setting"])

  defp keyword_action_match?(text, "read_setting"),
    do: text_has_any?(text, ["settings", "setting"])

  defp keyword_action_match?(text, "update_setting"),
    do: text_has_any?(text, ["settings", "setting"])

  defp keyword_action_match?(_text, _action), do: false

  defp text_match?(text, value) when is_atom(value), do: text_match?(text, Atom.to_string(value))
  defp text_match?(text, value) when is_binary(value), do: exact_text_match?(text, value)
  defp text_match?(_text, _value), do: false

  defp compound_text_match?(text, value) when is_atom(value),
    do: compound_text_match?(text, Atom.to_string(value))

  defp compound_text_match?(text, value) when is_binary(text) and is_binary(value) do
    normalized_text = normalize_text(text)
    normalized_value = normalize_text(value)

    String.contains?(normalized_text, normalized_value) or
      normalized_value
      |> String.split(" ", trim: true)
      |> Enum.reject(&(String.length(&1) < 3))
      |> case do
        [] -> false
        tokens -> Enum.all?(tokens, &String.contains?(normalized_text, &1))
      end
  end

  defp compound_text_match?(_text, _value), do: false

  defp text_has_any?(text, values) when is_binary(text) do
    normalized = normalize_text(text)
    Enum.any?(values, &String.contains?(normalized, normalize_text(&1)))
  end

  defp text_has_any?(_text, _values), do: false

  defp text_has_phrase_any?(text, values) when is_binary(text) do
    normalized = " #{normalize_text(text)} "

    Enum.any?(values, fn value ->
      phrase = " #{normalize_text(value)} "
      String.contains?(normalized, phrase)
    end)
  end

  defp normalize_text(value) do
    value
    |> to_string()
    |> String.downcase()
    |> String.replace(~r/[_\-:.\/]+/, " ")
    |> String.replace(~r/\s+/, " ")
    |> String.trim()
  end

  defp boost(candidate, amount, kind, reason) do
    candidate
    |> put_field(:score, score(candidate) + amount)
    |> put_trace(:ranking_reason, kind)
    |> put_trace(:ranking_reason_text, reason)
  end

  defp score_for_sort(candidate) do
    selected_boost = if field(candidate, :selected?) == true, do: 1.0, else: 0.0
    status_boost = if field(candidate, :status) == :selected, do: 0.5, else: 0.0
    score(candidate) + selected_boost + status_boost
  end

  defp ranking_context(context) do
    request = request_from_context(context)

    %{
      text: field(request, :text) || field(context, :text),
      active_app: normalize_active_app(field(request, :active_app) || field(context, :active_app))
    }
  end

  defp request_from_context(%{request: request}) when is_map(request), do: request
  defp request_from_context(%{"request" => request}) when is_map(request), do: request
  defp request_from_context(context) when is_map(context), do: context
  defp request_from_context(_context), do: %{}

  defp normalize_active_app(nil), do: :allbert

  defp normalize_active_app(active_app) do
    case AppRegistry.normalize_app_id(active_app) do
      {:ok, nil} -> :allbert
      {:ok, app_id} -> app_id
      {:error, _reason} -> :allbert
    end
  catch
    :exit, _reason -> :allbert
  end

  defp normalize_score(value) when is_integer(value), do: normalize_score(value / 1)
  defp normalize_score(value) when is_float(value), do: value |> max(0.0) |> min(1.0)
  defp normalize_score(_value), do: 0.0

  defp field(value, key, default \\ nil)

  defp field(%_struct{} = struct, key, default), do: Map.get(struct, key, default)

  defp field(map, key, default) when is_map(map) do
    Map.get(map, key, Map.get(map, Atom.to_string(key), default))
  end

  defp field(_value, _key, default), do: default

  defp put_field(%_struct{} = struct, key, value), do: Map.put(struct, key, value)
  defp put_field(%{} = map, key, value), do: Map.put(map, key, value)

  defp put_trace(candidate, key, value) do
    trace_metadata = field(candidate, :trace_metadata, %{}) || %{}
    put_field(candidate, :trace_metadata, Map.put(trace_metadata, key, value))
  end

  defp get_in_trace(candidate, key) do
    candidate
    |> field(:trace_metadata, %{})
    |> field(key)
  end
end
