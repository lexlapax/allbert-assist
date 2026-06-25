defmodule AllbertAssist.Serialization do
  @moduledoc """
  Serialization helpers for stable internal DTOs.
  """

  @spec stringify_keys(term(), keyword()) :: term()
  def stringify_keys(value, opts \\ [])

  def stringify_keys(%{} = map, opts) when not is_struct(map) do
    Map.new(map, fn {key, value} ->
      {to_string(key), stringify_keys(value, opts)}
    end)
  end

  def stringify_keys(list, opts) when is_list(list) do
    Enum.map(list, &stringify_keys(&1, opts))
  end

  def stringify_keys(value, opts) when is_atom(value) do
    if Keyword.get(opts, :atom_values?, false), do: Atom.to_string(value), else: value
  end

  def stringify_keys(value, _opts), do: value
end
