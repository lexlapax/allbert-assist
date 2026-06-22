defmodule AllbertAssist.Intent.Learning.Miner do
  @moduledoc """
  Mines reviewed runtime evidence into inert learned-review intent proposals.

  Proposals are descriptor-shaped YAML under
  `<ALLBERT_HOME>/intents/learned/review/`. They are never loaded by the
  resolver until an operator explicitly promotes them into an active tier.
  """

  alias AllbertAssist.Actions.Registry, as: ActionsRegistry
  alias AllbertAssist.Intent.Router.DescriptorStore
  alias AllbertAssist.Runtime.Redactor

  @max_examples 12
  @max_evidence_refs 20
  @max_text 120
  @secret_pattern ~r/(sk|pk|api[_ -]?key|token|secret)[-_:= ]+[A-Za-z0-9._-]+/i

  @type evidence :: map()
  @type proposal :: map()

  @spec mine([evidence()] | evidence()) :: [proposal()]
  def mine(evidence) do
    evidence
    |> List.wrap()
    |> Enum.reduce(%{}, &collect_evidence/2)
    |> Enum.map(fn {_key, proposal} ->
      {:ok, _path} = DescriptorStore.put(:review, proposal)
      proposal
    end)
  end

  defp collect_evidence(%{} = evidence, acc) do
    with {:ok, action_name} <- action_name(evidence),
         {:ok, capability} <- agent_capability(action_name),
         {:ok, utterance} <- learned_utterance(evidence) do
      app_id = capability.app_id || :allbert
      key = {app_id, action_name}
      existing = Map.get(acc, key) || existing_proposal(app_id, action_name)

      Map.put(
        acc,
        key,
        merge_evidence(existing, app_id, action_name, capability, utterance, evidence)
      )
    else
      _skip -> acc
    end
  end

  defp collect_evidence(_evidence, acc), do: acc

  defp merge_evidence(existing, app_id, action_name, capability, utterance, evidence) do
    now = DateTime.utc_now() |> DateTime.truncate(:second) |> DateTime.to_iso8601()
    support_count = integer_field(existing, :support_count, 0) + 1
    evidence_refs = append_evidence_ref(field(existing, :evidence_refs, []), evidence, now)
    examples = append_unique(field(existing, :examples, []), utterance, @max_examples)
    confidence = max(float_field(existing, :confidence, 0.0), confidence(evidence))

    %{
      app_id: app_id,
      action_name: action_name,
      label: field(existing, :label) || label_for(action_name, capability),
      examples: examples,
      synonyms: field(existing, :synonyms, []) || [],
      vocabulary: field(existing, :vocabulary, default_vocabulary(examples)),
      required_slots: field(existing, :required_slots, []) || [],
      optional_slots: field(existing, :optional_slots, []) || [],
      handoff_required?: true,
      support_count: support_count,
      confidence: confidence,
      evidence_refs: evidence_refs,
      first_seen_at: field(existing, :first_seen_at) || now,
      last_seen_at: now,
      learning: %{
        source: :learned_review,
        sources: append_unique(field(existing, [:learning, :sources], []), source(evidence), 8),
        inert_until_promoted?: true
      }
    }
  end

  defp existing_proposal(app_id, action_name) do
    DescriptorStore.read_attrs(:review)
    |> Enum.find(%{}, fn attrs ->
      normalize_app_id(field(attrs, :app_id)) == app_id and
        to_string(field(attrs, :action_name)) == action_name
    end)
  end

  defp action_name(evidence) do
    case field(evidence, :action_name) || field(evidence, :action) ||
           field(evidence, :selected_action) do
      value when is_binary(value) and value != "" -> {:ok, value}
      value when is_atom(value) -> {:ok, Atom.to_string(value)}
      _value -> {:error, :missing_action_name}
    end
  end

  defp agent_capability(action_name) do
    case ActionsRegistry.capability(action_name) do
      {:ok, capability} ->
        if capability.exposure == :agent do
          {:ok, capability}
        else
          {:error, :not_agent_exposed}
        end

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp learned_utterance(evidence) do
    evidence
    |> field(:utterance)
    |> then(fn value -> value || field(evidence, :text) || field(evidence, :query) end)
    |> sanitize_text()
    |> case do
      value when is_binary(value) and value != "" -> {:ok, value}
      _value -> {:error, :missing_utterance}
    end
  end

  defp append_evidence_ref(existing, evidence, now) do
    ref =
      %{
        source: source(evidence),
        ref: sanitize(field(evidence, :evidence_ref) || field(evidence, :ref) || %{}),
        observed_at: sanitize_text(field(evidence, :observed_at) || now)
      }
      |> Enum.reject(fn {_key, value} -> value in [nil, "", %{}] end)
      |> Map.new()

    existing
    |> List.wrap()
    |> Kernel.++([ref])
    |> Enum.uniq()
    |> Enum.take(@max_evidence_refs)
  end

  defp source(evidence) do
    evidence
    |> field(:source, :unknown)
    |> to_string()
    |> sanitize_text()
  end

  defp confidence(evidence) do
    evidence
    |> field(:confidence, 0.5)
    |> normalize_float()
  end

  defp label_for(action_name, capability) do
    capability
    |> Map.get(:description)
    |> sanitize_text()
    |> case do
      value when is_binary(value) and value != "" -> value
      _value -> action_name |> String.replace("_", " ") |> String.capitalize()
    end
  end

  defp default_vocabulary(examples) do
    %{phrases: examples, negative_phrases: [], allow_single_token_match: false}
  end

  defp sanitize(value) when is_binary(value), do: sanitize_text(value)

  defp sanitize(%{} = map) do
    map
    |> Redactor.redact()
    |> Map.new(fn {key, value} -> {key, sanitize(value)} end)
  end

  defp sanitize(values) when is_list(values), do: Enum.map(values, &sanitize/1)
  defp sanitize(value), do: Redactor.redact(value)

  defp sanitize_text(nil), do: nil

  defp sanitize_text(value) do
    value
    |> to_string()
    |> Redactor.redact()
    |> to_string()
    |> String.replace(@secret_pattern, "[REDACTED_SECRET]")
    |> String.slice(0, @max_text)
    |> String.trim()
  end

  defp append_unique(values, value, max_items) do
    values
    |> List.wrap()
    |> Kernel.++([value])
    |> Enum.map(&sanitize_text/1)
    |> Enum.reject(&(&1 in [nil, ""]))
    |> Enum.uniq()
    |> Enum.take(max_items)
  end

  defp normalize_app_id(value) when is_binary(value) do
    String.to_existing_atom(value)
  rescue
    ArgumentError -> value
  end

  defp normalize_app_id(value), do: value

  defp integer_field(map, key, default) do
    case field(map, key, default) do
      value when is_integer(value) -> value
      value when is_binary(value) -> parse_integer(value, default)
      _value -> default
    end
  end

  defp float_field(map, key, default), do: field(map, key, default) |> normalize_float()

  defp normalize_float(value) when is_number(value), do: (value * 1.0) |> max(0.0) |> min(1.0)
  defp normalize_float(value) when is_binary(value), do: parse_float(value, 0.0)
  defp normalize_float(_value), do: 0.0

  defp parse_integer(value, default) do
    case Integer.parse(value) do
      {int, _rest} -> int
      :error -> default
    end
  end

  defp parse_float(value, default) do
    case Float.parse(value) do
      {float, _rest} -> float |> max(0.0) |> min(1.0)
      :error -> default
    end
  end

  defp field(map, key, default \\ nil)

  defp field(value, [], _default), do: value
  defp field(map, [key], default), do: field(map, key, default)

  defp field(map, [key | rest], default) do
    map
    |> field(key, %{})
    |> field(rest, default)
  end

  defp field(map, key, default) when is_map(map) do
    Map.get(map, key, Map.get(map, to_string(key), default))
  end

  defp field(_map, _key, default), do: default
end
