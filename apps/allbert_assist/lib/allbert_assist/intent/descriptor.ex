defmodule AllbertAssist.Intent.Descriptor do
  @moduledoc """
  Inert app intent descriptor metadata.

  Descriptors help the intent engine recognize app-owned capability proposals.
  They never register actions, grant permission, set active app context, or
  bypass confirmations.
  """

  alias AllbertAssist.Actions.Capability
  alias AllbertAssist.Actions.Registry, as: ActionsRegistry
  alias AllbertAssist.Maps
  alias AllbertAssist.RegistryContext
  alias AllbertAssist.Runtime.Redactor
  alias AllbertAssist.Session.AppId

  @enforce_keys [:id, :app_id, :action_name, :label]
  defstruct [
    :id,
    :app_id,
    :action_name,
    :label,
    :source,
    :source_module,
    :destination,
    selection_policy: :semantic,
    examples: [],
    synonyms: [],
    required_slots: [],
    optional_slots: [],
    slot_extractors: %{},
    vocabulary: %{},
    handoff_required?: true,
    # F5 Q3: demo/example intents (e.g. StockSage) set this false so a fresh install does
    # not route general prompts to them; the router keeps them out of the default shortlist
    # unless the descriptor gate is bypassed (tests) or a future opt-in enables demos.
    routable_by_default?: true,
    capability: %{}
  ]

  @type t :: %__MODULE__{
          id: String.t(),
          app_id: atom(),
          action_name: String.t(),
          label: String.t(),
          source: atom() | nil,
          source_module: module() | nil,
          destination: String.t() | nil,
          selection_policy: :semantic | :explicit_evidence,
          examples: [String.t()],
          synonyms: [String.t()],
          required_slots: [atom()],
          optional_slots: [atom()],
          slot_extractors: %{atom() => atom()},
          vocabulary: map(),
          handoff_required?: boolean(),
          routable_by_default?: boolean(),
          capability: map()
        }

  @type match_context :: %{
          optional(:source_text) => String.t(),
          required(:normalized_text) => String.t(),
          required(:tokens) => [String.t()]
        }

  @slot_extractors [
    :ticker_symbol,
    :title_phrase,
    :body_phrase,
    :memory_phrase,
    :note_path_phrase,
    :email_address,
    :message_body_phrase,
    :channel_name_phrase,
    :channel_target_phrase,
    :calendar_title_phrase,
    :calendar_start_phrase,
    :url_phrase
  ]
  @max_descriptor_text 120
  @max_extracted_slot_text 1_000
  @max_list_items 20
  @max_selection_list_items 40
  @slot_regex ~r/^[a-z][a-z0-9_]*$/
  @destination_regex ~r/^(app|workspace):[a-z][a-z0-9_]*$/
  @operator_language_token_regex ~r/[\p{L}\p{N}]+/u

  @spec normalize(map(), keyword()) :: {:ok, t()} | {:error, map()}
  def normalize(attrs, opts \\ [])

  def normalize(attrs, opts) when is_map(attrs) and is_list(opts) do
    with {:ok, app_id} <- app_id(field(attrs, :app_id), Keyword.get(opts, :app_id), opts),
         {:ok, action_name} <- action_name(field(attrs, :action_name)),
         {:ok, capability} <- capability(app_id, action_name, attrs, opts),
         {:ok, label} <- bounded_required_string(field(attrs, :label), :label),
         {:ok, destination} <- optional_destination(field(attrs, :destination)),
         {:ok, selection_policy} <- selection_policy(field(attrs, :selection_policy, :semantic)),
         {:ok, examples} <- bounded_string_list(field(attrs, :examples, []), :examples),
         {:ok, synonyms} <- bounded_string_list(field(attrs, :synonyms, []), :synonyms),
         {:ok, required_slots} <- slot_list(field(attrs, :required_slots, [])),
         {:ok, optional_slots} <- slot_list(field(attrs, :optional_slots, [])),
         {:ok, slot_extractors} <-
           slot_extractors(field(attrs, :slot_extractors, %{}), required_slots ++ optional_slots),
         {:ok, vocabulary} <- vocabulary(field(attrs, :vocabulary, %{})) do
      {:ok,
       %__MODULE__{
         id: "#{app_id}:#{action_name}",
         app_id: app_id,
         action_name: action_name,
         label: label,
         source: Keyword.get(opts, :source, :app),
         source_module: Keyword.get(opts, :source_module),
         destination: destination,
         selection_policy: selection_policy,
         examples: examples,
         synonyms: synonyms,
         required_slots: required_slots,
         optional_slots: optional_slots -- required_slots,
         slot_extractors: slot_extractors,
         vocabulary: vocabulary,
         handoff_required?: field(attrs, :handoff_required?, true) == true,
         routable_by_default?: field(attrs, :routable_by_default?, true) != false,
         capability: capability
       }}
    else
      {:error, reason} ->
        {:error, diagnostic(reason, attrs, opts)}
    end
  end

  def normalize(value, opts), do: {:error, diagnostic(:invalid_descriptor, value, opts)}

  @spec normalize_many([map()], keyword()) :: %{descriptors: [t()], diagnostics: [map()]}
  def normalize_many(values, opts \\ [])

  def normalize_many(values, opts) when is_list(values) do
    Enum.reduce(values, %{descriptors: [], diagnostics: []}, fn value, acc ->
      case normalize(value, opts) do
        {:ok, descriptor} ->
          %{acc | descriptors: [descriptor | acc.descriptors]}

        {:error, diagnostic} ->
          %{acc | diagnostics: [diagnostic | acc.diagnostics]}
      end
    end)
    |> then(fn result ->
      %{
        descriptors: Enum.reverse(result.descriptors),
        diagnostics: Enum.reverse(result.diagnostics)
      }
    end)
  end

  def normalize_many(_values, opts),
    do: %{descriptors: [], diagnostics: [diagnostic(:invalid_descriptors, [], opts)]}

  @spec extract_slots(t(), String.t()) :: %{extracted_slots: map(), missing_slots: [atom()]}
  def extract_slots(%__MODULE__{} = descriptor, text) when is_binary(text) do
    extracted =
      (descriptor.required_slots ++ descriptor.optional_slots)
      |> Enum.reduce(%{}, fn slot, acc ->
        case extract_slot(Map.get(descriptor.slot_extractors, slot), text) do
          nil -> acc
          value -> Map.put(acc, slot, value)
        end
      end)

    missing = Enum.reject(descriptor.required_slots, &Map.has_key?(extracted, &1))

    %{extracted_slots: extracted, missing_slots: missing}
  end

  def extract_slots(%__MODULE__{} = descriptor, _text) do
    %{extracted_slots: %{}, missing_slots: descriptor.required_slots}
  end

  @doc "Pre-normalizes one request for reuse across descriptor candidates and phrases."
  @spec prepare_match_context(term()) :: match_context()
  def prepare_match_context(%{normalized_text: text, tokens: tokens} = context)
      when is_binary(text) and is_list(tokens),
      do: Map.put_new(context, :source_text, text)

  def prepare_match_context(value) do
    normalized_text = normalize_match_text(value)

    %{
      source_text: to_string(value),
      normalized_text: normalized_text,
      tokens: String.split(normalized_text, " ", trim: true)
    }
  end

  @doc "Returns the descriptor-owned text match score used by intent ranking and proposal evidence."
  @spec text_match_score(t() | map(), String.t() | match_context(), [term()]) ::
          non_neg_integer()
  def text_match_score(descriptor, text, extra_values \\ [])

  def text_match_score(descriptor, text, extra_values)
      when is_map(descriptor) and (is_binary(text) or is_map(text)) and is_list(extra_values) do
    match_context = prepare_match_context(text)
    vocabulary = field(descriptor, :vocabulary, %{}) || %{}
    allow_single? = field(vocabulary, :allow_single_token_match, true) != false

    if negative_text_match?(vocabulary, match_context) do
      0
    else
      descriptor_values(descriptor, vocabulary, extra_values)
      |> Enum.map(&phrase_match_score(match_context, &1, allow_single?))
      |> Enum.max(fn -> 0 end)
    end
  end

  def text_match_score(_descriptor, _text, _extra_values), do: 0

  @doc "Returns strict descriptor-owned evidence for semantic action selection."
  @spec semantic_selection_match_score(t() | map(), String.t() | match_context()) ::
          non_neg_integer()
  def semantic_selection_match_score(descriptor, text)
      when is_map(descriptor) and (is_binary(text) or is_map(text)) do
    leading_text_match_score(descriptor, prepare_match_context(text))
  end

  def semantic_selection_match_score(_descriptor, _text), do: 0

  @doc "Returns descriptor-owned category evidence used only to ground clarification options."
  @spec clarification_match_score(t() | map(), String.t() | match_context()) ::
          non_neg_integer()
  def clarification_match_score(descriptor, text)
      when is_map(descriptor) and (is_binary(text) or is_map(text)) do
    match_context = prepare_match_context(text)
    clarification_context = operator_language_match_context(match_context)
    vocabulary = field(descriptor, :vocabulary, %{}) || %{}

    if negative_text_match?(vocabulary, match_context) do
      0
    else
      vocabulary
      |> field(:clarification_phrases, [])
      |> List.wrap()
      |> Enum.map(&phrase_match_score(clarification_context, &1, true))
      |> Enum.max(fn -> 0 end)
    end
  end

  def clarification_match_score(_descriptor, _text), do: 0

  @doc "Builds generic evidence for a descriptor-governed action proposal."
  @spec selection_evidence(t() | map(), String.t(), map() | nil, match_context() | nil) :: map()
  def selection_evidence(descriptor, text, slot_result \\ nil, match_context \\ nil)

  def selection_evidence(descriptor, text, slot_result, match_context)
      when is_map(descriptor) and is_binary(text) do
    slots = slot_result || maybe_extract_slots(descriptor, text)
    extracted_slots = field(slots, :extracted_slots, %{}) || %{}
    required_slots = field(descriptor, :required_slots, []) || []
    policy = field(descriptor, :selection_policy, :semantic)
    match_context = match_context || prepare_match_context(text)

    operator_act_match_score = leading_text_match_score(descriptor, match_context)
    semantic_match_score = operator_act_match_score

    negative_text_match? =
      negative_text_match?(field(descriptor, :vocabulary, %{}) || %{}, match_context)

    required_slot_evidence? =
      required_slots != [] and Enum.all?(required_slots, &present_slot?(extracted_slots, &1))

    required_slot_selection_allowed? =
      field(field(descriptor, :vocabulary, %{}) || %{}, :allow_required_slot_selection, false) ==
        true

    %{
      descriptor_match_score: operator_act_match_score,
      descriptor_text_match?: operator_act_match_score > 0,
      semantic_match_score: semantic_match_score,
      semantic_text_match?: semantic_match_score > 0,
      negative_text_match?: negative_text_match?,
      required_slot_evidence?: required_slot_evidence?,
      required_slot_selection_allowed?: required_slot_selection_allowed?,
      satisfied?:
        selection_evidence_satisfied?(
          policy,
          operator_act_match_score,
          semantic_match_score,
          required_slot_evidence?,
          negative_text_match?,
          required_slot_selection_allowed?
        )
    }
  end

  def selection_evidence(_descriptor, _text, _slot_result, _match_context) do
    %{
      descriptor_match_score: 0,
      descriptor_text_match?: false,
      semantic_match_score: 0,
      semantic_text_match?: false,
      negative_text_match?: false,
      required_slot_evidence?: false,
      required_slot_selection_allowed?: false,
      satisfied?: false
    }
  end

  @doc "Applies the validated descriptor selection policy to proposal metadata."
  @spec selection_supported?(map()) :: boolean()
  def selection_supported?(metadata) when is_map(metadata) do
    case field(metadata, :selection_policy) do
      policy when policy in [:semantic, "semantic", :explicit_evidence, "explicit_evidence"] ->
        metadata
        |> field(:selection_evidence, %{})
        |> field(:satisfied?, false) == true

      _unknown_policy ->
        false
    end
  end

  def selection_supported?(_metadata), do: false

  @spec to_map(t()) :: map()
  def to_map(%__MODULE__{} = descriptor) do
    descriptor
    |> Map.from_struct()
    |> Redactor.redact()
  end

  defp app_id(nil, nil, _opts), do: {:error, :missing_app_id}

  defp app_id(value, fallback, opts) do
    app_id = value || fallback

    case Keyword.get(opts, :candidate_app_ids) do
      nil ->
        AppId.normalize_or(app_id, opts, &{:invalid_app_id, &1})

      app_ids when is_list(app_ids) and is_atom(app_id) ->
        if app_id in app_ids, do: {:ok, app_id}, else: {:error, {:invalid_app_id, :unknown_app}}

      _app_ids ->
        {:error, {:invalid_app_id, :unknown_app}}
    end
  end

  defp selection_policy(value) when value in [:semantic, "semantic"], do: {:ok, :semantic}

  defp selection_policy(value) when value in [:explicit_evidence, "explicit_evidence"],
    do: {:ok, :explicit_evidence}

  defp selection_policy(value), do: {:error, {:invalid_selection_policy, value}}

  # Model proposals need a descriptor-owned operator act at the start of the
  # utterance after bounded polite scaffolding. Semantic descriptors may also
  # opt in to complete-slot selection; explicit policies never do.
  defp selection_evidence_satisfied?(
         policy,
         operator_act_match_score,
         semantic_match_score,
         required_slot_evidence?,
         negative_text_match?,
         required_slot_selection_allowed?
       ) do
    if negative_text_match? do
      false
    else
      case policy do
        value when value in [:explicit_evidence, "explicit_evidence"] ->
          operator_act_match_score > 0

        value when value in [:semantic, "semantic"] ->
          semantic_match_score > 0 or
            (required_slot_selection_allowed? and required_slot_evidence?)

        _unknown ->
          false
      end
    end
  end

  # Explicit-evidence policies are operator-act aware: a descriptor-owned phrase
  # must start the utterance. This rejects quoted or supplied action language
  # without teaching the boundary prompt-specific referential regexes.
  defp leading_text_match_score(descriptor, match_context) do
    vocabulary = field(descriptor, :vocabulary, %{}) || %{}
    match_context = prepare_match_context(match_context)
    text_tokens = selection_tokens(match_context.normalized_text)
    negative_values = field(vocabulary, :negative_phrases, []) || []
    selection_negative_values = field(vocabulary, :selection_negative_phrases, []) || []

    selection_values =
      case field(vocabulary, :selection_phrases, []) || [] do
        [] -> descriptor_values(descriptor, vocabulary, [])
        values -> values
      end

    token_variants = operator_act_token_variants(text_tokens)

    if leading_selection_rejected?(
         match_context,
         negative_values,
         token_variants,
         selection_negative_values
       ) do
      0
    else
      token_variants
      |> Enum.flat_map(fn tokens ->
        Enum.map(selection_values, &leading_phrase_match_score(tokens, &1))
      end)
      |> Enum.max(fn -> 0 end)
    end
  end

  defp leading_selection_rejected?(
         match_context,
         negative_values,
         token_variants,
         selection_negative_values
       ) do
    Enum.any?([
      not operator_act_starts_lexically?(match_context.source_text),
      matching_negative_phrase?(match_context, negative_values),
      matching_leading_negative_phrase?(token_variants, selection_negative_values)
    ])
  end

  defp matching_negative_phrase?(match_context, negative_values) do
    match_context = operator_language_match_context(match_context)
    Enum.any?(negative_values, &(phrase_match_score(match_context, &1, true) > 0))
  end

  defp matching_leading_negative_phrase?(token_variants, negative_values) do
    Enum.any?(token_variants, fn tokens ->
      Enum.any?(negative_values, &(leading_phrase_match_score(tokens, &1) > 0))
    end)
  end

  # Human-reviewed operator-request scaffolding is normalized before applying
  # descriptor-owned selection phrases. This is a bounded token rule, not a
  # prompt- or action-specific regular expression.
  @operator_request_prefixes [
    ~w[could you please],
    ~w[can you please],
    ~w[would you please],
    ~w[will you please],
    ~w[could you],
    ~w[can you],
    ~w[would you],
    ~w[will you],
    ~w[please do],
    ~w[please]
  ]

  defp operator_act_token_variants(tokens) do
    stripped =
      Enum.flat_map(@operator_request_prefixes, fn prefix ->
        if Enum.take(tokens, length(prefix)) == prefix,
          do: [Enum.drop(tokens, length(prefix))],
          else: []
      end)

    Enum.uniq([tokens | stripped])
  end

  defp descriptor_values(descriptor, vocabulary, extra_values) do
    extra_values ++
      [field(descriptor, :label), field(descriptor, :action_name)] ++
      (field(descriptor, :examples, []) || []) ++
      (field(descriptor, :synonyms, []) || []) ++
      (field(vocabulary, :phrases, []) || []) ++
      (field(vocabulary, :positive_phrases, []) || [])
  end

  defp leading_phrase_match_score(text_tokens, value) when is_binary(value) do
    value_tokens = selection_tokens(value)

    cond do
      value_tokens == [] -> 0
      length(value_tokens) == 1 and String.length(hd(value_tokens)) < 4 -> 0
      Enum.take(text_tokens, length(value_tokens)) == value_tokens -> length(value_tokens)
      true -> 0
    end
  end

  defp leading_phrase_match_score(_text_tokens, _value), do: 0

  # Do not discard wrappers before deciding whether action language leads the
  # utterance. The first non-whitespace grapheme must itself be lexical; quotes,
  # code spans, escapes, blockquotes, brackets, and parenthetical supplied text
  # therefore cannot become operator acts after tokenization.
  defp operator_act_starts_lexically?(text) do
    text
    |> String.trim_leading()
    |> then(&Regex.match?(~r/^[\p{L}\p{N}]/u, &1))
  end

  # Selection phrases are operator-facing language. Treat ordinary punctuation
  # as token boundaries without altering the long-standing ranker normalization.
  # Quotes remain harmless because only a phrase at the start of the utterance
  # can satisfy explicit evidence.
  defp selection_tokens(value) do
    value
    |> to_string()
    |> String.downcase()
    |> then(&Regex.scan(@operator_language_token_regex, &1))
    |> List.flatten()
  end

  # Category vocabulary is presentation evidence, not execution authority. It
  # should nevertheless behave like operator-facing language: terminal
  # punctuation must not make `model settings?` rank differently from `model
  # settings`. Reuse the stricter selection tokenizer while retaining the
  # existing anywhere/ordered category matching semantics.
  defp operator_language_match_context(match_context) do
    match_context = prepare_match_context(match_context)
    tokens = selection_tokens(match_context.source_text)
    %{match_context | normalized_text: Enum.join(tokens, " "), tokens: tokens}
  end

  defp maybe_extract_slots(%__MODULE__{} = descriptor, text), do: extract_slots(descriptor, text)
  defp maybe_extract_slots(_descriptor, _text), do: %{extracted_slots: %{}, missing_slots: []}

  defp present_slot?(slots, slot) do
    Enum.any?([slot, to_string(slot)], fn key ->
      case Map.get(slots, key) do
        value when is_binary(value) -> String.trim(value) != ""
        nil -> false
        _value -> true
      end
    end)
  end

  defp phrase_match_score(match_context, value, allow_single?) when is_binary(value) do
    text_tokens = prepare_match_context(match_context).tokens
    normalized_value = normalize_match_text(value)
    value_tokens = String.split(normalized_value, " ", trim: true)
    token_count = length(value_tokens)

    phrase_match_score_for_tokens(
      text_tokens,
      value_tokens,
      normalized_value,
      token_count,
      allow_single?
    )
  end

  defp phrase_match_score(_text, _value, _allow_single?), do: 0

  defp phrase_match_score_for_tokens(_text_tokens, _value_tokens, "", _token_count, _allow),
    do: 0

  defp phrase_match_score_for_tokens(text_tokens, value_tokens, _value, token_count, allow) do
    if contiguous_tokens?(text_tokens, value_tokens) do
      token_count
    else
      noncontiguous_phrase_match_score(text_tokens, value_tokens, token_count, allow)
    end
  end

  defp noncontiguous_phrase_match_score(text_tokens, value_tokens, token_count, allow_single?) do
    if token_count > 1 and ordered_tokens?(text_tokens, value_tokens) do
      token_count
    else
      single_token_match_score(text_tokens, value_tokens, token_count, allow_single?)
    end
  end

  defp single_token_match_score(text_tokens, [token], 1, true) do
    if String.length(token) >= 4 and token in text_tokens, do: 1, else: 0
  end

  defp single_token_match_score(_text_tokens, _value_tokens, _token_count, _allow_single?),
    do: 0

  defp negative_text_match?(vocabulary, match_context) do
    match_context = operator_language_match_context(match_context)

    vocabulary
    |> field(:negative_phrases, [])
    |> List.wrap()
    |> Enum.any?(&(phrase_match_score(match_context, &1, true) > 0))
  end

  # Keep this byte-for-byte equivalent to the long-standing Ranker matcher:
  # ASCII uses one bounded byte walk, while non-ASCII falls back to Unicode
  # downcasing and the original punctuation/whitespace replacements. Unicode
  # letters therefore remain matchable rather than being discarded.
  defp normalize_match_text(value) do
    binary = to_string(value)

    case normalize_match_text_ascii(binary, <<>>, false) do
      :non_ascii ->
        binary
        |> String.downcase()
        |> String.replace(~r/[_\-:.\/]+/, " ")
        |> String.replace(~r/\s+/, " ")
        |> String.trim()

      normalized ->
        normalized
    end
  end

  @match_separators [?_, ?-, ?:, ?., ?/, ?\s, ?\t, ?\n, ?\r]

  defp normalize_match_text_ascii(<<c, rest::binary>>, acc, _pending?)
       when c in @match_separators do
    normalize_match_text_ascii(rest, acc, acc != <<>>)
  end

  defp normalize_match_text_ascii(<<c, rest::binary>>, acc, pending?)
       when c >= 0x20 and c <= 0x7E do
    acc = if pending?, do: <<acc::binary, ?\s>>, else: acc
    c = if c >= ?A and c <= ?Z, do: c + 32, else: c
    normalize_match_text_ascii(rest, <<acc::binary, c>>, false)
  end

  defp normalize_match_text_ascii(<<>>, acc, _pending?), do: acc
  defp normalize_match_text_ascii(_binary, _acc, _pending?), do: :non_ascii

  defp contiguous_tokens?(_text_tokens, []), do: false

  defp contiguous_tokens?(text_tokens, value_tokens) do
    text_tokens
    |> Enum.chunk_every(length(value_tokens), 1, :discard)
    |> Enum.any?(&(&1 == value_tokens))
  end

  defp ordered_tokens?(_text_tokens, []), do: false
  defp ordered_tokens?(text_tokens, tokens), do: do_ordered_tokens?(text_tokens, tokens)
  defp do_ordered_tokens?(_text_tokens, []), do: true

  defp do_ordered_tokens?(text_tokens, [token | rest]) do
    case Enum.drop_while(text_tokens, &(&1 != token)) do
      [_matched | remaining] -> do_ordered_tokens?(remaining, rest)
      [] -> false
    end
  end

  defp action_name(value) when is_atom(value), do: action_name(Atom.to_string(value))

  defp action_name(value) when is_binary(value) do
    normalized =
      value
      |> String.trim()
      |> String.downcase()

    if Regex.match?(~r/^[a-z][a-z0-9_]*$/, normalized) do
      {:ok, normalized}
    else
      {:error, {:invalid_action_name, value}}
    end
  end

  defp action_name(value), do: {:error, {:invalid_action_name, value}}

  defp capability(app_id, action_name, attrs, opts) do
    case field(attrs, :capability) do
      %{} = capability_attrs ->
        if field(capability_attrs, :registered?, true) == false do
          inert_capability(app_id, action_name, capability_attrs, opts)
        else
          registered_capability(app_id, action_name, opts)
        end

      _other ->
        registered_capability(app_id, action_name, opts)
    end
  end

  defp registered_capability(app_id, action_name, opts) do
    case capability_from_projection(action_name, opts) do
      {:ok, capability} ->
        validate_registered_capability(capability, app_id, action_name)

      :not_supplied ->
        case ActionsRegistry.capability(action_name, RegistryContext.take(opts)) do
          {:ok, capability} ->
            validate_registered_capability(Capability.summary(capability), app_id, action_name)

          {:error, reason} ->
            {:error, {:unknown_action, action_name, reason}}
        end
    end
  end

  defp capability_from_projection(action_name, opts) do
    case Keyword.get(opts, :capability_projection) do
      nil ->
        :not_supplied

      projection when is_map(projection) ->
        case Map.fetch(projection, action_name) do
          {:ok, capability} when is_map(capability) -> {:ok, capability}
          _ -> {:ok, %{name: action_name, registered?: false}}
        end

      _other ->
        {:ok, %{name: action_name, registered?: false}}
    end
  end

  defp validate_registered_capability(capability, app_id, action_name) do
    capability_app_id = field(capability, :app_id)

    cond do
      field(capability, :registered?, true) == false ->
        {:error, {:unknown_action, action_name, :not_projected}}

      not app_id_matches?(capability_app_id, app_id) ->
        {:error, {:action_app_mismatch, app_id, action_name}}

      field(capability, :exposure) != :agent ->
        {:error, {:action_not_agent_exposed, action_name}}

      true ->
        {:ok, capability}
    end
  end

  # v0.54 M9.1 (Option 1, ADR 0062): core actions carry `app_id: nil` but the
  # descriptor system needs a non-nil app_id. Treat `nil` capability app_id as the
  # reserved `:allbert` core id so core actions can be descriptorized without
  # mutating their capability metadata (which memory namespaces / surfaces / handoff
  # / traces depend on). Plugin/app actions still match their own app_id exactly.
  defp app_id_matches?(nil, :allbert), do: true
  defp app_id_matches?(capability_app_id, app_id), do: capability_app_id == app_id

  defp inert_capability(app_id, action_name, attrs, opts) do
    with {:ok, permission} <- capability_atom(field(attrs, :permission, :read_only), [:read_only]),
         {:ok, exposure} <- capability_atom(field(attrs, :exposure, :agent), [:agent]),
         {:ok, execution_mode} <-
           capability_atom(field(attrs, :execution_mode, :read_only), [:read_only]),
         {:ok, confirmation} <-
           capability_atom(field(attrs, :confirmation, :not_required), [:not_required]) do
      {:ok,
       %{
         name: action_name,
         registered?: false,
         permission: permission,
         exposure: exposure,
         execution_mode: execution_mode,
         skill_backed?: false,
         confirmation: confirmation,
         resumable?: false,
         app_id: app_id
       }
       |> put_if_present(:plugin_id, field(attrs, :plugin_id) || Keyword.get(opts, :plugin_id))}
    else
      {:error, reason} -> {:error, {:invalid_inert_capability, reason}}
    end
  end

  defp capability_atom(value, allowed) when is_atom(value) do
    if value in allowed, do: {:ok, value}, else: {:error, {:unsupported_capability_value, value}}
  end

  defp capability_atom(value, allowed) when is_binary(value) do
    value
    |> String.trim()
    |> String.downcase()
    |> String.to_existing_atom()
    |> capability_atom(allowed)
  rescue
    ArgumentError -> {:error, {:unsupported_capability_value, value}}
  end

  defp capability_atom(value, _allowed), do: {:error, {:unsupported_capability_value, value}}

  defp bounded_required_string(value, field_name) do
    case bounded_string(value) do
      string when is_binary(string) and string != "" -> {:ok, string}
      _other -> {:error, {:invalid_field, field_name}}
    end
  end

  defp bounded_string_list(values, field_name, max_items \\ @max_list_items)

  defp bounded_string_list(values, field_name, max_items)
       when is_list(values) and is_integer(max_items) and max_items > 0 do
    values =
      values
      |> Enum.map(&bounded_string/1)
      |> Enum.reject(&is_nil/1)
      |> Enum.uniq()
      |> Enum.take(max_items)

    {:ok, values}
  rescue
    _exception -> {:error, {:invalid_field, field_name}}
  end

  defp bounded_string_list(_values, field_name, _max_items),
    do: {:error, {:invalid_field, field_name}}

  defp bounded_string(value) when is_atom(value), do: bounded_string(Atom.to_string(value))

  defp bounded_string(value) when is_binary(value) do
    value = String.trim(value)

    cond do
      value == "" -> nil
      byte_size(value) <= @max_descriptor_text -> value
      true -> binary_part(value, 0, @max_descriptor_text)
    end
  end

  defp bounded_string(_value), do: nil

  defp optional_destination(nil), do: {:ok, nil}

  defp optional_destination(value) do
    case bounded_string(value) do
      destination when is_binary(destination) ->
        if Regex.match?(@destination_regex, destination) do
          {:ok, destination}
        else
          {:error, {:invalid_destination, value}}
        end

      _value ->
        {:ok, nil}
    end
  end

  defp slot_list(values) when is_list(values) do
    values
    |> Enum.map(&slot_name/1)
    |> Enum.reduce_while({:ok, []}, fn
      {:ok, slot}, {:ok, acc} -> {:cont, {:ok, [slot | acc]}}
      {:error, reason}, _acc -> {:halt, {:error, reason}}
    end)
    |> case do
      {:ok, slots} -> {:ok, slots |> Enum.reverse() |> Enum.uniq()}
      {:error, reason} -> {:error, reason}
    end
  end

  defp slot_list(_values), do: {:error, :invalid_required_slots}

  defp slot_name(value) when is_atom(value), do: slot_name(Atom.to_string(value))

  defp slot_name(value) when is_binary(value) do
    value = String.trim(value)

    if Regex.match?(@slot_regex, value) do
      {:ok, String.to_atom(value)}
    else
      {:error, {:invalid_slot, value}}
    end
  end

  defp slot_name(value), do: {:error, {:invalid_slot, value}}

  defp slot_extractors(values, required_slots) when is_map(values) do
    Enum.reduce_while(values, {:ok, %{}}, fn {slot_key, extractor}, {:ok, acc} ->
      with {:ok, slot} <- slot_name(slot_key),
           true <- slot in required_slots,
           {:ok, extractor} <- slot_extractor(extractor) do
        {:cont, {:ok, Map.put(acc, slot, extractor)}}
      else
        false -> {:halt, {:error, {:unknown_slot_extractor_slot, slot_key}}}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
  end

  defp slot_extractors(_values, _required_slots), do: {:error, :invalid_slot_extractors}

  defp slot_extractor(value) when is_atom(value) and value in @slot_extractors, do: {:ok, value}

  defp slot_extractor(value) when is_binary(value) do
    value
    |> String.trim()
    |> String.downcase()
    |> String.to_existing_atom()
    |> slot_extractor()
  rescue
    ArgumentError -> {:error, {:invalid_slot_extractor, value}}
  end

  defp slot_extractor(value), do: {:error, {:invalid_slot_extractor, value}}

  defp vocabulary(nil), do: {:ok, %{}}

  defp vocabulary(%{} = values) do
    with {:ok, phrases} <-
           bounded_string_list(vocabulary_list(values, :phrases), :vocabulary_phrases),
         {:ok, positive_phrases} <-
           bounded_string_list(vocabulary_list(values, :positive_phrases), :vocabulary_phrases),
         {:ok, negative_phrases} <-
           bounded_string_list(
             vocabulary_list(values, :negative_phrases),
             :vocabulary_negative_phrases
           ),
         {:ok, selection_phrases} <-
           bounded_string_list(
             vocabulary_list(values, :selection_phrases),
             :vocabulary_selection_phrases,
             @max_selection_list_items
           ),
         {:ok, selection_negative_phrases} <-
           bounded_string_list(
             vocabulary_list(values, :selection_negative_phrases),
             :vocabulary_selection_negative_phrases,
             @max_selection_list_items
           ),
         {:ok, clarification_phrases} <-
           bounded_string_list(
             vocabulary_list(values, :clarification_phrases),
             :vocabulary_clarification_phrases,
             @max_selection_list_items
           ) do
      {:ok,
       %{
         phrases: Enum.uniq(phrases ++ positive_phrases),
         negative_phrases: negative_phrases,
         selection_phrases: selection_phrases,
         selection_negative_phrases: selection_negative_phrases,
         clarification_phrases: clarification_phrases,
         allow_single_token_match: field(values, :allow_single_token_match, true) != false,
         allow_required_slot_selection:
           field(values, :allow_required_slot_selection, false) == true
       }}
    end
  end

  defp vocabulary(_values), do: {:error, {:invalid_field, :vocabulary}}

  defp vocabulary_list(values, key), do: field(values, key, [])

  defp extract_slot(:ticker_symbol, text) do
    Regex.scan(
      ~r/(?:^|[^A-Za-z0-9._$-])(\$?)([A-Z]{1,5}(?:[._-][A-Z]{1,4})?)(?=$|[^A-Za-z0-9._-])/,
      text,
      capture: :all_but_first
    )
    |> Enum.find_value(fn [sigil, ticker] ->
      if accepted_ticker_candidate?(ticker, explicit_ticker_reference?(sigil, ticker, text)) do
        ticker
      end
    end)
  end

  defp extract_slot(:title_phrase, text) do
    if note_colon_body?(text) do
      "note"
    else
      text
      |> extract_phrase([
        ~r/\b(?:titled|title|called|named)\s+(.+?)(?:\s+(?:with\s+body|body|with|saying|that\s+says|says)\b|$)/i
      ])
      |> trim_extracted_slot()
    end
  end

  defp extract_slot(:body_phrase, text) do
    text
    |> extract_phrase([
      ~r/\b(?:save|write|create|make)\s+a\s+note\s*:\s*(.+)$/i,
      ~r/\bwith\s+body\s+(.+)$/i,
      ~r/\bbody\s+(.+)$/i,
      ~r/\b(?:saying|that\s+says|says)\s+(.+)$/i,
      ~r/\b(?:titled|title|called|named)\s+.+?\s+with\s+(.+)$/i
    ])
    |> trim_extracted_slot()
  end

  # v0.65 local-knowledge fix: pull the memory content from natural "remember X" /
  # "note to self: X" phrasings so the launch-path memory-write loop creates a
  # reviewable candidate from chat instead of asking for the missing slot.
  defp extract_slot(:memory_phrase, text) do
    text
    |> extract_phrase([
      # Colon form after a trigger: "note to self: X", "remember this after review: X".
      ~r/\b(?:remember|memori[sz]e|keep\s+in\s+mind|note\s+to\s+self)\b[^:]*:\s*(.+)$/i,
      # "remember that X" (drop the "that").
      ~r/\bremember\s+that\s+(.+)$/i,
      # Bare "remember X" / "memorize X" / "keep in mind X" / "note to self X".
      ~r/\b(?:remember|memori[sz]e|keep\s+in\s+mind|note\s+to\s+self)\s+(.+)$/i
    ])
    |> trim_extracted_slot()
  end

  defp extract_slot(:note_path_phrase, text) do
    text
    |> extract_phrase([
      ~r/\b(?:read|open|show)\s+(?:the\s+)?(.+?)\s+note\b/i,
      ~r/\b(?:read|open|show)\s+note\s+(.+?)(?:\.md)?$/i,
      ~r/\b(?:read|open|show)\s+(.+?(?:\/.+?|\.md))$/i
    ])
    |> note_path_from_phrase()
  end

  defp extract_slot(:email_address, text) do
    text
    |> extract_phrase([
      ~r/\bto\s+([A-Z0-9._%+\-]+@[A-Z0-9.\-]+\.[A-Z]{2,})\b/i,
      ~r/\b([A-Z0-9._%+\-]+@[A-Z0-9.\-]+\.[A-Z]{2,})\b/i
    ])
    |> trim_extracted_slot()
  end

  defp extract_slot(:message_body_phrase, text) do
    text
    |> extract_phrase([
      ~r/\bwith\s+body\s+(.+)$/i,
      ~r/\bbody\s+(.+)$/i,
      ~r/\b(?:saying|that\s+says|says)\s+(.+)$/i,
      # v1.0.1 M4.3: leading-message form — "send (the exact) message <body> to ..."
      ~r/\bsend\s+(?:the\s+)?(?:exact\s+)?message\s+(.+?)\s+(?:to|on|via)\b/i,
      ~r/\babout\s+(.+)$/i
    ])
    |> trim_extracted_slot()
  end

  defp extract_slot(:channel_name_phrase, text) do
    text
    |> extract_phrase([
      ~r/\bsend\s+a\s+([a-z][a-z0-9_-]*)\s+message\b/i,
      ~r/\b(?:on|via)\s+([a-z][a-z0-9_-]*)\b/i,
      # v1.0.1 M4.3: "... my (configured) <channel> channel"
      ~r/\b([a-z][a-z0-9_-]*)\s+channel\b/i
    ])
    |> trim_extracted_slot()
    |> downcase_slot()
  end

  # v1.0.1 M4.3: `external_network_request` now requires a :url slot at the
  # DESCRIPTOR layer, so the router slot-penalizes and clarify-blocks it for
  # URL-less utterances instead of executing into a `:missing_url` denial.
  defp extract_slot(:url_phrase, text) do
    text
    |> extract_phrase([
      ~r/\b(https?:\/\/\S+)/i,
      ~r/\b(www\.\S+)/i,
      ~r/\b((?:[a-z0-9-]+\.)+(?:com|org|net|io|dev|co|edu|gov)(?:\/\S*)?)\b/i
    ])
    |> trim_extracted_slot()
  end

  defp extract_slot(:channel_target_phrase, text) do
    text
    |> extract_phrase([
      ~r/\bto\s+(#[A-Za-z0-9._-]+|@[A-Za-z0-9._-]+|[A-Za-z0-9._-]+)(?:\s+(?:saying|that\s+says|says|with\s+body|body)\b|$)/i
    ])
    |> trim_extracted_slot()
  end

  defp extract_slot(:calendar_title_phrase, text) do
    text
    |> extract_phrase([
      ~r/\b(?:titled|title|called|named)\s+(.+?)$/i,
      ~r/\bschedule\s+(?:a|an|the)?\s*(.+?)(?:\s+(?:tomorrow|today|tonight|next\s+\w+|\d{1,2}(?::\d{2})?\s*(?:am|pm)?|\d{4}-\d{2}-\d{2})\b|$)/i
    ])
    |> trim_extracted_slot()
  end

  defp extract_slot(:calendar_start_phrase, text) do
    text
    |> extract_phrase([
      ~r/\b((?:tomorrow|today|tonight|next\s+\w+)(?:\s+at)?\s+\d{1,2}(?::\d{2})?\s*(?:am|pm)?)\b/i,
      ~r/\b(\d{4}-\d{2}-\d{2}(?:\s+\d{1,2}(?::\d{2})?\s*(?:am|pm)?)?)\b/i,
      ~r/\b((?:tomorrow|today|tonight|next\s+\w+))\b/i
    ])
    |> trim_extracted_slot()
  end

  defp extract_slot(_extractor, _text), do: nil

  defp note_colon_body?(text) when is_binary(text),
    do: Regex.match?(~r/\b(?:save|write|create|make)\s+a\s+note\s*:\s*\S/i, text)

  defp accepted_ticker_candidate?(ticker, explicit?),
    do: explicit? || String.length(ticker) > 1

  defp explicit_ticker_reference?("$", _ticker, _text), do: true

  defp explicit_ticker_reference?(_sigil, ticker, text) do
    Regex.match?(~r/\b(?:ticker|symbol)\s+\$?#{Regex.escape(ticker)}\b/, text)
  end

  defp extract_phrase(text, patterns) do
    Enum.find_value(patterns, fn pattern ->
      case Regex.run(pattern, text, capture: :all_but_first) do
        [value | _rest] -> value
        _other -> nil
      end
    end)
  end

  defp trim_extracted_slot(nil), do: nil

  defp trim_extracted_slot(value) when is_binary(value) do
    value =
      value
      |> String.trim()
      |> String.trim(~s("'))
      |> String.trim()

    cond do
      value == "" -> nil
      byte_size(value) <= @max_extracted_slot_text -> value
      true -> binary_part(value, 0, @max_extracted_slot_text)
    end
  end

  defp downcase_slot(nil), do: nil
  defp downcase_slot(value) when is_binary(value), do: String.downcase(value)

  defp note_path_from_phrase(nil), do: nil

  defp note_path_from_phrase(value) when is_binary(value) do
    case trim_extracted_slot(value) do
      nil -> nil
      value -> note_path_from_trimmed_phrase(value)
    end
  end

  defp note_path_from_trimmed_phrase(value) do
    cond do
      String.contains?(value, "://") ->
        nil

      String.ends_with?(String.downcase(value), ".md") ->
        value

      String.contains?(value, "/") ->
        value <> ".md"

      true ->
        value
        |> String.downcase()
        |> String.replace(~r/[^a-z0-9]+/, "-")
        |> String.trim("-")
        |> then(&if(&1 == "", do: nil, else: &1 <> ".md"))
    end
  end

  defp diagnostic(reason, attrs, opts) do
    %{
      kind: :invalid_intent_descriptor,
      reason: Redactor.redact(reason),
      app_id: Keyword.get(opts, :app_id),
      source: Keyword.get(opts, :source, :app),
      source_module: Keyword.get(opts, :source_module),
      descriptor: attrs |> descriptor_summary() |> Redactor.redact()
    }
  end

  defp descriptor_summary(attrs) when is_map(attrs) do
    attrs
    |> Map.take([:app_id, :action_name, :label])
    |> Map.merge(Map.take(attrs, ["app_id", "action_name", "label"]))
  end

  defp descriptor_summary(_attrs), do: %{}

  defp put_if_present(map, _key, nil), do: map
  defp put_if_present(map, key, value), do: Map.put(map, key, value)

  defp field(map, key, default \\ nil), do: Maps.field(map, key, default)
end
