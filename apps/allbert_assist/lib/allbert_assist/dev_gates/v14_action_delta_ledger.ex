defmodule AllbertAssist.DevGates.V14ActionDeltaLedger do
  @moduledoc """
  Reconciles the immutable v1.4 M0 action roster with the append-only v1.4
  action-delta ledger.

  The ledger records only shipped static-action additions, removals, and
  ownership moves. Dynamic and declared overlays are outside this denominator.
  """

  alias AllbertAssist.DevGates.V14M0RegistryLedger

  @schema_version 1
  @normalization "v14_action_delta_ledger_v1"
  @entry_fields ~w(sequence change module id pack_id registry_order exposure param_contract security_placement envelope_owner test_owner baseline_row_sha256 current_row_sha256)
  @changes ~w(added removed moved)

  @doc "Return the repository-owned v1.4 action-delta ledger path."
  @spec fixture_path() :: Path.t()
  def fixture_path do
    Path.expand("../../../test/fixtures/v1.4/action_delta_ledger.json", __DIR__)
  end

  @doc "Load and validate the append-only ledger shape."
  @spec load!() :: map()
  def load! do
    ledger = fixture_path() |> File.read!() |> Jason.decode!()
    validate_ledger!(ledger)
  end

  @doc "Reconcile the current shipped action roster with M0 plus recorded deltas."
  @spec check!() :: :ok
  def check! do
    ledger = load!()
    frozen = V14M0RegistryLedger.load_frozen!()
    current = V14M0RegistryLedger.snapshot()

    assert_equal!(
      get_in(ledger, ["baseline", "m0_actions_sha256"]),
      get_in(frozen, ["digests", "actions_sha256"]),
      "baseline action digest"
    )

    assert_equal!(
      get_in(ledger, ["baseline", "m0_source_sha"]),
      get_in(frozen, ["provenance", "source_sha"]),
      "baseline source SHA"
    )

    baseline_rows = get_in(frozen, ["payload", "actions", "rows"])
    current_rows = get_in(current, ["payload", "actions", "rows"])

    assert_equal!(
      get_in(ledger, ["baseline", "action_count"]),
      length(baseline_rows),
      "baseline action count"
    )

    expected = roster_delta(baseline_rows, current_rows)
    recorded = Enum.map(ledger["entries"], &entry_delta/1)

    assert_equal!(recorded, expected, "action delta entries")
    :ok
  end

  defp validate_ledger!(
         %{
           "schema_version" => @schema_version,
           "normalization" => @normalization,
           "entry_contract" => @entry_fields,
           "baseline" => %{
             "m0_actions_sha256" => actions_sha,
             "m0_source_sha" => source_sha,
             "action_count" => action_count
           },
           "entries" => entries
         } = ledger
       )
       when is_binary(actions_sha) and is_binary(source_sha) and is_integer(action_count) and
              action_count >= 0 and is_list(entries) do
    assert_sha!(actions_sha, "baseline action digest")
    assert_sha!(source_sha, "baseline source SHA", 40)

    entries
    |> Enum.with_index(1)
    |> Enum.each(fn {entry, sequence} -> validate_entry!(entry, sequence) end)

    ids = Enum.map(entries, &{&1["change"], &1["id"]})
    if Enum.uniq(ids) != ids, do: raise("duplicate v1.4 action-delta identity")

    ledger
  end

  defp validate_ledger!(_ledger), do: raise("invalid v1.4 action-delta ledger")

  defp validate_entry!(entry, sequence) when is_map(entry) do
    assert_equal!(Map.keys(entry) |> Enum.sort(), Enum.sort(@entry_fields), "entry fields")
    assert_equal!(entry["sequence"], sequence, "append-only entry sequence")

    unless entry["change"] in @changes and
             Enum.all?(
               ~w(module id exposure param_contract security_placement envelope_owner test_owner),
               &(is_binary(entry[&1]) and entry[&1] != "")
             ) and
             (is_nil(entry["pack_id"]) or is_binary(entry["pack_id"])) and
             (is_nil(entry["registry_order"]) or
                (is_integer(entry["registry_order"]) and entry["registry_order"] >= 0)) do
      raise "invalid v1.4 action-delta entry #{sequence}"
    end

    assert_optional_sha!(entry["baseline_row_sha256"], "baseline row digest")
    assert_optional_sha!(entry["current_row_sha256"], "current row digest")
  end

  defp validate_entry!(_entry, sequence),
    do: raise("invalid v1.4 action-delta entry #{sequence}")

  defp roster_delta(baseline_rows, current_rows) do
    baseline = Map.new(baseline_rows, &{&1["name"], &1})
    current = Map.new(current_rows, &{&1["name"], &1})

    (Map.keys(baseline) ++ Map.keys(current))
    |> Enum.uniq()
    |> Enum.sort()
    |> Enum.flat_map(fn id ->
      case {Map.get(baseline, id), Map.get(current, id)} do
        {nil, row} -> [row_delta("added", nil, row)]
        {row, nil} -> [row_delta("removed", row, nil)]
        {same, same} -> []
        {baseline_row, current_row} -> [row_delta("moved", baseline_row, current_row)]
      end
    end)
  end

  defp entry_delta(entry) do
    %{
      "change" => entry["change"],
      "id" => entry["id"],
      "module" => entry["module"],
      "exposure" => entry["exposure"],
      "param_contract" => entry["param_contract"],
      "baseline_row_sha256" => entry["baseline_row_sha256"],
      "current_row_sha256" => entry["current_row_sha256"]
    }
  end

  defp row_delta(change, baseline, current) do
    row = current || baseline

    %{
      "change" => change,
      "id" => row["name"],
      "module" => row["module"],
      "exposure" => get_in(row, ["capability", "exposure"]),
      "param_contract" => row["input_schema_sha256"],
      "baseline_row_sha256" => row_sha(baseline),
      "current_row_sha256" => row_sha(current)
    }
  end

  defp row_sha(nil), do: nil
  defp row_sha(row), do: V14M0RegistryLedger.digest(row)

  defp assert_sha!(value, label, length \\ 64) do
    if not (is_binary(value) and String.match?(value, ~r/^[0-9a-f]+$/) and
              String.length(value) == length) do
      raise "invalid #{label}"
    end
  end

  defp assert_optional_sha!(nil, _label), do: :ok
  defp assert_optional_sha!(value, label), do: assert_sha!(value, label)

  defp assert_equal!(value, value, _label), do: :ok

  defp assert_equal!(actual, expected, label) do
    raise "v1.4 #{label} mismatch: expected=#{inspect(expected)} actual=#{inspect(actual)}"
  end
end
