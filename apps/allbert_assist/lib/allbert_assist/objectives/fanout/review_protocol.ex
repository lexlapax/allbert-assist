defmodule AllbertAssist.Objectives.Fanout.ReviewProtocol do
  @moduledoc """
  Pure compiler and validator for one bounded two-critic review round.

  Consumer policies own rule meaning, ordered rule groups, and the group-catalog
  digest. This module proves the supplied groups are one exact disjoint cover,
  binds the two closed source handles to whole-source digests, validates typed
  critic assessments, and merges them deterministically. It owns no process,
  durable state, capability, or effect authority.
  """

  alias AllbertAssist.Objectives.CanonicalJSON

  @review_protocol_version 1
  @critic_group_count 2
  @source_handles ["task_contract", "candidate"]
  @statuses ["satisfied", "violated", "unresolved"]
  @assessment_digest_domain "allbert:fanout-review-assessment:v1\0"

  @enforce_keys [
    :review_protocol_version,
    :policy_version,
    :rule_group_catalog_version,
    :rule_group_catalog_sha256,
    :rule_ids,
    :rule_specs,
    :groups
  ]
  defstruct @enforce_keys

  @type t :: %__MODULE__{
          review_protocol_version: 1,
          policy_version: pos_integer(),
          rule_group_catalog_version: pos_integer(),
          rule_group_catalog_sha256: String.t(),
          rule_ids: [String.t()],
          rule_specs: [map()],
          groups: [map()]
        }

  @doc "Compile a consumer-owned rule catalog into the closed review protocol."
  @spec compile([map()], [map()], keyword()) ::
          {:ok, t()} | {:error, :invalid_review_protocol}
  def compile(rule_specs, groups, opts \\ [])

  def compile(rule_specs, groups, opts)
      when is_list(rule_specs) and is_list(groups) and is_list(opts) do
    with {:ok, normalized_rules} <- normalize_rules(rule_specs),
         {:ok, normalized_groups} <- normalize_groups(groups, normalized_rules),
         {:ok, policy_version} <- positive_option(opts, :policy_version),
         {:ok, group_catalog_version} <-
           positive_option(opts, :rule_group_catalog_version),
         {:ok, group_catalog_sha256} <-
           sha256_option(opts, :rule_group_catalog_sha256) do
      {:ok,
       %__MODULE__{
         review_protocol_version: @review_protocol_version,
         policy_version: policy_version,
         rule_group_catalog_version: group_catalog_version,
         rule_group_catalog_sha256: group_catalog_sha256,
         rule_ids: Enum.map(normalized_rules, & &1["id"]),
         rule_specs: normalized_rules,
         groups: normalized_groups
       }}
    else
      _invalid -> {:error, :invalid_review_protocol}
    end
  end

  def compile(_rule_specs, _groups, _opts), do: {:error, :invalid_review_protocol}

  @doc "Return the two consumer-defined group identifiers in catalog order."
  @spec group_ids(t()) :: [String.t()]
  def group_ids(%__MODULE__{groups: groups}), do: Enum.map(groups, & &1["id"])

  @doc false
  @spec bind_sources(map(), String.t()) :: {:ok, map()} | {:error, :invalid_review_sources}
  def bind_sources(%{"task_contract" => task_contract} = sources, candidate)
      when map_size(sources) == 1 and is_binary(task_contract) and is_binary(candidate) do
    if nonempty?(task_contract) and nonempty?(candidate) do
      {:ok,
       %{
         "task_contract" => source_binding(task_contract),
         "candidate" => source_binding(candidate)
       }}
    else
      {:error, :invalid_review_sources}
    end
  end

  def bind_sources(_sources, _candidate), do: {:error, :invalid_review_sources}

  @doc false
  @spec critic_request(t(), String.t(), map()) ::
          {:ok, map()} | {:error, :invalid_review_protocol}
  def critic_request(%__MODULE__{} = protocol, group_id, source_bindings)
      when is_binary(group_id) and is_map(source_bindings) do
    with {:ok, group} <- fetch_group(protocol, group_id),
         true <- valid_source_bindings?(source_bindings) do
      {:ok,
       %{
         "review_protocol_version" => protocol.review_protocol_version,
         "policy_version" => protocol.policy_version,
         "rule_group_catalog_version" => protocol.rule_group_catalog_version,
         "rule_group_catalog_sha256" => protocol.rule_group_catalog_sha256,
         "group" => group,
         "sources" => source_bindings
       }}
    else
      _invalid -> {:error, :invalid_review_protocol}
    end
  end

  def critic_request(_protocol, _group_id, _source_bindings),
    do: {:error, :invalid_review_protocol}

  @doc false
  @spec validate_group_assessment(t(), String.t(), map(), map()) ::
          {:ok, map()} | {:error, :invalid_critic_assessment}
  def validate_group_assessment(
        %__MODULE__{} = protocol,
        group_id,
        assessment,
        source_bindings
      )
      when is_binary(group_id) and is_map(assessment) and is_map(source_bindings) do
    with {:ok, group} <- fetch_group(protocol, group_id),
         true <- valid_source_bindings?(source_bindings),
         true <- exact_keys?(assessment, ~w[group_id assessments]),
         true <- assessment["group_id"] == group_id,
         raw_assessments when is_list(raw_assessments) <- assessment["assessments"],
         {:ok, normalized} <- normalize_assessments(raw_assessments),
         {:ok, ordered} <- order_group_assessments(normalized, group["rule_ids"]) do
      {:ok, %{"group_id" => group_id, "assessments" => ordered}}
    else
      _invalid -> {:error, :invalid_critic_assessment}
    end
  end

  def validate_group_assessment(_protocol, _group_id, _assessment, _source_bindings),
    do: {:error, :invalid_critic_assessment}

  @doc false
  @spec merge(t(), [map()], map()) :: {:ok, map()} | {:error, :invalid_critic_assessment}
  def merge(%__MODULE__{} = protocol, group_results, source_bindings)
      when is_list(group_results) and is_map(source_bindings) do
    with true <- valid_source_bindings?(source_bindings),
         {:ok, validated} <- validate_group_results(protocol, group_results, source_bindings) do
      group_results = order_group_results(protocol, validated)

      assessments =
        group_results
        |> Enum.flat_map(& &1["assessments"])
        |> order_assessments(protocol.rule_ids)

      revision_rule_ids =
        assessments
        |> Enum.reject(&(&1["status"] == "satisfied"))
        |> Enum.map(& &1["rule_id"])

      source_sha256 = source_sha256(source_bindings)

      digest_input = %{
        "review_protocol_version" => protocol.review_protocol_version,
        "rule_group_catalog_version" => protocol.rule_group_catalog_version,
        "rule_group_catalog_sha256" => protocol.rule_group_catalog_sha256,
        "source_sha256" => source_sha256,
        "assessments" => assessments
      }

      {:ok,
       %{
         review_protocol_version: protocol.review_protocol_version,
         critic_group_count: @critic_group_count,
         rule_group_catalog_version: protocol.rule_group_catalog_version,
         rule_group_catalog_sha256: protocol.rule_group_catalog_sha256,
         source_sha256: source_sha256,
         group_results: group_results,
         assessments: assessments,
         outcome: if(revision_rule_ids == [], do: :satisfied, else: :requires_revision),
         revision_rule_ids: revision_rule_ids,
         assessment_sha256:
           sha256(@assessment_digest_domain <> CanonicalJSON.encode(digest_input))
       }}
    else
      _invalid -> {:error, :invalid_critic_assessment}
    end
  end

  def merge(_protocol, _group_results, _source_bindings),
    do: {:error, :invalid_critic_assessment}

  defp normalize_rules(rule_specs) do
    with {:ok, normalized} <- map_all(rule_specs, &normalize_rule/1),
         ids <- Enum.map(normalized, & &1["id"]),
         true <- normalized != [] and unique?(ids) do
      {:ok, normalized}
    else
      _invalid -> {:error, :invalid_review_protocol}
    end
  end

  defp normalize_rule(rule) when is_map(rule) do
    with {:ok, id} <- normalize_id(Map.get(rule, :id, Map.get(rule, "id"))),
         instruction when is_binary(instruction) <-
           Map.get(rule, :instruction, Map.get(rule, "instruction")),
         true <- nonempty?(instruction) do
      normalized = %{"id" => id, "instruction" => instruction}

      case Map.get(rule, :criteria, Map.get(rule, "criteria")) do
        nil ->
          {:ok, normalized}

        criteria when is_list(criteria) and criteria != [] ->
          with {:ok, criteria} <- map_all(criteria, &normalize_id/1),
               true <- unique?(criteria) do
            {:ok, Map.put(normalized, "criteria", criteria)}
          else
            _invalid -> {:error, :invalid_review_protocol}
          end

        _invalid ->
          {:error, :invalid_review_protocol}
      end
    else
      _invalid -> {:error, :invalid_review_protocol}
    end
  end

  defp normalize_rule(_rule), do: {:error, :invalid_review_protocol}

  defp normalize_groups(groups, rules) when length(groups) == @critic_group_count do
    with {:ok, normalized} <- map_all(groups, &normalize_group/1),
         group_ids <- Enum.map(normalized, & &1["id"]),
         true <- unique?(group_ids),
         rule_ids <- Enum.map(rules, & &1["id"]),
         grouped_rule_ids <- Enum.flat_map(normalized, & &1["rule_ids"]),
         true <- unique?(grouped_rule_ids),
         true <- Enum.sort(grouped_rule_ids) == Enum.sort(rule_ids),
         true <- groups_follow_rule_order?(normalized, rule_ids) do
      rule_by_id = Map.new(rules, &{&1["id"], &1})

      {:ok,
       Enum.map(normalized, fn group ->
         Map.put(group, "rules", Enum.map(group["rule_ids"], &Map.fetch!(rule_by_id, &1)))
       end)}
    else
      _invalid -> {:error, :invalid_review_protocol}
    end
  end

  defp normalize_groups(_groups, _rules), do: {:error, :invalid_review_protocol}

  defp normalize_group(group) when is_map(group) do
    with true <- exact_keys?(group, ~w[id rule_ids]),
         {:ok, id} <- normalize_id(group["id"]),
         rule_ids when is_list(rule_ids) and rule_ids != [] <- group["rule_ids"],
         {:ok, normalized_rule_ids} <- map_all(rule_ids, &normalize_id/1),
         true <- unique?(normalized_rule_ids) do
      {:ok, %{"id" => id, "rule_ids" => normalized_rule_ids}}
    else
      _invalid -> {:error, :invalid_review_protocol}
    end
  end

  defp normalize_group(_group), do: {:error, :invalid_review_protocol}

  defp normalize_assessments(assessments), do: map_all(assessments, &normalize_assessment/1)

  defp normalize_assessment(assessment) when is_map(assessment) do
    with true <- exact_keys?(assessment, ~w[rule_id status source_handles]),
         {:ok, rule_id} <- normalize_id(assessment["rule_id"]),
         status when status in @statuses <- assessment["status"],
         handles when is_list(handles) and handles != [] <- assessment["source_handles"],
         true <- Enum.all?(handles, &(&1 in @source_handles)),
         true <- unique?(handles) do
      {:ok,
       %{
         "rule_id" => rule_id,
         "status" => status,
         "source_handles" => Enum.filter(@source_handles, &(&1 in handles))
       }}
    else
      _invalid -> {:error, :invalid_critic_assessment}
    end
  end

  defp normalize_assessment(_assessment), do: {:error, :invalid_critic_assessment}

  defp order_group_assessments(assessments, expected_rule_ids) do
    actual_rule_ids = Enum.map(assessments, & &1["rule_id"])

    if unique?(actual_rule_ids) and Enum.sort(actual_rule_ids) == Enum.sort(expected_rule_ids) do
      by_id = Map.new(assessments, &{&1["rule_id"], &1})
      {:ok, Enum.map(expected_rule_ids, &Map.fetch!(by_id, &1))}
    else
      {:error, :invalid_critic_assessment}
    end
  end

  defp validate_group_results(protocol, group_results, source_bindings) do
    with group_ids when is_list(group_ids) <- Enum.map(group_results, & &1["group_id"]),
         true <- unique?(group_ids),
         true <- Enum.sort(group_ids) == Enum.sort(group_ids(protocol)) do
      map_all(group_results, fn result ->
        validate_group_assessment(protocol, result["group_id"], result, source_bindings)
      end)
    else
      _invalid -> {:error, :invalid_critic_assessment}
    end
  end

  defp order_group_results(protocol, group_results) do
    by_id = Map.new(group_results, &{&1["group_id"], &1})
    Enum.map(group_ids(protocol), &Map.fetch!(by_id, &1))
  end

  defp order_assessments(assessments, rule_ids) do
    by_id = Map.new(assessments, &{&1["rule_id"], &1})
    Enum.map(rule_ids, &Map.fetch!(by_id, &1))
  end

  defp fetch_group(%__MODULE__{groups: groups}, group_id) do
    case Enum.find(groups, &(&1["id"] == group_id)) do
      nil -> {:error, :invalid_review_protocol}
      group -> {:ok, group}
    end
  end

  defp groups_follow_rule_order?(groups, rule_ids) do
    positions = rule_ids |> Enum.with_index() |> Map.new()

    Enum.all?(groups, fn group ->
      indexes = Enum.map(group["rule_ids"], &Map.fetch!(positions, &1))
      indexes == Enum.sort(indexes)
    end)
  end

  defp valid_source_bindings?(bindings) when is_map(bindings) do
    exact_keys?(bindings, @source_handles) and
      Enum.all?(@source_handles, fn handle ->
        case bindings[handle] do
          %{"content" => content, "sha256" => digest} = binding
          when map_size(binding) == 2 and is_binary(content) ->
            nonempty?(content) and sha256?(digest) and digest == sha256(content)

          _invalid ->
            false
        end
      end)
  end

  defp valid_source_bindings?(_bindings), do: false

  defp source_binding(content), do: %{"content" => content, "sha256" => sha256(content)}

  defp source_sha256(bindings),
    do: Map.new(@source_handles, &{&1, bindings[&1]["sha256"]})

  defp positive_option(opts, key) do
    case Keyword.fetch(opts, key) do
      {:ok, value} when is_integer(value) and value > 0 -> {:ok, value}
      _missing_or_invalid -> {:error, :invalid_review_protocol}
    end
  end

  defp sha256_option(opts, key) do
    case Keyword.fetch(opts, key) do
      {:ok, value} ->
        if(sha256?(value), do: {:ok, value}, else: {:error, :invalid_review_protocol})

      :error ->
        {:error, :invalid_review_protocol}
    end
  end

  defp map_all(values, function) do
    values
    |> Enum.reduce_while({:ok, []}, fn value, {:ok, acc} ->
      case function.(value) do
        {:ok, normalized} -> {:cont, {:ok, [normalized | acc]}}
        {:error, _reason} = error -> {:halt, error}
      end
    end)
    |> case do
      {:ok, reversed} -> {:ok, Enum.reverse(reversed)}
      {:error, _reason} = error -> error
    end
  end

  defp normalize_id(value) when is_atom(value), do: normalize_id(Atom.to_string(value))

  defp normalize_id(value) when is_binary(value) do
    if value != "" and String.match?(value, ~r/^[a-z][a-z0-9_]*$/),
      do: {:ok, value},
      else: {:error, :invalid_review_protocol}
  end

  defp normalize_id(_value), do: {:error, :invalid_review_protocol}

  defp unique?(values), do: length(values) == MapSet.size(MapSet.new(values))
  defp exact_keys?(map, keys), do: Enum.sort(Map.keys(map)) == Enum.sort(keys)
  defp nonempty?(value), do: is_binary(value) and String.trim(value) != ""

  defp sha256?(value) when is_binary(value) and byte_size(value) == 64 do
    case Base.decode16(value, case: :lower) do
      {:ok, decoded} -> byte_size(decoded) == 32
      :error -> false
    end
  end

  defp sha256?(_value), do: false

  defp sha256(value) do
    :sha256
    |> :crypto.hash(value)
    |> Base.encode16(case: :lower)
  end
end
