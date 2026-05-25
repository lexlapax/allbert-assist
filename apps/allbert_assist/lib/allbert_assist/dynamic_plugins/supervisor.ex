defmodule AllbertAssist.DynamicPlugins.Supervisor do
  @moduledoc """
  Supervision tree for v0.37 dynamic integration runtime state.
  """

  use Supervisor

  def start_link(opts \\ []) do
    Supervisor.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @impl true
  def init(opts) do
    children = [
      {AllbertAssist.DynamicPlugins.Codegen.Agent, Keyword.get(opts, :codegen, [])},
      {AllbertAssist.DynamicPlugins.ActionsOverlay, Keyword.get(opts, :actions_overlay, [])},
      {AllbertAssist.DynamicPlugins.Reconciler, Keyword.get(opts, :reconciler, [])}
    ]

    Supervisor.init(children, strategy: :one_for_one)
  end
end
