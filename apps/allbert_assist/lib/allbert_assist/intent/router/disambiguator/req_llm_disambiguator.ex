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

  alias AllbertAssist.Settings
  alias AllbertAssist.Settings.ModelRuntime

  @schema [
    selected: [
      type: :string,
      required: true,
      doc: "Exactly one action name from the candidates list, or __clarify__/__answer__/__none__."
    ],
    confidence: [type: :float, required: true, doc: "Confidence 0.0-1.0 in the selection."],
    reason: [type: :string, required: false, doc: "Short operator-safe explanation."],
    slots: [type: :string, required: false, doc: "JSON object of extracted argument slots, or {}."]
  ]

  @impl true
  def select(query, shortlist, context, opts) do
    with :ok <- ensure_req_llm(),
         {:ok, profile_name} <- profile_name(opts),
         {:ok, profile} <- Settings.resolve_model_profile(profile_name),
         {:ok, spec} <- ModelRuntime.model_spec(profile),
         {:ok, response} <-
           ReqLLM.generate_object(spec, prompt(query, shortlist, context), @schema, request_opts(profile, opts)),
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

  defp prompt(query, shortlist, context) do
    candidates =
      shortlist
      |> Enum.map(fn c -> "- #{c.action_name}: #{Map.get(c, :label)}" end)
      |> Enum.join("\n")

    """
    Choose how to handle the operator request by selecting exactly one option.

    `selected` must be a candidate action name below, or one of `__clarify__`,
    `__answer__`, `__none__`.

    Candidate actions are listed **best-match first** (most relevant at the top).

    Rules:
    - Pick the SINGLE best-matching action when one fits the request. Prefer the
      highest-ranked candidate that fits; pick a lower-ranked one only if it clearly
      fits the request better. Prefer acting over asking.
    - Match the request's domain to the action; do NOT pick an action from a
      different domain. E.g. taking a SCREENSHOT of a URL is a browser action, not
      image generation; SUMMARIZING an inbox is a mail action, not URL summarization.
    - `__answer__`: ONLY for general knowledge or conversation that no candidate can
      serve (e.g. "what is the capital of France"). If a candidate would RETRIEVE
      the answer from the user's own data (list/show/read/recall their notes,
      memory, settings, models, skills, channels, apps, objectives, marketplace…),
      pick that candidate — a question phrased as "what … do I have / what do you
      remember / what's in …" is a retrieval action, not `__answer__`.
    - `__none__`: no candidate action fits the request (out of scope / unsupported).
    - `__clarify__`: ONLY when two or more candidates genuinely and equally fit and
      you cannot choose — never for a merely-related neighbour.
    - Do not invent an action name that is not in the list.
    - Put any extracted arguments in `slots` as a JSON object (or {}).
    - Set `confidence` honestly: high when one action clearly fits, low when unsure.

    Recent context (may be empty):
    #{to_string(Map.get(context, :summary, ""))}

    Operator request:
    #{query}

    Candidate actions (best-match first):
    #{candidates}
    """
  end

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

  defp parse_slots(value) when is_map(value), do: value

  defp parse_slots(value) when is_binary(value) and value != "" do
    case Jason.decode(value) do
      {:ok, map} when is_map(map) -> map
      _other -> %{}
    end
  end

  defp parse_slots(_value), do: %{}

  defp field(map, key) when is_map(map),
    do: Map.get(map, key) || Map.get(map, to_string(key))

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
