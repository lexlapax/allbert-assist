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
  and performs no network I/O — the guided-install egress is M4's, always behind
  explicit consent.

  Onboarding state lives in a Home-directory marker file
  (`<Allbert Home>/onboarding.json`) — additive, outside the Settings Central
  schema, so it is not a new Settings key (Locked Decision 6 / plan Settings
  section).
  """

  require Logger

  alias AllbertAssist.FirstModel.Ollama
  alias AllbertAssist.Paths

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

  @doc "Resolve the current first-run product state (read-only, no network)."
  @spec detect() :: state()
  def detect do
    cond do
      not home_initialized?() -> :home_missing
      not schema_compatible?() -> :schema_incompatible
      not onboarding_complete?() -> :onboarding_incomplete
      first_model_state() not in [:local_ready, :byok_ready] -> :first_model_not_ready
      not profile_reviewed?() -> :profile_unreviewed
      true -> :product_ready
    end
  end

  @doc """
  Resolve the first-model state. `deps` lets M4 / tests inject the Ollama probe
  and hardware check; the default is a conservative read that never touches the
  network — an unprobed environment resolves to `:byok_ready` when a provider
  key is present, else `:runtime_missing`.
  """
  @spec first_model_state(keyword()) :: model_state()
  def first_model_state(deps \\ []) do
    ollama = Keyword.get(deps, :ollama_probe, &default_ollama_probe/0)
    floor_ok = Keyword.get(deps, :hardware_ok?, fn -> true end)
    byok? = Keyword.get(deps, :byok_ready?, &byok_ready?/0)

    case ollama.() do
      :model_ready -> :local_ready
      :model_missing -> if floor_ok.(), do: :model_missing, else: :below_hardware_floor
      :unhealthy -> :runtime_unhealthy
      :missing -> if byok?.(), do: :byok_ready, else: :runtime_missing
    end
  end

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
