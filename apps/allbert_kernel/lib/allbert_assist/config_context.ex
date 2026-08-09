defmodule AllbertAssist.ConfigContext do
  @moduledoc false

  # v1.0.3 M1 (ADR 0086 contract 2): ONE internal process-scoped
  # configuration context with the fixed shape
  #
  #     config_context: [home: path, settings_root: path, app: keyword]
  #
  # `home` and `settings_root` override ONLY their corresponding
  # `AllbertAssist.Paths` reads (`Paths.home/0`, `Paths.settings_root/0`);
  # `app` carries the allowlisted module/key configuration a converted test
  # path needs — never arbitrary application state. The context is installed
  # process-locally for the duration of ONE bounded `with_context/2` call and
  # must be handed to Tasks, LiveViews, agents, and supervised children
  # EXPLICITLY (`current/0` at spawn, `with_context/2` in the child) — it is
  # deliberately not inherited, so a process that was not given a context
  # keeps reading the global defaults.
  #
  # Production omission preserves current defaults byte-for-byte: no
  # production call site installs a context, `home/0`/`settings_root/0`
  # return nil when none is installed, and every `Paths` precedence chain is
  # unchanged from its pre-context form in that case.
  #
  # This is DISTINCT from the two existing seams (ADR 0086 contract 2):
  # `Settings.Store.with_resolved_settings/1` pins a validated READ snapshot
  # and `AllbertAssist.RegistryContext` selects registries — neither
  # substitutes for app-env writes. The context grants nothing: Settings
  # Central validation, Security Central authority, and schema checks run
  # identically inside a context.

  @context_key {__MODULE__, :context}
  @allowed_keys [:home, :settings_root, :app]

  @typedoc "The internal configuration-context shape (ADR 0086 contract 2)."
  @type t :: [home: Path.t(), settings_root: Path.t(), app: keyword()]

  @doc """
  Run `fun` with `context` installed process-locally, restoring any
  previously-installed context afterwards (bounded, reentrant-safe).
  """
  @spec with_context(t(), (-> result)) :: result when result: term()
  def with_context(context, fun) when is_list(context) and is_function(fun, 0) do
    validate!(context)
    previous = Process.put(@context_key, context)

    try do
      fun.()
    after
      restore(previous)
    end
  end

  @doc "The context installed in the calling process, or `[]` when none."
  @spec current() :: t()
  def current, do: Process.get(@context_key) || []

  @doc "The context `:home` override for `Paths.home/0`, or nil."
  @spec home() :: Path.t() | nil
  def home, do: current()[:home]

  @doc "The context `:settings_root` override for `Paths.settings_root/0`, or nil."
  @spec settings_root() :: Path.t() | nil
  def settings_root, do: current()[:settings_root]

  @doc """
  The context `:app` override for `{app, key}`, or `default`. Converted
  paths consult this INSTEAD of `Application.get_env(app, key, default)`
  when a context is installed; with no context (production) the caller's
  `Application` read runs unchanged.
  """
  @spec app_env(atom(), term(), term()) :: term()
  def app_env(app, key, default \\ nil) when is_atom(app) do
    case current()[:app] do
      nil -> default
      overrides -> overrides |> Keyword.get(app, []) |> keyword_get(key, default)
    end
  end

  defp keyword_get(entries, key, default) when is_list(entries) do
    case List.keyfind(entries, key, 0) do
      {^key, value} -> value
      nil -> default
    end
  end

  defp restore(nil), do: Process.delete(@context_key)
  defp restore(previous), do: Process.put(@context_key, previous)

  defp validate!(context) do
    case Keyword.keys(context) -- @allowed_keys do
      [] ->
        :ok

      unknown ->
        raise ArgumentError,
              "unknown config_context key(s) #{inspect(unknown)}; " <>
                "the ADR 0086 contract-2 shape is [home:, settings_root:, app:]"
    end
  end
end
