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
  alias AllbertAssist.Pack.EffectGuard
  alias AllbertAssist.Settings
  alias AllbertAssist.SignalBus
  alias Jido.Signal.Bus, as: JidoSignalBus

  # v0.54 M9.3b/v0.56 M11: rebuild when the action/app/plugin set changes.
  # Subscribe to dynamic-codegen plus canonical registration lifecycle signals
  # and coalesce bursts into one rebuild via a short debounce window.
  @signal_paths [
    "allbert.dynamic_codegen.**",
    "allbert.app.**",
    "allbert.plugin.**",
    "allbert.action.registry_changed"
  ]
  @rebuild_debounce_ms 2_000

  @enforce_keys []
  defstruct entries: [],
            status: :not_built,
            built_at: nil,
            error: nil,
            subscription_id: nil,
            rebuild_timer: nil,
            effect_guard: EffectGuard,
            effect_guard_opts: []

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

  @doc "The utterance text indexed for a descriptor, including clarification vocabulary."
  @spec utterance_text(map()) :: String.t()
  def utterance_text(descriptor) do
    vocabulary = Map.get(descriptor, :vocabulary, %{}) || %{}

    [to_string(descriptor.label)]
    |> Kernel.++(Map.get(descriptor, :examples, []))
    |> Kernel.++(Map.get(descriptor, :synonyms, []))
    |> Kernel.++(Map.get(vocabulary, :phrases, []) || Map.get(vocabulary, "phrases", []))
    |> Kernel.++(
      Map.get(vocabulary, :clarification_phrases, []) ||
        Map.get(vocabulary, "clarification_phrases", [])
    )
    |> Enum.map(&to_string/1)
    |> Enum.reject(&(&1 == ""))
    |> Enum.join(" ; ")
  end

  @doc "Signal path subscriptions that can mark the index stale."
  @spec signal_paths() :: [String.t()]
  def signal_paths, do: @signal_paths

  # ── GenServer ────────────────────────────────────────────────────────────────

  @impl true
  def init(opts) do
    state = %__MODULE__{
      effect_guard: Keyword.get(opts, :effect_guard, EffectGuard),
      effect_guard_opts: Keyword.get(opts, :effect_guard_opts, [])
    }

    {:ok, subscribe(state)}
  end

  @impl true
  def handle_call(:rebuild, _from, state) do
    case rebuild_with_epoch(state) do
      {:ok, built} -> {:reply, built, retain_runtime_state(built, state)}
      {:error, :product_not_ready} -> {:reply, unavailable_state(state), state}
    end
  end

  def handle_call(:state, _from, state), do: {:reply, state, state}

  @impl true
  # An action-set change arrived (dynamic plugin integrate/rollback/reconcile):
  # mark the index stale and debounce a rebuild so a burst coalesces into one.
  def handle_info({:signal, _signal}, state) do
    {:noreply, %{state | status: :not_built, rebuild_timer: reschedule(state.rebuild_timer)}}
  end

  def handle_info(:rebuild_debounced, state) do
    case rebuild_with_epoch(state) do
      {:ok, built} -> {:noreply, retain_runtime_state(built, state)}
      {:error, :product_not_ready} -> {:noreply, unavailable_state(state)}
    end
  end

  def handle_info(:retry_subscribe, %__MODULE__{subscription_id: nil} = state),
    do: {:noreply, subscribe(state)}

  def handle_info(_message, state), do: {:noreply, state}

  # ── reindex hooks ────────────────────────────────────────────────────────────

  defp subscribe(state) do
    if reindex_on_registration_signal?() do
      case safe_subscribe() do
        {:ok, subscription_id} ->
          %{state | subscription_id: subscription_id}

        _error ->
          # Bus may not be up yet at boot; retry without blocking init.
          Process.send_after(self(), :retry_subscribe, @rebuild_debounce_ms)
          state
      end
    else
      state
    end
  end

  defp reindex_on_registration_signal? do
    case Application.fetch_env(:allbert_assist, :intent_index_reindex_on_signal) do
      {:ok, value} when is_boolean(value) ->
        value

      _other ->
        case Settings.get("intent.reindex_on_registration_signal") do
          {:ok, value} when is_boolean(value) -> value
          _fallback -> true
        end
    end
  end

  defp safe_subscribe do
    subscriptions =
      Enum.map(@signal_paths, fn path ->
        {path, JidoSignalBus.subscribe(SignalBus, path)}
      end)

    ids =
      subscriptions
      |> Enum.flat_map(fn
        {_path, {:ok, subscription_id}} -> [subscription_id]
        {_path, _error} -> []
      end)

    if ids == [] do
      {:error, :subscribe_failed}
    else
      {:ok, ids}
    end
  rescue
    _exception -> {:error, :subscribe_failed}
  catch
    :exit, _reason -> {:error, :subscribe_exit}
  end

  defp reschedule(nil), do: Process.send_after(self(), :rebuild_debounced, @rebuild_debounce_ms)

  defp reschedule(timer) do
    Process.cancel_timer(timer)
    Process.send_after(self(), :rebuild_debounced, @rebuild_debounce_ms)
  end

  # A delayed rebuild is a provider-facing operation. It admits one epoch only
  # when the message is handled and validates that same epoch immediately before
  # embedding; a replacement readiness epoch is never substituted.
  defp rebuild_with_epoch(state) do
    with {:ok, epoch} <- state.effect_guard.admit_ready(state.effect_guard_opts),
         :ok <- state.effect_guard.validate(epoch, state.effect_guard_opts) do
      {:ok, build()}
    else
      {:error, _reason} -> {:error, :product_not_ready}
    end
  end

  defp retain_runtime_state(built, state) do
    %{
      built
      | subscription_id: state.subscription_id,
        rebuild_timer: nil,
        effect_guard: state.effect_guard,
        effect_guard_opts: state.effect_guard_opts
    }
  end

  defp unavailable_state(state) do
    %{state | status: :unavailable, error: :product_not_ready, rebuild_timer: nil}
  end

  defp build do
    # Non-default app descriptors are inert index data. Prefilter scopes them to
    # the validated active app on each request before they can reach ranking.
    descriptors = DescriptorResolver.resolve(availability: :router_index)
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
              descriptor: descriptor,
              required_slots: descriptor.required_slots,
              optional_slots: descriptor.optional_slots,
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
