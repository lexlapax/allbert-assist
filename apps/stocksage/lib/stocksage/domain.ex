defmodule StockSage.Domain do
  @moduledoc false

  import Ecto.Changeset

  @max_user_id 128
  @max_symbol 24

  def new_id(prefix) when is_binary(prefix) do
    prefix <> "_" <> Ecto.UUID.generate()
  end

  def normalize_symbol(nil), do: nil

  def normalize_symbol(symbol) when is_atom(symbol) do
    symbol |> Atom.to_string() |> normalize_symbol()
  end

  def normalize_symbol(symbol) when is_binary(symbol) do
    symbol
    |> String.trim()
    |> String.upcase()
  end

  def normalize_symbol(symbol), do: symbol

  def normalize_user_id(nil), do: nil

  def normalize_user_id(user_id) when is_binary(user_id) do
    String.trim(user_id)
  end

  def normalize_user_id(user_id), do: user_id

  def put_generated_id(attrs, prefix) do
    Map.put_new(attrs, :id, new_id(prefix))
  end

  def put_defaults(attrs, defaults) do
    Enum.reduce(defaults, attrs, fn {key, value}, acc -> Map.put_new(acc, key, value) end)
  end

  def normalize_common(changeset) do
    changeset
    |> update_change(:user_id, &normalize_user_id/1)
    |> update_change(:symbol, &normalize_symbol/1)
  end

  def validate_common(changeset) do
    changeset
    |> validate_length(:user_id, min: 1, max: @max_user_id)
    |> validate_length(:symbol, min: 1, max: @max_symbol)
  end

  def normalize_limit(limit, _default, maximum) when is_integer(limit) do
    limit
    |> max(1)
    |> min(maximum)
  end

  def normalize_limit(nil, default, _maximum), do: default

  def normalize_limit(limit, default, maximum) when is_binary(limit) do
    case Integer.parse(limit) do
      {parsed, ""} -> normalize_limit(parsed, default, maximum)
      _ -> default
    end
  end

  def normalize_limit(_limit, default, _maximum), do: default

  def normalize_offset(offset) when is_integer(offset), do: max(offset, 0)
  def normalize_offset(nil), do: 0

  def normalize_offset(offset) when is_binary(offset) do
    case Integer.parse(offset) do
      {parsed, ""} -> normalize_offset(parsed)
      _ -> 0
    end
  end

  def normalize_offset(_offset), do: 0
end
