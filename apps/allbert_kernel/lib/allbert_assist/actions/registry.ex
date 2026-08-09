defmodule AllbertAssist.Actions.Registry do
  @moduledoc """
  Public action-resolution facade over the finalized authoritative Pack.

  Dynamic-plugin actions remain a final overlay because their confirmed loader
  lifecycle is outside static Pack composition. App and Plugin metadata do not
  independently grant action authority after Pack finalization.
  """

  alias AllbertAssist.Action
  alias AllbertAssist.Actions.{Capability, SnapshotCatalog}
  alias AllbertAssist.Kernel.Contract.ActionsOverlay
  alias AllbertAssist.Kernel.Contract.Membership
  alias AllbertAssist.Kernel.Contract.Signals
  alias AllbertAssist.Pack.Registry, as: PackRegistry
  alias AllbertAssist.RegistryContext

  @doc "Return registered runtime action modules in stable display order."
  @spec modules(keyword()) :: [module()]
  def modules(opts \\ []),
    do: SnapshotCatalog.modules(pack_snapshot(opts)) ++ dynamic_actions(opts)

  @doc "Return action modules that can be exposed to the intent agent."
  @spec agent_modules(keyword()) :: [module()]
  def agent_modules(opts \\ []) do
    SnapshotCatalog.agent_modules(pack_snapshot(opts)) ++
      ActionsOverlay.agent_modules(opts)
  end

  @doc "Return registered action names in stable display order."
  @spec names(keyword()) :: [String.t()]
  def names(opts \\ []), do: Enum.map(modules(opts), & &1.name())

  @doc "Return canonical capability metadata for all registered actions."
  @spec capabilities(keyword()) :: [Capability.t()]
  def capabilities(opts \\ []) do
    SnapshotCatalog.capabilities(pack_snapshot(opts)) ++ dynamic_capabilities(opts)
  end

  @doc "Return canonical capability metadata for intent-agent actions."
  @spec agent_capabilities(keyword()) :: [Capability.t()]
  def agent_capabilities(opts \\ []) do
    snapshot = pack_snapshot(opts)
    overlay_agent_modules = ActionsOverlay.agent_modules(opts)

    SnapshotCatalog.agent_capabilities(snapshot) ++
      Enum.map(overlay_agent_modules, &capability_for_module!(&1, opts))
  end

  @doc "Return canonical capability metadata for internal-only actions."
  @spec internal_capabilities(keyword()) :: [Capability.t()]
  def internal_capabilities(opts \\ []) do
    overlay_agent_modules = ActionsOverlay.agent_modules(opts)

    dynamic_internal =
      opts
      |> dynamic_actions()
      |> Enum.reject(&(&1 in overlay_agent_modules))
      |> Enum.map(&capability_for_module!(&1, opts))

    SnapshotCatalog.internal_capabilities(pack_snapshot(opts)) ++ dynamic_internal
  end

  @doc "Return action capabilities contributed by one registered app."
  @spec capabilities_for_app(atom(), keyword()) :: [Capability.t()]
  def capabilities_for_app(app_id, opts \\ [])

  def capabilities_for_app(app_id, opts) when is_atom(app_id) do
    SnapshotCatalog.capabilities_for_app(pack_snapshot(opts), app_id) ++
      (app_id
       |> ActionsOverlay.actions_for_app(opts)
       |> Enum.map(&capability_for_module!(&1, opts)))
  end

  def capabilities_for_app(_app_id, _opts), do: []

  @doc "Resolve a registered action by module, string name, or atom name."
  @spec resolve(module() | String.t() | atom(), keyword()) ::
          {:ok, module()} | {:error, {:unknown_action, term()}}
  def resolve(action, opts \\ []) do
    case SnapshotCatalog.resolve(pack_snapshot(opts), action) do
      {:ok, module} -> {:ok, module}
      {:error, _reason} -> resolve_dynamic(action, opts)
    end
  end

  @doc "Resolve canonical capability metadata by registered action name or module."
  @spec capability(module() | String.t() | atom(), keyword()) ::
          {:ok, Capability.t()} | {:error, {:unknown_action, term()}}
  def capability(action, opts \\ []) do
    case SnapshotCatalog.capability(pack_snapshot(opts), action) do
      {:ok, capability} ->
        {:ok, capability}

      {:error, _reason} ->
        with {:ok, module} <- resolve_dynamic(action, opts) do
          {:ok, capability_for_module!(module, opts)}
        end
    end
  end

  @doc "Return true when a registered action may be resumed from a durable confirmation."
  @spec resumable?(module() | String.t() | atom(), keyword()) :: boolean()
  def resumable?(action, opts \\ []) do
    case capability(action, opts) do
      {:ok, capability} -> capability.resumable?
      {:error, _reason} -> false
    end
  end

  @doc "Return true when the module is registered for runtime invocation."
  @spec registered_module?(module(), keyword()) :: boolean()
  def registered_module?(module, opts \\ []), do: module in modules(opts)

  @doc "Return duplicate registered names. This should always be empty."
  @spec duplicate_names(keyword()) :: [String.t()]
  def duplicate_names(opts \\ []) do
    opts
    |> names()
    |> Enum.frequencies()
    |> Enum.filter(fn {_name, count} -> count > 1 end)
    |> Enum.map(&elem(&1, 0))
  end

  @doc "Return action-registry diagnostics from the confirmed dynamic overlay."
  @spec diagnostics(keyword()) :: [map()]
  def diagnostics(opts \\ []),
    do: ActionsOverlay.diagnostics(opts)

  @doc "Emit an advisory action-registry-changed signal for index subscribers."
  @spec emit_registry_changed(atom(), map()) :: :ok
  def emit_registry_changed(reason, metadata \\ %{}) when is_atom(reason) and is_map(metadata) do
    metadata =
      metadata
      |> Map.put(:reason, reason)
      |> Map.put(:registered_action_count, length(names()))
      |> Map.put(:agent_action_count, length(agent_modules()))

    Signals.emit_registration(:action_registry_changed, metadata)
  end

  defp pack_snapshot(opts) do
    case PackRegistry.snapshot(RegistryContext.pack_opts(opts)) do
      {:ok, snapshot} -> snapshot
      {:error, _reason} -> nil
    end
  end

  defp dynamic_actions(opts), do: ActionsOverlay.modules(opts)

  defp dynamic_capabilities(opts),
    do: Enum.map(dynamic_actions(opts), &capability_for_module!(&1, opts))

  defp resolve_dynamic(action, opts) do
    modules = dynamic_actions(opts)

    cond do
      is_atom(action) and action in modules ->
        {:ok, action}

      is_atom(action) ->
        action
        |> Atom.to_string()
        |> String.replace_prefix("Elixir.", "")
        |> resolve_dynamic_name(action, modules)

      is_binary(action) ->
        resolve_dynamic_name(action, action, modules)

      true ->
        {:error, {:unknown_action, action}}
    end
  end

  defp resolve_dynamic_name(name, original, modules) do
    normalized = normalize_name(name)

    case Enum.find(modules, &(normalize_name(&1.name()) == normalized)) do
      nil -> {:error, {:unknown_action, original}}
      module -> {:ok, module}
    end
  end

  defp capability_for_module!(module, opts) do
    attrs = capability_attrs!(module)
    app_id = Membership.app_id_for_action(module, RegistryContext.app_opts(opts))
    plugin_id = Membership.plugin_id_for_action(module, RegistryContext.plugin_opts(opts))

    module
    |> Capability.new(attrs)
    |> maybe_put(:app_id, app_id)
    |> maybe_put(:plugin_id, plugin_id)
  end

  defp capability_attrs!(module) do
    with true <- Code.ensure_loaded?(module),
         true <- function_exported?(module, :capability, 0),
         {:ok, attrs} <- module |> apply(:capability, []) |> Action.validate_capability() do
      attrs
    else
      reason -> raise KeyError, key: module, term: reason
    end
  end

  defp maybe_put(value, _field, nil), do: value
  defp maybe_put(value, field, owner), do: Map.put(value, field, owner)

  defp normalize_name(name) do
    binary = to_string(name)

    case normalize_ascii(binary, <<>>, false) do
      :non_ascii ->
        binary
        |> String.downcase()
        |> String.replace(~r/[^a-z0-9]+/, "_")
        |> String.trim("_")

      normalized ->
        normalized
    end
  end

  defp normalize_ascii(<<char, rest::binary>>, acc, pending?) when char < 0x80 do
    char = if char >= ?A and char <= ?Z, do: char + 32, else: char

    if (char >= ?a and char <= ?z) or (char >= ?0 and char <= ?9) do
      acc = if pending?, do: <<acc::binary, ?_>>, else: acc
      normalize_ascii(rest, <<acc::binary, char>>, false)
    else
      normalize_ascii(rest, acc, acc != <<>>)
    end
  end

  defp normalize_ascii(<<>>, acc, _pending?), do: acc
  defp normalize_ascii(_binary, _acc, _pending?), do: :non_ascii
end
