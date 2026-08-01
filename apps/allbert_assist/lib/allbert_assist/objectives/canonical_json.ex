defmodule AllbertAssist.Objectives.CanonicalJSON do
  @moduledoc """
  Canonical compact JSON encoding for Objective integrity bindings.

  Map keys are recursively converted to strings and ordered
  lexicographically. List order is preserved. Typed callers must validate that
  keys remain unique after stringification; this encoder preserves legacy v1
  behavior for compatibility.
  """

  @doc "Encode one value as recursively string-keyed canonical JSON."
  @spec encode(term()) :: String.t()
  def encode(value), do: value |> stringify_keys() |> encode_json()

  defp stringify_keys(value) when is_map(value),
    do: Map.new(value, fn {key, nested} -> {to_string(key), stringify_keys(nested)} end)

  defp stringify_keys(value) when is_list(value), do: Enum.map(value, &stringify_keys/1)
  defp stringify_keys(value), do: value

  defp encode_json(map) when is_map(map) do
    map
    |> Enum.sort_by(fn {key, _value} -> key end)
    |> Enum.map_join(",", fn {key, value} -> Jason.encode!(key) <> ":" <> encode_json(value) end)
    |> then(&("{" <> &1 <> "}"))
  end

  defp encode_json(list) when is_list(list),
    do: "[" <> Enum.map_join(list, ",", &encode_json/1) <> "]"

  defp encode_json(value), do: Jason.encode!(value)
end
