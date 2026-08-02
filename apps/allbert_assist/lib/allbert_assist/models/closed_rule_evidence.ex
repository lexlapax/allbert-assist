defmodule AllbertAssist.Models.ClosedRuleEvidence do
  @moduledoc """
  Pure transport and normalization boundary for catalog-keyed model judgments.

  Policy owners supply their immutable rule identifiers. This module expresses
  those identifiers as a closed JSON Schema and, in later validation, keeps
  provider judgments advisory while local code derives the aggregate result.
  It owns no state or lifecycle, so neither a Jido Agent nor a GenServer is
  appropriate.
  """

  @transport_version 2
  @violation_semantics "For every catalog-keyed rule_violations Boolean, judge the returned final output after any revision: return true only when that output still violates the rule, and false when it satisfies the rule or the rule's triggering condition does not apply."

  @doc "Return the fixed provider transport-contract version."
  @spec transport_version() :: 2
  def transport_version, do: @transport_version

  @doc "Return the shared provider-facing meaning of closed violation Booleans."
  @spec violation_semantics() :: String.t()
  def violation_semantics, do: @violation_semantics

  @doc "Return a closed raw JSON Schema for one immutable rule catalog."
  @spec schema!([String.t()]) :: map()
  def schema!(rule_ids) when is_list(rule_ids) do
    if valid_rule_ids?(rule_ids) do
      %{
        "type" => "object",
        "properties" => Map.new(rule_ids, &{&1, violation_property(&1)}),
        "required" => rule_ids,
        "additionalProperties" => false
      }
    else
      raise ArgumentError, "rule ids must be a non-empty unique list of non-empty strings"
    end
  end

  def schema!(_rule_ids) do
    raise ArgumentError, "rule ids must be a non-empty unique list of non-empty strings"
  end

  @doc "Normalize advisory violation Booleans and derive the aggregate locally."
  @spec normalize([String.t()], map()) ::
          {:ok,
           %{
             verdict: String.t(),
             failed_rule_ids: [String.t()],
             rule_results: [map()]
           }}
          | {:error, :invalid_closed_rule_evidence}
  def normalize(rule_ids, violations) when is_list(rule_ids) and is_map(violations) do
    with true <- valid_rule_ids?(rule_ids),
         {:ok, violations} <- normalize_violation_keys(violations),
         true <- Enum.sort(Map.keys(violations)) == Enum.sort(rule_ids),
         true <- Enum.all?(Map.values(violations), &is_boolean/1) do
      rule_results = Enum.map(rule_ids, &rule_result(&1, violations))

      failed_rule_ids =
        for %{"rule_id" => rule_id, "verdict" => "unsatisfied"} <- rule_results, do: rule_id

      {:ok,
       %{
         verdict: if(failed_rule_ids == [], do: "accepted", else: "unresolved"),
         failed_rule_ids: failed_rule_ids,
         rule_results: rule_results
       }}
    else
      _invalid -> {:error, :invalid_closed_rule_evidence}
    end
  end

  def normalize(_rule_ids, _violations), do: {:error, :invalid_closed_rule_evidence}

  defp rule_result(rule_id, violations) do
    verdict = if violations[rule_id], do: "unsatisfied", else: "satisfied"
    %{"rule_id" => rule_id, "verdict" => verdict}
  end

  defp violation_property(rule_id) do
    %{
      "type" => "boolean",
      "description" =>
        "For rule #{rule_id}, true means the rule remains violated in the returned final output after any revision; false means the rule is satisfied or not applicable to that final output."
    }
  end

  defp normalize_violation_keys(violations) do
    Enum.reduce_while(violations, {:ok, %{}}, fn {raw_key, value}, {:ok, normalized} ->
      with {:ok, key} <- normalize_key(raw_key),
           false <- Map.has_key?(normalized, key) do
        {:cont, {:ok, Map.put(normalized, key, value)}}
      else
        _invalid -> {:halt, {:error, :invalid_closed_rule_evidence}}
      end
    end)
  end

  defp normalize_key(key) when is_binary(key), do: {:ok, key}
  defp normalize_key(key) when is_atom(key), do: {:ok, Atom.to_string(key)}
  defp normalize_key(_key), do: {:error, :invalid_closed_rule_evidence}

  defp valid_rule_ids?([_first | _rest] = rule_ids) do
    Enum.all?(rule_ids, &(is_binary(&1) and String.trim(&1) != "")) and
      Enum.uniq(rule_ids) == rule_ids
  end

  defp valid_rule_ids?(_rule_ids), do: false
end
