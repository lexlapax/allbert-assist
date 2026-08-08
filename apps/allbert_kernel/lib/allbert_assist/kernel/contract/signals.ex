defmodule AllbertAssist.Kernel.Contract.Signals do
  @moduledoc """
  Signal emission for the relocated action Registry and Runner.

  Emission is an effect, so it is a port rather than a snapshot. The kernel has
  no signal bus of its own and does not invent one: an unbound `log/1` is a
  no-op and an unbound signal build returns `{:error, :contract_unbound}` rather
  than fabricating a lifecycle record for work that was never admitted.

  The Runner never reaches these values. Its readiness gate refuses with
  `:product_not_ready` unless a binding exists for the epoch it was admitted
  under, and composition binds this contract before the readiness barrier opens,
  so an unbound signal path means the action was already refused.
  """

  alias AllbertAssist.Kernel.Contract

  @callback action_requested(String.t(), module() | nil, map(), map()) :: term()
  @callback action_completed(String.t(), module() | nil, atom(), term(), map(), integer()) ::
              term()
  @callback log(term()) :: :ok
  @callback emit_registration(atom(), map()) :: :ok

  @doc "Emit the action-requested lifecycle signal."
  @spec action_requested(String.t(), module() | nil, map(), map()) :: term()
  def action_requested(name, module, params, context),
    do: call(:action_requested, [name, module, params, context], {:error, :contract_unbound})

  @doc "Emit the action-completed lifecycle signal."
  @spec action_completed(String.t(), module() | nil, atom(), term(), map(), integer()) :: term()
  def action_completed(name, module, status, response, context, duration_ms),
    do:
      call(
        :action_completed,
        [name, module, status, response, context, duration_ms],
        {:error, :contract_unbound}
      )

  @doc "Publish an already-built signal."
  @spec log(term()) :: :ok
  def log(signal), do: call(:log, [signal])

  @doc "Emit an advisory registration-changed signal."
  @spec emit_registration(atom(), map()) :: :ok
  def emit_registration(reason, metadata), do: call(:emit_registration, [reason, metadata])

  defp call(fun, args, closed \\ :ok) do
    case Contract.fetch(:signals) do
      {:ok, implementation} -> apply(implementation, fun, args)
      {:error, _unbound} -> closed
    end
  end
end
