defmodule AllbertAssist.Objectives.Runs.CancelToken do
  @moduledoc """
  Cooperative cancellation flag shared by a run and its lifecycle facade.

  The token is deliberately process-independent: cancelling it does not grant
  authority or kill work by itself. Lifecycle boundaries consult the flag and
  persist an honest cancelled transition. M4 layers scoped process teardown on
  top of this cooperative primitive.
  """

  defstruct [:ref]

  @type t :: %__MODULE__{ref: :atomics.atomics_ref()}

  @spec new() :: t()
  def new, do: %__MODULE__{ref: :atomics.new(1, signed: false)}

  @spec cancel(t()) :: :ok
  def cancel(%__MODULE__{ref: ref}) do
    :atomics.put(ref, 1, 1)
    :ok
  end

  @spec cancelled?(t()) :: boolean()
  def cancelled?(%__MODULE__{ref: ref}), do: :atomics.get(ref, 1) == 1

  @spec checkpoint(map()) :: :ok | :cancelled
  def checkpoint(params) when is_map(params) do
    case Map.get(params, :cancel_token, Map.get(params, "cancel_token")) do
      %__MODULE__{} = token -> if(cancelled?(token), do: :cancelled, else: :ok)
      _other -> :ok
    end
  end
end
