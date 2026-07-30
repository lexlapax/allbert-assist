defmodule AllbertAssist.Settings.SchemaDiff do
  @moduledoc """
  Additive-only diff checks for Settings Central schema changes.

  A complete deprecation annotation (`deprecated?: true` plus a non-empty
  `deprecation_reason`) is additive when it is the only change to an existing
  row. It communicates that a preserved compatibility key grants no authority;
  it cannot change the key's stored shape, default, validation, or safety floor.
  """

  @deprecation_annotation_keys MapSet.new(["deprecated?", "deprecation_reason"])

  @type report :: %{
          required(:status) => :additive | :non_additive,
          required(:added) => [term()],
          required(:removed) => [term()],
          required(:changed) => [map()]
        }

  @doc "Compare two settings schemas and return a report."
  @spec compare(map(), map()) :: {:ok, report()} | {:error, report()}
  def compare(previous_schema, current_schema)
      when is_map(previous_schema) and is_map(current_schema) do
    previous_keys = MapSet.new(Map.keys(previous_schema))
    current_keys = MapSet.new(Map.keys(current_schema))

    removed = previous_keys |> MapSet.difference(current_keys) |> MapSet.to_list() |> Enum.sort()
    added = current_keys |> MapSet.difference(previous_keys) |> MapSet.to_list() |> Enum.sort()

    changed =
      previous_keys
      |> MapSet.intersection(current_keys)
      |> MapSet.to_list()
      |> Enum.sort()
      |> Enum.flat_map(&changed_entry(&1, previous_schema, current_schema))

    report = %{
      status: if(removed == [] and changed == [], do: :additive, else: :non_additive),
      added: added,
      removed: removed,
      changed: changed
    }

    if report.status == :additive, do: {:ok, report}, else: {:error, report}
  end

  @doc "Return true when the diff is additive-only."
  @spec additive_only?(map(), map()) :: boolean()
  def additive_only?(previous_schema, current_schema) do
    match?({:ok, %{status: :additive}}, compare(previous_schema, current_schema))
  end

  defp changed_entry(key, previous_schema, current_schema) do
    previous = Map.fetch!(previous_schema, key)
    current = Map.fetch!(current_schema, key)

    if previous == current or additive_deprecation_annotation?(previous, current) do
      []
    else
      [
        %{
          key: key,
          previous: previous,
          current: current
        }
      ]
    end
  end

  defp additive_deprecation_annotation?(previous, current)
       when is_map(previous) and is_map(current) do
    previous = stringify_keys(previous)
    current = stringify_keys(current)

    added_keys =
      current |> Map.keys() |> MapSet.new() |> MapSet.difference(MapSet.new(Map.keys(previous)))

    MapSet.equal?(added_keys, @deprecation_annotation_keys) and
      Map.drop(current, MapSet.to_list(added_keys)) == previous and
      current["deprecated?"] in [true, "true"] and
      is_binary(current["deprecation_reason"]) and
      String.trim(current["deprecation_reason"]) != ""
  end

  defp additive_deprecation_annotation?(_previous, _current), do: false

  defp stringify_keys(map), do: Map.new(map, fn {key, value} -> {to_string(key), value} end)
end
