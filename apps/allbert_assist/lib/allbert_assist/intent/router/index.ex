defmodule AllbertAssist.Intent.Router.Index do
  @moduledoc """
  In-memory utterance index for the intent router Stage 1 prefilter (ADR 0061).

  Holds one embedding per registered intent descriptor — built from its
  `label`, `examples`, and `synonyms` — keyed by `action_name`/`app_id`. The
  index is rebuilt from the registry on demand via `rebuild/1` (the Stage 1
  cosine search over `entries/1` lands in M2; supervision wiring + refresh on
  registry change land in M2/M5). Embedding is local-only via
  `Intent.Router.Embedder`; when the embedder is unavailable the index reports
  status `:unavailable` and the router falls back to the deterministic ladder.
  """
  use GenServer

  alias AllbertAssist.Intent.Router.DescriptorResolver
  alias AllbertAssist.Intent.Router.Embedder

  @enforce_keys []
  defstruct entries: [], status: :not_built, built_at: nil, error: nil

  @type entry :: %{
          action_name: String.t(),
          app_id: atom() | String.t() | nil,
          label: String.t(),
          text: String.t(),
          vector: [float()]
        }
  @type t :: %__MODULE__{
          entries: [entry()],
          status: :not_built | :built | :unavailable | :error,
          built_at: DateTime.t() | nil,
          error: term()
        }

  # ── API ────────────────────────────────────────────────────────────────────

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: Keyword.get(opts, :name, __MODULE__))
  end

  @doc "Rebuild the index from the registry. Returns the new state."
  @spec rebuild(GenServer.server()) :: t()
  def rebuild(server \\ __MODULE__), do: GenServer.call(server, :rebuild, 60_000)

  @doc "Current index state."
  @spec state(GenServer.server()) :: t()
  def state(server \\ __MODULE__), do: GenServer.call(server, :state)

  @doc "Current index entries (vectors + metadata)."
  @spec entries(GenServer.server()) :: [entry()]
  def entries(server \\ __MODULE__), do: state(server).entries

  @doc "The utterance text indexed for a descriptor (label ; examples ; synonyms)."
  @spec utterance_text(map()) :: String.t()
  def utterance_text(descriptor) do
    [to_string(descriptor.label)]
    |> Kernel.++(Map.get(descriptor, :examples, []))
    |> Kernel.++(Map.get(descriptor, :synonyms, []))
    |> Enum.map(&to_string/1)
    |> Enum.reject(&(&1 == ""))
    |> Enum.join(" ; ")
  end

  # ── GenServer ────────────────────────────────────────────────────────────────

  @impl true
  def init(_opts), do: {:ok, %__MODULE__{}}

  @impl true
  def handle_call(:rebuild, _from, _state) do
    built = build()
    {:reply, built, built}
  end

  def handle_call(:state, _from, state), do: {:reply, state, state}

  defp build do
    descriptors = DescriptorResolver.resolve()
    do_build(descriptors)
  end

  defp do_build([]), do: %__MODULE__{entries: [], status: :built, built_at: DateTime.utc_now()}

  defp do_build(descriptors) do
    texts = Enum.map(descriptors, &utterance_text/1)

    case Embedder.embed(texts) do
      {:ok, vectors} when length(vectors) == length(descriptors) ->
        entries =
          descriptors
          |> Enum.zip(vectors)
          |> Enum.map(fn {descriptor, vector} ->
            %{
              action_name: descriptor.action_name,
              app_id: descriptor.app_id,
              label: to_string(descriptor.label),
              text: utterance_text(descriptor),
              vector: vector
            }
          end)

        %__MODULE__{entries: entries, status: :built, built_at: DateTime.utc_now()}

      {:ok, _mismatch} ->
        %__MODULE__{status: :error, error: :embedding_count_mismatch}

      {:error, reason} ->
        %__MODULE__{status: :unavailable, error: reason}
    end
  end
end
