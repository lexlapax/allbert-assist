defmodule AllbertAssist.Artifacts.GC do
  @moduledoc """
  Supervised mark-and-sweep reconciliation for Artifacts Central.

  The GC has no authority to decide whether an artifact can be read or used. It
  only reconciles the content-addressed object tree against the metadata index,
  removing unindexed object files when operator policy allows orphan removal.
  """

  use GenServer

  alias AllbertAssist.Artifacts.Config
  alias AllbertAssist.Artifacts.MetadataIndex
  alias AllbertAssist.Artifacts.Store

  @type summary :: %{
          required(:status) => :completed,
          required(:root) => String.t(),
          required(:object_count) => non_neg_integer(),
          required(:metadata_count) => non_neg_integer(),
          required(:orphan_count) => non_neg_integer(),
          required(:removed_count) => non_neg_integer(),
          required(:retained_count) => non_neg_integer(),
          required(:orphans) => [String.t()],
          required(:removed) => [map()],
          required(:retained) => [String.t()]
        }

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: Keyword.get(opts, :name, __MODULE__))
  end

  @spec run_once(GenServer.server(), keyword()) :: {:ok, summary()} | {:error, term()}
  def run_once(server \\ __MODULE__, opts \\ []) do
    GenServer.call(server, {:run_once, opts})
  end

  @doc "Run one on-demand artifact GC sweep."
  @spec sweep(keyword()) :: {:ok, summary()} | {:error, term()}
  def sweep(opts \\ []) do
    root = Store.root(opts)
    delete_orphans? = Keyword.get(opts, :delete_orphans?, Config.gc_policy().delete_orphans?)

    with {:ok, object_shas} <- Store.list_objects(opts),
         {:ok, metadata_records} <- MetadataIndex.list(opts) do
      metadata_shas = MapSet.new(metadata_records, & &1.sha256)
      retained_shas = retained_shas(metadata_records)

      orphans =
        object_shas
        |> Enum.reject(&MapSet.member?(metadata_shas, &1))
        |> Enum.sort()

      removed = if delete_orphans?, do: remove_orphans(orphans, opts), else: []

      {:ok,
       %{
         status: :completed,
         root: root,
         object_count: length(object_shas),
         metadata_count: length(metadata_records),
         orphan_count: length(orphans),
         removed_count: length(removed),
         retained_count: MapSet.size(retained_shas),
         orphans: orphans,
         removed: removed,
         retained: retained_shas |> MapSet.to_list() |> Enum.sort()
       }}
    end
  end

  @impl true
  def init(opts) do
    {:ok, %{opts: Keyword.delete(opts, :name)}}
  end

  @impl true
  def handle_call({:run_once, opts}, _from, state) do
    {:reply, sweep(Keyword.merge(state.opts, opts)), state}
  end

  defp retained_shas(records) do
    records
    |> Enum.filter(fn metadata ->
      Map.get(metadata, :retention) in ["retained", "normal"] and
        Map.get(metadata, :lifecycle, "active") == "active"
    end)
    |> MapSet.new(& &1.sha256)
  end

  defp remove_orphans(orphans, opts) do
    Enum.flat_map(orphans, fn sha256 ->
      case Store.delete(sha256, opts) do
        {:ok, removed} -> [removed]
        {:error, _reason} -> []
      end
    end)
  end
end
