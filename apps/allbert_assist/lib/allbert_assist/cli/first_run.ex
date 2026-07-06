defmodule AllbertAssist.CLI.FirstRun do
  @moduledoc """
  First-run detection and first-model-state resolution for the bare-`allbert`
  dispatcher (v0.62 M3, owning the `docs/design/entry-point-cli-ux.md` state
  machine — Locked Decision 6; v0.63 owns the wizard *semantics* this hooks
  into).

  `detect/0` returns one of the six product states (the design's first-run
  detection table); `first_model_state/1` returns one of the seven model states
  the entry points consume. Detection is **read-only** and performs no network
  I/O — the guided-install egress is M4's, always behind explicit consent.

  Onboarding state lives in a Home-directory marker file
  (`<Allbert Home>/onboarding.json`) — additive, outside the Settings Central
  schema, so it is not a new Settings key (Locked Decision 6 / plan Settings
  section).
  """

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
          | :blocked

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
  @spec onboarding_summary() :: {:ok, map()}
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

  @doc "Mark onboarding complete (Home marker; not a Settings key)."
  @spec mark_onboarding_complete() :: :ok
  def mark_onboarding_complete do
    write_marker(%{"onboarding_complete" => true, "profile_reviewed" => true})
  end

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

  # Default Ollama probe is intentionally conservative and network-free: M4
  # replaces it with the three-way live probe. Absent that, report `:missing`
  # so first-run degrades to BYOK rather than assuming a local model. The spec
  # advertises the full probe union so callers keep every model-state branch.
  @spec default_ollama_probe() :: :model_ready | :model_missing | :unhealthy | :missing
  defp default_ollama_probe, do: :missing

  # -- Home marker -----------------------------------------------------------

  defp marker do
    path = Path.join(Paths.home(), @onboarding_file)

    with {:ok, body} <- File.read(path),
         {:ok, map} <- Jason.decode(body) do
      map
    else
      _absent -> %{}
    end
  end

  defp write_marker(attrs) do
    home = Paths.home()
    File.mkdir_p!(home)
    merged = Map.merge(marker(), attrs)
    File.write!(Path.join(home, @onboarding_file), Jason.encode!(merged))
    :ok
  end
end
