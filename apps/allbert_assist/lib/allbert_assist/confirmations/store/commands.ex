defmodule AllbertAssist.Confirmations.Store.Commands do
  @moduledoc false

  alias AllbertAssist.Confirmations.Store.Persistence

  @doc false
  def finish(command, result, opts \\ []) do
    case result do
      {:ok, value} ->
        {:ok, projection} = Persistence.rebuild_projection()

        {:ok,
         projection
         |> Map.merge(%{
           last_command: command,
           last_result: {:ok, value},
           last_error: nil
         })
         |> maybe_put(:last_sweep_at, Keyword.get(opts, :last_sweep_at))}

      {:error, reason} ->
        {:ok,
         %{
           last_command: command,
           last_result: {:error, reason},
           last_error: inspect(reason)
         }}
    end
  end

  defp maybe_put(map, _key, nil), do: map
  defp maybe_put(map, key, value), do: Map.put(map, key, value)
end

defmodule AllbertAssist.Confirmations.Store.Commands.Create do
  @moduledoc false

  use Jido.Action,
    name: "allbert_confirmations_store_create",
    description: "Private confirmation-store create command."

  alias AllbertAssist.Confirmations.Store.Commands
  alias AllbertAssist.Confirmations.Store.Persistence

  @impl true
  def run(%{attrs: attrs, opts: opts}, _context) do
    Commands.finish(:create, Persistence.create(attrs, opts))
  end
end

defmodule AllbertAssist.Confirmations.Store.Commands.Read do
  @moduledoc false

  use Jido.Action,
    name: "allbert_confirmations_store_read",
    description: "Private confirmation-store read command."

  alias AllbertAssist.Confirmations.Store.Commands
  alias AllbertAssist.Confirmations.Store.Persistence

  @impl true
  def run(%{id: id}, _context) do
    Commands.finish(:read, Persistence.read(id))
  end
end

defmodule AllbertAssist.Confirmations.Store.Commands.List do
  @moduledoc false

  use Jido.Action,
    name: "allbert_confirmations_store_list",
    description: "Private confirmation-store list command."

  alias AllbertAssist.Confirmations.Store.Commands
  alias AllbertAssist.Confirmations.Store.Persistence

  @impl true
  def run(%{opts: opts}, _context) do
    Commands.finish(:list, {:ok, Persistence.list(opts)})
  end
end

defmodule AllbertAssist.Confirmations.Store.Commands.Resolve do
  @moduledoc false

  use Jido.Action,
    name: "allbert_confirmations_store_resolve",
    description: "Private confirmation-store resolve command."

  alias AllbertAssist.Confirmations.Store.Commands
  alias AllbertAssist.Confirmations.Store.Persistence

  @impl true
  def run(%{id: id, status: status, resolution_attrs: attrs, opts: opts}, _context) do
    Commands.finish(:resolve, Persistence.resolve(id, status, attrs, opts))
  end
end

defmodule AllbertAssist.Confirmations.Store.Commands.Expire do
  @moduledoc false

  use Jido.Action,
    name: "allbert_confirmations_store_expire",
    description: "Private confirmation-store expire command."

  alias AllbertAssist.Confirmations.Store.Commands
  alias AllbertAssist.Confirmations.Store.Persistence

  @impl true
  def run(%{opts: opts}, _context) do
    sweep_at =
      opts
      |> Keyword.get(:now, DateTime.utc_now())
      |> DateTime.truncate(:second)
      |> DateTime.to_iso8601()

    Commands.finish(:expire, Persistence.expire(opts), last_sweep_at: sweep_at)
  end
end

defmodule AllbertAssist.Confirmations.Store.Commands.Rebuild do
  @moduledoc false

  use Jido.Action,
    name: "allbert_confirmations_store_rebuild",
    description: "Private confirmation-store rebuild command."

  alias AllbertAssist.Confirmations.Store.Persistence

  @impl true
  def run(params, _context) do
    opts = Map.get(params, :opts, [])
    {:ok, projection} = Persistence.rebuild_projection(opts)
    {:ok, projection}
  end
end
