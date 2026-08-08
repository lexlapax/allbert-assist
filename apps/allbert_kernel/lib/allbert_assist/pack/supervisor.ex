defmodule AllbertAssist.Pack.Supervisor do
  @moduledoc "Owns the authoritative Pack Registry and Readiness as one restart epoch."

  use Supervisor

  alias AllbertAssist.Pack.{Readiness, Registry}

  @spec start_link(keyword()) :: Supervisor.on_start()
  def start_link(opts \\ []) do
    name = Keyword.get(opts, :name, __MODULE__)
    Supervisor.start_link(__MODULE__, opts, name: name)
  end

  @impl true
  def init(opts) do
    coordinator = Keyword.get(opts, :coordinator, :allbert_pack_composition_owner)
    registry = Keyword.get(opts, :registry, Registry)
    readiness = Keyword.get(opts, :readiness, Readiness)
    publication = Keyword.get(opts, :publication, :authoritative)

    children = [
      {Registry, [name: registry, publication: publication, coordinator: coordinator]},
      {Readiness, [name: readiness, registry: registry, coordinator: coordinator]}
    ]

    Supervisor.init(children, strategy: :one_for_all)
  end
end
