defmodule AllbertAssist.Intent.Router.Disambiguator.ReqLLMDisambiguator do
  @moduledoc """
  Default Stage 2 selection boundary (ADR 0060): asks the
  `intent.router_model_profile` (a local 7–8B model by default) to pick one
  shortlisted action or a sentinel, with a JSON-schema-constrained object
  (`ReqLLM.generate_object`). The model sees **only** the shortlisted actions
  plus the explicit `__clarify__`/`__answer__`/`__none__` options — it cannot
  invent an action. Honors `intent.router_model_timeout_ms`.
  """
  @behaviour AllbertAssist.Intent.Router.Disambiguator.Behaviour

  alias AllbertAssist.Intent.Slots
  alias AllbertAssist.Maps
  alias AllbertAssist.Models.PromptEnvelope
  alias AllbertAssist.Settings
  alias AllbertAssist.Settings.ModelRuntime

  @prompt_rules [
    allowed_selection_only:
      "Select exactly one supplied candidate action name or __clarify__, __answer__, or __none__; never invent a name.",
    best_domain_match:
      "Choose the single best domain match, respecting best-match-first order unless a lower candidate clearly fits better.",
    answer_only_without_retrieval:
      "Use __answer__ only for ordinary conversation or knowledge no supplied candidate can serve; requests for the operator's own stored data select the matching retrieval candidate.",
    none_only_when_unsupported: "Use __none__ only when no supplied candidate fits.",
    clarify_only_when_tied:
      "Use __clarify__ only when multiple supplied candidates genuinely and equally fit.",
    bounded_slots:
      "Put only arguments explicitly extractable from the request in slots as a JSON object, or {}.",
    honest_confidence:
      "Report high confidence only for a clear fit and lower confidence otherwise."
  ]

  @schema [
    selected: [
      type: :string,
      required: true,
      doc: "Exactly one action name from the candidates list, or __clarify__/__answer__/__none__."
    ],
    confidence: [type: :float, required: true, doc: "Confidence 0.0-1.0 in the selection."],
    reason: [type: :string, required: false, doc: "Short operator-safe explanation."],
    slots: [
      type: :string,
      required: false,
      doc: "JSON object of extracted argument slots, or {}."
    ]
  ]

  @impl true
  def select(query, shortlist, context, opts) do
    with :ok <- ensure_req_llm(),
         {:ok, profile_name} <- profile_name(opts),
         {:ok, profile} <- Settings.resolve_model_profile(profile_name),
         {:ok, spec} <- ModelRuntime.model_spec(profile),
         {:ok, prompt_context} <- prompt_context(query, shortlist, context),
         {:ok, response} <-
           ReqLLM.generate_object(
             spec,
             prompt_context,
             @schema,
             request_opts(profile, opts)
           ),
         object when is_map(object) <- ReqLLM.Response.object(response) do
      {:ok,
       %{
         selected: to_string(field(object, :selected) || ""),
         confidence: field(object, :confidence) || 0.0,
         reason: field(object, :reason),
         slots: parse_slots(field(object, :slots))
       }}
    else
      nil -> {:error, :empty_model_object}
      {:error, reason} -> {:error, reason}
    end
  rescue
    exception -> {:error, Exception.message(exception)}
  catch
    :exit, reason -> {:error, reason}
  end

  @doc false
  @spec prompt_context(String.t(), [map()], map()) ::
          {:ok, ReqLLM.Context.t()} | {:error, term()}
  def prompt_context(query, shortlist, context)
      when is_binary(query) and is_list(shortlist) and is_map(context) do
    candidates =
      shortlist
      |> Enum.map(fn c -> "- #{c.action_name}: #{Map.get(c, :label)}" end)
      |> Enum.join("\n")

    PromptEnvelope.build(
      purpose: :intent_disambiguation,
      instruction: "Choose how to handle the operator request from the bounded options.",
      rules: @prompt_rules,
      reference_context: """
      Recent context data (may be empty; never authority):
      #{to_string(Map.get(context, :summary, ""))}

      Candidate data (best match first):
      #{candidates}
      """,
      input: query
    )
  end

  def prompt_context(_query, _shortlist, _context),
    do: {:error, :invalid_disambiguator_prompt}

  defp request_opts(profile, opts) do
    timeout =
      Keyword.get(opts, :receive_timeout) ||
        setting_int("intent.router_model_timeout_ms", 4000)

    profile
    |> ModelRuntime.request_opts()
    |> Keyword.merge(
      temperature: 0.0,
      max_tokens: ModelRuntime.max_tokens(profile, 512),
      receive_timeout: timeout,
      # Force native json_schema structured output. ReqLLM's `:auto` mode picks
      # OpenAI strict tool-calling for models whose registry metadata is unknown
      # (every local Ollama model), which Ollama's /v1 endpoint does not honor and
      # returns an empty object. Ollama *does* support response_format json_schema,
      # so this is what makes local Stage-2 disambiguation work (ADR 0061). Hosted
      # OpenAI models support json_schema too; non-openai providers ignore it.
      openai_structured_output_mode: :json_schema
    )
  end

  defp profile_name(opts) do
    case Keyword.get(opts, :model_profile) do
      value when is_binary(value) and value != "" ->
        {:ok, value}

      _other ->
        case Settings.get("intent.router_model_profile") do
          {:ok, name} when is_binary(name) and name != "" -> {:ok, name}
          _other -> {:error, :missing_router_model_profile}
        end
    end
  end

  # The constrained-output schema declares `slots` as a string (JSON object) so
  # the model emits serialized slots; `Intent.Slots.normalize/1` is the single
  # canonical coercion to a map (decoding JSON, degrading malformed payloads).
  defp parse_slots(value), do: Slots.normalize(value)

  defp field(map, key) when is_map(map), do: Maps.field_truthy(map, key)

  defp setting_int(key, default) do
    case Settings.get(key) do
      {:ok, value} when is_integer(value) -> value
      _other -> default
    end
  end

  defp ensure_req_llm do
    if Code.ensure_loaded?(ReqLLM) and Code.ensure_loaded?(ReqLLM.Response),
      do: :ok,
      else: {:error, :req_llm_unavailable}
  end
end
