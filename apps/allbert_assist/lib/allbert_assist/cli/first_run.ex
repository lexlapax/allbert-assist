defmodule AllbertAssist.CLI.FirstRun do
  @moduledoc """
  First-run detection and first-model-state resolution for the bare-`allbert`
  dispatcher (v0.62 M3, owning the `docs/design/entry-point-cli-ux.md` state
  machine — Locked Decision 6; v0.63 owns the wizard *semantics* this hooks
  into).

  `detect/0` returns one of the six product states (the design's first-run
  detection table); `first_model_state/1` returns one of the **six** model-probe
  states the entry points consume (there is no synthetic `blocked` state — operator
  readiness labels `Needs credentials`/`Needs review` come from the provider/product
  layer, per the plan's Readiness Label Mapping Contract). Detection is **read-only**
  (it never writes) but is NOT network-free: `first_model_state/0` first probes the
  configured local provider through Model Doctor, then falls back to host-local
  Ollama discovery. This lets WSL2 use a Windows-host runtime without bundling or
  installing Ollama in the Linux artifact. Guided-install egress remains M4's and
  always requires explicit consent. The packaged `eval` entry starts `:req` first
  because both probes need its HTTP pool (M8.1).

  Onboarding state lives in a Home-directory marker file
  (`<Allbert Home>/onboarding.json`) — additive, outside the Settings Central
  schema, so it is not a new Settings key (Locked Decision 6 / plan Settings
  section).
  """

  require Logger

  alias AllbertAssist.FirstModel.Ollama
  alias AllbertAssist.Paths
  alias AllbertAssist.Settings
  alias AllbertAssist.Settings.ModelDoctor

  @onboarding_file "onboarding.json"

  @type state ::
          :home_missing
          | :schema_incompatible
          | :onboarding_incomplete
          | :first_model_not_ready
          | :profile_unreviewed
          | :product_ready

  @type model_state ::
          :local_ready
          | :runtime_missing
          | :runtime_unhealthy
          | :model_missing
          | :below_hardware_floor
          | :byok_ready

  @doc """
  Resolve the current first-run product state.

  v0.63 M7.9: callers that already hold a resolved first-model probe (e.g. a wizard
  render that cached it) pass `first_model_state:` so `detect/1` reuses it instead of
  probing localhost Ollama again. The model-state branch is still evaluated *lazily*
  (only reached once onboarding is complete), so `detect/0` during onboarding never
  probes — and post-completion renders that inject the cached probe never do either.
  """
  @spec detect(keyword()) :: state()
  def detect(opts \\ []) do
    detect_details(opts).state
  end

  @doc """
  Resolve first-run state plus the model probe when the state machine reaches the
  post-onboarding model branch. This keeps probing lazy but lets callers render repair
  copy without re-probing.
  """
  @spec detect_details(keyword()) :: %{state: state(), first_model_state: model_state() | nil}
  def detect_details(opts \\ []) do
    cond do
      not home_initialized?() ->
        details(:home_missing)

      not schema_compatible?() ->
        details(:schema_incompatible)

      not onboarding_complete?() ->
        details(:onboarding_incomplete)

      true ->
        model_state = resolved_model_state(opts)

        cond do
          model_state not in [:local_ready, :byok_ready] ->
            details(:first_model_not_ready, model_state)

          not profile_reviewed?() ->
            details(:profile_unreviewed, model_state)

          true ->
            details(:product_ready, model_state)
        end
    end
  end

  # Reuse an injected probe when present; otherwise fall back to the live probe — but
  # only when the cond actually reaches this branch (post-completion), preserving the
  # no-probe-during-onboarding short-circuit.
  defp resolved_model_state(opts) do
    Keyword.get_lazy(opts, :first_model_state, fn ->
      case Application.get_env(:allbert_assist, :first_model_state_override) do
        state
        when state in [
               :local_ready,
               :runtime_missing,
               :runtime_unhealthy,
               :model_missing,
               :below_hardware_floor,
               :byok_ready
             ] ->
          state

        _other ->
          first_model_state()
      end
    end)
  end

  @doc """
  Resolve the first-model state. `deps` lets M4 / tests inject the Ollama probe
  and hardware check; the default is a conservative read that never touches the
  network — an unprobed environment resolves to `:byok_ready` when a provider
  key is present, else `:runtime_missing`.
  """
  @spec first_model_state(keyword()) :: model_state()
  def first_model_state(deps \\ []) do
    floor_ok = Keyword.get(deps, :hardware_ok?, fn -> true end)
    byok? = Keyword.get(deps, :byok_ready?, &byok_ready?/0)
    classify_model_probe(resolve_model_probe(deps), floor_ok, byok?)
  end

  defp resolve_model_probe(deps) do
    ollama = Keyword.get(deps, :ollama_probe, &default_ollama_probe/0)
    configured = Keyword.get(deps, :configured_local_probe, configured_probe(deps))

    case configured.() do
      :not_configured -> ollama.()
      result -> result
    end
  end

  defp configured_probe(deps) do
    if Keyword.has_key?(deps, :ollama_probe),
      do: fn -> :not_configured end,
      else: &configured_local_probe/0
  end

  defp classify_model_probe(probe, floor_ok, byok?) do
    case probe do
      :model_ready -> :local_ready
      :model_missing -> if floor_ok.(), do: :model_missing, else: :below_hardware_floor
      :unhealthy -> :runtime_unhealthy
      :missing -> if byok?.(), do: :byok_ready, else: :runtime_missing
    end
  end

  defp details(state, model_state \\ nil), do: %{state: state, first_model_state: model_state}

  @doc "A short onboarding summary map (backing `allbert admin onboarding`)."
  def onboarding_summary do
    {:ok,
     %{
       state: detect(),
       first_model_state: first_model_state(),
       home: Paths.home(),
       home_initialized: home_initialized?(),
       onboarding_complete: onboarding_complete?()
     }}
  end

  @doc """
  Mark onboarding complete (Home marker; not a Settings key). v0.63 M1: this no
  longer forces `profile_reviewed` — profile review is now a real, separate state
  written by the wizard's `profile_review` step (see `mark_profile_reviewed/0`).
  """
  @spec mark_onboarding_complete() :: :ok
  def mark_onboarding_complete do
    merge_marker(%{"onboarding_complete" => true})
  end

  @doc "Mark the persona/profile review step done (real state, v0.63 M1)."
  @spec mark_profile_reviewed() :: :ok
  def mark_profile_reviewed do
    merge_marker(%{"profile_reviewed" => true})
  end

  @doc """
  Reset onboarding state by removing the Home marker (v0.63 M1 `--reset` seam).
  Clears `onboarding_complete`, `profile_reviewed`, and any wizard progress; it
  preserves all other Home data (db, secrets, settings, traces, memory, caches).
  """
  @spec reset_onboarding() :: :ok
  def reset_onboarding do
    _ = File.rm(Path.join(Paths.home(), @onboarding_file))
    :ok
  end

  @doc "Read the raw onboarding marker map (v0.63 M1; the single source of truth)."
  @spec read_marker() :: map()
  def read_marker, do: marker()

  @doc "Merge keys into the onboarding marker (v0.63 M1)."
  @spec merge_marker(map()) :: :ok
  def merge_marker(attrs) when is_map(attrs), do: write_marker(attrs)

  # -- state predicates ------------------------------------------------------

  defp home_initialized? do
    home = Paths.home()
    File.dir?(home) and File.exists?(Path.join([home, "db", "allbert.sqlite3"]))
  end

  # The v0.59 settings/version contract blocks boot on incompatibility;
  # reaching this code means the app booted, so the schema is compatible. A
  # dedicated pre-boot check belongs to the version-contract module — the spec
  # keeps the `detect/0` branch live for when that lands.
  @spec schema_compatible?() :: boolean()
  defp schema_compatible? do
    Application.get_env(:allbert_assist, :schema_incompatible, false) == false
  end

  defp onboarding_complete? do
    marker()["onboarding_complete"] == true
  end

  defp profile_reviewed? do
    marker()["profile_reviewed"] == true
  end

  defp byok_ready? do
    Enum.any?(
      ~w(ANTHROPIC_API_KEY OPENAI_API_KEY OPENROUTER_API_KEY GOOGLE_API_KEY GEMINI_API_KEY),
      &(System.get_env(&1) not in [nil, ""])
    )
  end

  # v0.62 M4: the default probe is the live three-way Ollama check (binary /
  # localhost server / curated model). Localhost-only — no external egress in
  # detection; the guided install and pull are separate confirmation-gated
  # actions. The spec keeps every model-state branch reachable for callers.
  @spec default_ollama_probe() :: :model_ready | :model_missing | :unhealthy | :missing
  defp default_ollama_probe do
    Ollama.probe()
  end

  # v1.0.5 M8.4: a configured, reachable local endpoint is local runtime.
  # Reuse ModelDoctor's bounded/read-only provider probe so WSL2 can use a
  # Windows-host Ollama without pretending an Ollama binary exists in Linux.
  defp configured_local_probe do
    with {:ok, profile} <- Settings.get("model_preferences.primary"),
         {:ok, summary} <- ModelDoctor.diagnose(profile),
         :local_endpoint <- summary.endpoint_kind do
      cond do
        summary.endpoint_ok and summary.model_available == true -> :model_ready
        summary.endpoint_ok and summary.model_available == false -> :model_missing
        true -> :unhealthy
      end
    else
      _other -> :not_configured
    end
  end

  # -- Home marker -----------------------------------------------------------

  defp marker do
    path = Path.join(Paths.home(), @onboarding_file)

    case File.read(path) do
      {:ok, body} -> decode_marker(body, path)
      {:error, :enoent} -> %{}
      {:error, _reason} -> %{}
    end
  end

  # v0.63 M7.1: a present-but-corrupt marker (e.g. truncated by a crash mid-write) must
  # not be silently read as "no onboarding" — surface it so a real state is not lost.
  defp decode_marker(body, path) do
    case Jason.decode(body) do
      {:ok, map} when is_map(map) ->
        map

      _error ->
        Logger.warning(
          "onboarding marker at #{path} is present but unreadable; treating as empty this read"
        )

        %{}
    end
  end

  # v0.63 M7.1: write atomically (temp + rename) so a crash mid-write can't leave a
  # truncated marker.
  defp write_marker(attrs) do
    home = Paths.home()
    File.mkdir_p!(home)
    path = Path.join(home, @onboarding_file)
    tmp = path <> ".tmp"
    merged = Map.merge(marker(), attrs)
    File.write!(tmp, Jason.encode!(merged))
    :ok = File.rename(tmp, path)
    :ok
  end
end
