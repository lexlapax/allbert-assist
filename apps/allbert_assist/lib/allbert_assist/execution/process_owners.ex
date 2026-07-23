defmodule AllbertAssist.Execution.ProcessOwners do
  @moduledoc "Dynamic supervisor for temporary, scoped OS execution owners."

  use DynamicSupervisor

  def start_link(opts \\ []) do
    DynamicSupervisor.start_link(__MODULE__, opts, name: Keyword.get(opts, :name, __MODULE__))
  end

  @impl true
  def init(_opts), do: DynamicSupervisor.init(strategy: :one_for_one)
end
