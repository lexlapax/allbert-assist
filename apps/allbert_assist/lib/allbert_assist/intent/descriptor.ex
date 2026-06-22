defmodule AllbertAssist.Intent.Descriptor do
  @moduledoc """
  Inert app intent descriptor metadata.

  Descriptors help the intent engine recognize app-owned capability proposals.
  They never register actions, grant permission, set active app context, or
  bypass confirmations.
  """

  alias AllbertAssist.Actions.Capability
  alias AllbertAssist.Actions.Registry, as: ActionsRegistry
  alias AllbertAssist.App.Registry, as: AppRegistry
  alias AllbertAssist.Runtime.Redactor

  @enforce_keys [:id, :app_id, :action_name, :label]
  defstruct [
    :id,
    :app_id,
    :action_name,
    :label,
    :source,
    :source_module,
    :destination,
    examples: [],
    synonyms: [],
    required_slots: [],
    optional_slots: [],
    slot_extractors: %{},
    vocabulary: %{},
    handoff_required?: true,
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
          examples: [String.t()],
          synonyms: [String.t()],
          required_slots: [atom()],
          optional_slots: [atom()],
          slot_extractors: %{atom() => atom()},
          vocabulary: map(),
          handoff_required?: boolean(),
          capability: map()
        }

  @slot_extractors [
    :ticker_symbol,
    :title_phrase,
    :body_phrase,
    :note_path_phrase,
    :email_address,
    :message_body_phrase,
    :channel_name_phrase,
    :channel_target_phrase,
    :calendar_title_phrase,
    :calendar_start_phrase
  ]
  @max_descriptor_text 120
  @max_extracted_slot_text 1_000
  @max_list_items 20
  @slot_regex ~r/^[a-z][a-z0-9_]*$/
  @destination_regex ~r/^(app|workspace):[a-z][a-z0-9_]*$/

  @spec normalize(map(), keyword()) :: {:ok, t()} | {:error, map()}
  def normalize(attrs, opts \\ [])

  def normalize(attrs, opts) when is_map(attrs) and is_list(opts) do
    with {:ok, app_id} <- app_id(field(attrs, :app_id), Keyword.get(opts, :app_id)),
         {:ok, action_name} <- action_name(field(attrs, :action_name)),
         {:ok, capability} <- capability(app_id, action_name, attrs, opts),
         {:ok, label} <- bounded_required_string(field(attrs, :label), :label),
         {:ok, destination} <- optional_destination(field(attrs, :destination)),
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
         examples: examples,
         synonyms: synonyms,
         required_slots: required_slots,
         optional_slots: optional_slots -- required_slots,
         slot_extractors: slot_extractors,
         vocabulary: vocabulary,
         handoff_required?: field(attrs, :handoff_required?, true) == true,
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

  @spec to_map(t()) :: map()
  def to_map(%__MODULE__{} = descriptor) do
    descriptor
    |> Map.from_struct()
    |> Redactor.redact()
  end

  defp app_id(nil, nil), do: {:error, :missing_app_id}

  defp app_id(value, fallback) do
    value = value || fallback

    case AppRegistry.normalize_app_id(value) do
      {:ok, app_id} when is_atom(app_id) -> {:ok, app_id}
      {:error, reason} -> {:error, {:invalid_app_id, reason}}
    end
  catch
    :exit, reason -> {:error, {:invalid_app_id, reason}}
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
          registered_capability(app_id, action_name)
        end

      _other ->
        registered_capability(app_id, action_name)
    end
  end

  defp registered_capability(app_id, action_name) do
    case ActionsRegistry.capability(action_name) do
      {:ok, capability} ->
        cond do
          not app_id_matches?(capability.app_id, app_id) ->
            {:error, {:action_app_mismatch, app_id, action_name}}

          capability.exposure != :agent ->
            {:error, {:action_not_agent_exposed, action_name}}

          true ->
            {:ok, Capability.summary(capability)}
        end

      {:error, reason} ->
        {:error, {:unknown_action, action_name, reason}}
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

  defp bounded_string_list(values, field_name) when is_list(values) do
    values =
      values
      |> Enum.map(&bounded_string/1)
      |> Enum.reject(&is_nil/1)
      |> Enum.uniq()
      |> Enum.take(@max_list_items)

    {:ok, values}
  rescue
    _exception -> {:error, {:invalid_field, field_name}}
  end

  defp bounded_string_list(_values, field_name), do: {:error, {:invalid_field, field_name}}

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
           ) do
      {:ok,
       %{
         phrases: Enum.uniq(phrases ++ positive_phrases),
         negative_phrases: negative_phrases,
         allow_single_token_match: field(values, :allow_single_token_match, true) != false
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
    text
    |> extract_phrase([
      ~r/\b(?:titled|title|called|named)\s+(.+?)(?:\s+(?:with\s+body|body|with|saying|that\s+says|says)\b|$)/i
    ])
    |> trim_extracted_slot()
  end

  defp extract_slot(:body_phrase, text) do
    text
    |> extract_phrase([
      ~r/\bwith\s+body\s+(.+)$/i,
      ~r/\bbody\s+(.+)$/i,
      ~r/\b(?:saying|that\s+says|says)\s+(.+)$/i,
      ~r/\b(?:titled|title|called|named)\s+.+?\s+with\s+(.+)$/i
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
      ~r/\babout\s+(.+)$/i
    ])
    |> trim_extracted_slot()
  end

  defp extract_slot(:channel_name_phrase, text) do
    text
    |> extract_phrase([
      ~r/\bsend\s+a\s+([a-z][a-z0-9_-]*)\s+message\b/i,
      ~r/\b(?:on|via)\s+([a-z][a-z0-9_-]*)\b/i
    ])
    |> trim_extracted_slot()
    |> downcase_slot()
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

  defp field(map, key, default \\ nil)

  defp field(map, key, default) when is_map(map) do
    Map.get(map, key, Map.get(map, Atom.to_string(key), default))
  end
end
