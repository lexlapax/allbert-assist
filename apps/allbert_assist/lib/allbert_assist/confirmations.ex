defmodule AllbertAssist.Confirmations do
  @moduledoc """
  Durable confirmation request domain.

  Runtime-facing approval and denial enter through registered actions. This
  module is the plain Elixir facade those actions use behind the boundary.
  """

  alias AllbertAssist.Confirmations.Store

  @adapter_unavailable_note "Approved, but not executed: this target has no v0.07 adapter. External network execution is planned for v0.10."

  defdelegate root(), to: Store
  defdelegate ensure_root!(), to: Store
  defdelegate create(attrs, opts \\ []), to: Store
  defdelegate read(id), to: Store
  defdelegate list(opts \\ []), to: Store
  defdelegate resolve(id, status, resolution_attrs \\ %{}, opts \\ []), to: Store
  defdelegate expire(opts \\ []), to: Store

  @doc "Return the operator-facing explanation for adapter-unavailable approvals."
  @spec adapter_unavailable_note() :: String.t()
  def adapter_unavailable_note, do: @adapter_unavailable_note

  @doc "Return a human-readable status note for confirmation records that need one."
  @spec status_note(map()) :: String.t() | nil
  def status_note(%{"status" => "adapter_unavailable"}), do: @adapter_unavailable_note
  def status_note(_record), do: nil

  @doc "Return the standard operator-facing confirmation resolution message."
  @spec status_message(map()) :: String.t()
  def status_message(record) when is_map(record) do
    message = "Confirmation #{record["id"]} is #{record["status"]}."

    case status_note(record) do
      nil -> message
      note -> "#{message} #{note}"
    end
  end
end
