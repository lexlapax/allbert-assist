defmodule AllbertAssist.Portability.SecretReferences do
  @moduledoc """
  Secret-reference manifest helpers for portability envelopes.
  """

  alias AllbertAssist.Settings.Secrets

  @secret_ref_pattern ~r/^secret:\/\/[A-Za-z0-9_\/.-]+$/

  @doc "Return sorted secret refs discovered in a settings/profile structure."
  @spec collect(term()) :: [String.t()]
  def collect(term), do: term |> collect(MapSet.new()) |> MapSet.to_list() |> Enum.sort()

  @doc "Return export-safe ref/status rows. Values are never fetched."
  @spec export_rows(term()) :: [map()]
  def export_rows(term) do
    term
    |> collect()
    |> Enum.map(fn ref ->
      %{
        "ref" => ref,
        "status" => Secrets.status(ref) |> to_string()
      }
    end)
  end

  @doc "Compare exported refs with the target Home's current secret status."
  @spec target_summary([map()]) :: map()
  def target_summary(rows) when is_list(rows) do
    refs =
      rows
      |> Enum.map(&Map.get(&1, "ref"))
      |> Enum.filter(&secret_ref?/1)
      |> Enum.uniq()
      |> Enum.sort()

    target_rows =
      Enum.map(refs, fn ref ->
        exported = Enum.find(rows, &(&1["ref"] == ref)) || %{}
        target_status = Secrets.status(ref) |> to_string()

        %{
          "ref" => ref,
          "exported_status" => Map.get(exported, "status", "unknown"),
          "target_status" => target_status,
          "missing_in_target" => target_status != "configured"
        }
      end)

    %{
      "required" => length(target_rows),
      "configured" => Enum.count(target_rows, &(&1["target_status"] == "configured")),
      "missing" => Enum.count(target_rows, & &1["missing_in_target"]),
      "refs" => target_rows
    }
  end

  defp collect(value, refs) when is_binary(value) do
    if secret_ref?(value), do: MapSet.put(refs, value), else: refs
  end

  defp collect(%{} = map, refs) do
    Enum.reduce(map, refs, fn {_key, value}, acc -> collect(value, acc) end)
  end

  defp collect(list, refs) when is_list(list), do: Enum.reduce(list, refs, &collect/2)
  defp collect(_term, refs), do: refs

  defp secret_ref?(value) when is_binary(value), do: Regex.match?(@secret_ref_pattern, value)
  defp secret_ref?(_value), do: false
end
