defmodule AllbertAssist.Confirmations.Store.Agent do
  @moduledoc """
  JidoBacked coordinator for durable confirmation records.

  Confirmation files under Allbert Home remain authoritative. This agent owns a
  rebuildable projection of pending ids and routes lifecycle commands through
  private Jido actions so the confirmation store follows the same substrate
  pattern that v0.24 objectives will use.
  """

  alias AllbertAssist.Confirmations.Store.Commands
  alias AllbertAssist.Confirmations.Store.Persistence
  alias AllbertAssist.JidoBacked

  @create "allbert.confirmations.store.create"
  @read "allbert.confirmations.store.read"
  @list "allbert.confirmations.store.list"
  @resolve "allbert.confirmations.store.resolve"
  @expire "allbert.confirmations.store.expire"
  @rebuild "allbert.confirmations.store.rebuild"

  use JidoBacked,
    name: "allbert_confirmations_store",
    description: "Coordinates durable confirmation store lifecycle transitions.",
    signal_routes: [
      {@create, Commands.Create},
      {@read, Commands.Read},
      {@list, Commands.List},
      {@resolve, Commands.Resolve},
      {@expire, Commands.Expire},
      {@rebuild, Commands.Rebuild}
    ]

  @doc false
  @impl true
  def rebuild_state(opts) do
    Persistence.rebuild_projection(opts)
  end

  @doc false
  @impl true
  def command_modules do
    [
      Commands.Create,
      Commands.Read,
      Commands.List,
      Commands.Resolve,
      Commands.Expire,
      Commands.Rebuild
    ]
  end

  @doc false
  def create(attrs, opts \\ []) when is_map(attrs) and is_list(opts) do
    dispatch(@create, %{attrs: attrs, opts: opts})
  end

  @doc false
  def read(id) when is_binary(id), do: dispatch(@read, %{id: id})

  @doc false
  def list(opts \\ []) when is_list(opts) do
    case dispatch(@list, %{opts: opts}) do
      {:ok, records} when is_list(records) -> records
      {:error, _reason} -> []
    end
  end

  @doc false
  def resolve(id, status, resolution_attrs \\ %{}, opts \\ [])
      when is_binary(id) and is_map(resolution_attrs) and is_list(opts) do
    dispatch(@resolve, %{
      id: id,
      status: status,
      resolution_attrs: resolution_attrs,
      opts: opts
    })
  end

  @doc false
  def expire(opts \\ []) when is_list(opts), do: dispatch(@expire, %{opts: opts})

  @doc false
  def ensure_root!, do: Persistence.ensure_root!()

  @doc false
  def dispatch(signal_type, data) when is_binary(signal_type) and is_map(data) do
    JidoBacked.dispatch(__MODULE__, signal_type, data,
      source: "/allbert/confirmations/store",
      timeout: :infinity
    )
  end
end
