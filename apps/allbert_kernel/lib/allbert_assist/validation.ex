defmodule AllbertAssist.Validation do
  @moduledoc """
  Shared validation helpers for small scalar bounds.
  """

  @spec clamp_limit(term(), pos_integer(), pos_integer(), pos_integer()) :: pos_integer()
  def clamp_limit(value, default, max, min \\ 1)

  def clamp_limit(value, _default, max, min)
      when is_integer(value) and value >= min and value <= max,
      do: value

  def clamp_limit(value, _default, max, min)
      when is_integer(value) and value > max and max >= min,
      do: max

  def clamp_limit(_value, default, _max, _min), do: default
end
