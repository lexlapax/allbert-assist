defmodule AllbertAssist.Runtime.SafeTerm do
  @moduledoc """
  Total traversal helpers for runtime-facing terms.

  Runtime payloads can come from provider adapters, model metadata, persisted
  traces, or operator-owned settings. These helpers keep malformed list tails
  from crashing safety/redaction/normalization paths that must be total.
  """

  @doc "Map over a possibly-improper list, folding a non-list tail into the output."
  @spec map_list(term(), (term() -> term())) :: list()
  def map_list(value, fun) when is_list(value), do: do_map_list(value, fun)
  def map_list(_value, _fun), do: []

  @doc "Filter a possibly-improper list, folding and testing a non-list tail."
  @spec filter_list(term(), (term() -> as_boolean(term()))) :: list()
  def filter_list(value, fun) when is_list(value), do: do_filter_list(value, fun)
  def filter_list(_value, _fun), do: []

  @doc "Convert a possibly-improper list to a proper list."
  @spec to_list(term()) :: list()
  def to_list(value) when is_list(value), do: map_list(value, & &1)
  def to_list(_value), do: []

  @doc "Wrap a term as a proper list, while normalizing malformed list tails."
  @spec wrap_list(term()) :: list()
  def wrap_list(nil), do: []
  def wrap_list(value) when is_list(value), do: to_list(value)
  def wrap_list(value), do: [value]

  defp do_map_list([head | tail], fun) when is_list(tail),
    do: [fun.(head) | do_map_list(tail, fun)]

  defp do_map_list([head | tail], fun), do: [fun.(head), fun.(tail)]
  defp do_map_list([], _fun), do: []

  defp do_filter_list([head | tail], fun) when is_list(tail) do
    rest = do_filter_list(tail, fun)

    if fun.(head) do
      [head | rest]
    else
      rest
    end
  end

  defp do_filter_list([head | tail], fun) do
    []
    |> maybe_prepend(tail, fun)
    |> maybe_prepend(head, fun)
  end

  defp do_filter_list([], _fun), do: []

  defp maybe_prepend(acc, value, fun) do
    if fun.(value) do
      [value | acc]
    else
      acc
    end
  end
end
