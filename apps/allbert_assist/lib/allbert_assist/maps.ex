defmodule AllbertAssist.Maps do
  @moduledoc """
  Small map access helpers for mixed atom/string-key DTOs.

  These helpers are intentionally narrow: they do not create new atoms, and they
  return defaults instead of raising when callers pass non-map input.
  """

  @doc """
  Presence-based mixed-key read: a PRESENT `nil`/`false` value is returned
  as-is; the cross-type key spelling is consulted only when the first key is
  ABSENT. Use `field_truthy/3` when callers want `||` fall-through instead.
  """
  @spec field(term(), atom() | String.t(), term()) :: term()
  def field(value, key, default \\ nil)

  def field(%{} = map, key, default) when is_atom(key) do
    case Map.fetch(map, key) do
      {:ok, value} -> value
      :error -> Map.get(map, Atom.to_string(key), default)
    end
  end

  def field(%{} = map, key, default) when is_binary(key) do
    case Map.fetch(map, key) do
      {:ok, value} -> value
      :error -> atom_field(map, key, default)
    end
  end

  def field(_value, _key, default), do: default

  @doc """
  Truthy mixed-key read with `||` semantics — the falsy-aware counterpart to
  the presence-based `field/3` (v1.0.2 M8.3 consolidation of the local
  `Map.get(map, key) || Map.get(map, to_string(key))` copies).

  A present `nil`/`false` value FALLS THROUGH to the other key spelling; the
  fallback lookup uses `Map.get/3` with `default`, so a present-but-false
  fallback value is returned as-is (exactly the local copies' semantics —
  `a || b` and `a || Map.get(map, string_key, default)` agree for every
  input). String keys resolve their atom spelling only via existing atoms;
  no atoms are created. Non-map input returns `default`.

  Contrast: `field(%{enabled: false, "enabled" => true}, :enabled)` returns
  `false` (presence wins); `field_truthy/3` returns `true` (falsy falls
  through).
  """
  @spec field_truthy(term(), atom() | String.t(), term()) :: term()
  def field_truthy(value, key, default \\ nil)

  def field_truthy(%{} = map, key, default) when is_atom(key) do
    Map.get(map, key) || Map.get(map, Atom.to_string(key), default)
  end

  def field_truthy(%{} = map, key, default) when is_binary(key) do
    Map.get(map, key) || atom_field(map, key, default)
  end

  def field_truthy(_value, _key, default), do: default

  @spec get_any(term(), [atom() | String.t()], term()) :: term()
  def get_any(value, keys, default \\ nil)

  def get_any(%{} = map, keys, default) when is_list(keys) do
    keys
    |> Enum.find_value(fn key ->
      case field(map, key, :__allbert_missing__) do
        :__allbert_missing__ -> nil
        value -> {:found, value}
      end
    end)
    |> case do
      {:found, value} -> value
      nil -> default
    end
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
