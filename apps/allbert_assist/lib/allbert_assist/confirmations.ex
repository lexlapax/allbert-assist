defmodule AllbertAssist.Confirmations do
  @moduledoc """
  Durable confirmation request domain.

  Runtime-facing approval and denial enter through registered actions. This
  module is the plain Elixir facade those actions use behind the boundary.
  """

  alias AllbertAssist.Confirmations.Store

  defdelegate root(), to: Store
  defdelegate ensure_root!(), to: Store
  defdelegate create(attrs, opts \\ []), to: Store
  defdelegate read(id), to: Store
  defdelegate list(opts \\ []), to: Store
  defdelegate resolve(id, status, resolution_attrs \\ %{}, opts \\ []), to: Store
  defdelegate expire(opts \\ []), to: Store
end
