defmodule AllbertAssist.Pack.Supervisor do
  @moduledoc "Owns the authoritative Pack Registry and Readiness as one restart epoch."

  use Supervisor

  alias AllbertAssist.Kernel.Contract.Owner, as: ContractOwner
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

    contract_owner = Keyword.get(opts, :contract_owner, ContractOwner)

    children = [
      {Registry, [name: registry, publication: publication, coordinator: coordinator]},
      {Readiness, [name: readiness, registry: registry, coordinator: coordinator]},
      # Shares the Pack restart epoch: a registry or barrier restart must take
      # the sealed contract binding down with the snapshot that produced it.
      {ContractOwner, [name: contract_owner]}
    ]

    Supervisor.init(children, strategy: :one_for_all)
  end
end
