defmodule AllbertAssist.Objectives.Runs.RunServer do
  @moduledoc """
  Temporary, Registry-addressed executor for one child objective.

  A plain GenServer fits the thin running/cancelling state machine; Jido.Agent
  routing buys nothing here. Durable lifecycle work is delegated to
  `Objectives.Lifecycle`, and this process owns no private objective truth.
  """

  use GenServer, restart: :temporary

  alias AllbertAssist.Objectives.Lifecycle
  alias AllbertAssist.Objectives.Runs.CancelToken

  def child_spec(opts) do
    child_id = Keyword.fetch!(opts, :child_id)

    %{
      id: {__MODULE__, child_id},
      start: {__MODULE__, :start_link, [opts]},
      restart: :temporary
    }
  end

  def start_link(opts), do: GenServer.start_link(__MODULE__, opts)

  @impl true
  def init(opts) do
    child_id = Keyword.fetch!(opts, :child_id)

    case Registry.register(AllbertAssist.Objectives.Runs.Registry, {:run, child_id}, nil) do
      {:ok, _} ->
        cancel_token = Keyword.get_lazy(opts, :cancel_token, &CancelToken.new/0)

        {:ok,
         %{
           child_id: child_id,
           parent_id: Keyword.fetch!(opts, :parent_id),
           coordinator: Keyword.fetch!(opts, :coordinator),
           lifecycle_opts:
             Keyword.get(opts, :lifecycle_opts, [])
             |> Keyword.put_new(:cancel_token, cancel_token)
         }, {:continue, :run}}

      {:error, {:already_registered, pid}} ->
        {:stop, {:already_started, pid}}
    end
  end

  @impl true
  def handle_continue(:run, state) do
    result = Lifecycle.run(state.child_id, state.lifecycle_opts)
    send(state.coordinator, {:run_terminal, state.child_id, result})
    {:stop, :normal, state}
  end
end
