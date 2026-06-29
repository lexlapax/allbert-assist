defmodule AllbertAssist.Settings.SchemaDiff do
  @moduledoc """
  Additive-only diff checks for Settings Central schema changes.
  """

  @doc "Compare two settings schemas and return a report."
  @spec compare(map(), map()) :: {:ok, map()} | {:error, map()}
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

    if previous == current do
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
end
