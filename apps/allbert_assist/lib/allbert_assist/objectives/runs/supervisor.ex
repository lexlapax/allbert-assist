defmodule AllbertAssist.Objectives.Runs.Supervisor do
  @moduledoc "Global dynamic supervisor for temporary fan-out coordinators and runs."

  use DynamicSupervisor

  @default_safety_ceiling 48

  def start_link(opts \\ []) do
    DynamicSupervisor.start_link(__MODULE__, opts, name: Keyword.get(opts, :name, __MODULE__))
  end

  @impl true
  def init(opts) do
    DynamicSupervisor.init(
      strategy: :one_for_one,
      max_children: Keyword.get(opts, :max_children, @default_safety_ceiling)
    )
  end
end
