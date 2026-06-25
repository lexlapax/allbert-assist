defmodule AllbertAssist.Maps do
  @moduledoc """
  Small map access helpers for mixed atom/string-key DTOs.

  These helpers are intentionally narrow: they do not create new atoms, and they
  return defaults instead of raising when callers pass non-map input.
  """

  @spec field(term(), atom() | String.t(), term()) :: term()
  def field(value, key, default \\ nil)

  def field(%{} = map, key, default) when is_atom(key) do
    Map.get(map, key, Map.get(map, Atom.to_string(key), default))
  end

  def field(%{} = map, key, default) when is_binary(key) do
    case Map.fetch(map, key) do
      {:ok, value} -> value
      :error -> atom_field(map, key, default)
    end
  end

  def field(_value, _key, default), do: default

  @spec get_any(term(), [atom() | String.t()], term()) :: term()
  def get_any(value, keys, default \\ nil)

  def get_any(%{} = map, keys, default) when is_list(keys) do
    Enum.find_value(keys, default, fn key ->
      case field(map, key, :__allbert_missing__) do
        :__allbert_missing__ -> false
        value -> value
      end
    end)
  end

  def get_any(_value, _keys, default), do: default

  defp atom_field(map, key, default) do
    case existing_atom(key) do
      nil -> default
      atom_key -> Map.get(map, atom_key, default)
    end
  end

  defp existing_atom(key) do
    String.to_existing_atom(key)
  rescue
    ArgumentError -> nil
  end
end
