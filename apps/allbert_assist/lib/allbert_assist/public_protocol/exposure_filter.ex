defmodule AllbertAssist.PublicProtocol.ExposureFilter do
  @moduledoc """
  Deny-before-allow projection for v0.51 public protocol surfaces.

  Public MCP/OpenAI/ACP surfaces are narrower than the intent-agent action set.
  `exposure: :agent` is necessary, but settings, secret, confirmation, trace,
  registry, and local-process boundaries stay non-exposable even when a caller
  attempts to allowlist them in Settings Central.
  """

  alias AllbertAssist.Actions.Capability
  alias AllbertAssist.Actions.Registry, as: ActionsRegistry
  alias AllbertAssist.Memory.Namespaces

  @blocked_execution_modes MapSet.new([
                             :settings_read,
                             :settings_write,
                             :secret_write,
                             :confirmation_decision,
                             :confirmation_cleanup,
                             :confirmation_read,
                             :internal_trace,
                             :local_process,
                             :package_manager_process,
                             :skill_script_process,
                             :mcp_server_connect,
                             :coding_file_read,
                             :coding_file_write,
                             :coding_search,
                             :coding_shell_execute
                           ])

  @blocked_permissions MapSet.new([
                         :settings_write,
                         :settings_secret_write,
                         :settings_secret_read,
                         :confirmation_decide,
                         :command_execute,
                         :package_install,
                         :skill_script_execute,
                         :dynamic_integration,
                         :coding_file_read,
                         :coding_file_write,
                         :coding_shell_execute
                       ])

  @type filter_result ::
          {:ok, [Capability.t()]}
          | {:error, {:non_exposable_tools, [map()]}}

  @doc "Return true when a capability can be considered for public allowlisting."
  @spec exposable_tool?(Capability.t()) :: boolean()
  def exposable_tool?(%Capability{} = capability), do: non_exposable_reason(capability) == nil

  @doc "Return the deny-before-allow reason for a capability, if any."
  @spec non_exposable_reason(Capability.t()) ::
          atom() | {:blocked_execution_mode, atom()} | {:blocked_permission, atom()} | nil
  def non_exposable_reason(%Capability{exposure: exposure}) when exposure != :agent,
    do: :not_agent_exposable

  def non_exposable_reason(%Capability{execution_mode: mode, permission: permission}) do
    cond do
      MapSet.member?(@blocked_execution_modes, mode) -> {:blocked_execution_mode, mode}
      MapSet.member?(@blocked_permissions, permission) -> {:blocked_permission, permission}
      true -> nil
    end
  end

  @doc "Return all public-safe tool candidates before an operator allowlist is applied."
  @spec tool_candidates() :: [Capability.t()]
  def tool_candidates do
    ActionsRegistry.capabilities()
    |> Enum.filter(&exposable_tool?/1)
  end

  @doc """
  Resolve an operator allowlist to public-safe capabilities.

  Any unknown or non-exposable entry is a configuration error so a surface cannot
  silently appear enabled while dropping unsafe names.
  """
  @spec filter_tools([String.t()]) :: filter_result()
  def filter_tools(allowlist) when is_list(allowlist) do
    capabilities_by_name = Map.new(ActionsRegistry.capabilities(), &{&1.name, &1})

    allowlist
    |> Enum.reduce({[], []}, &resolve_tool(&1, &2, capabilities_by_name))
    |> case do
      {accepted, []} -> {:ok, Enum.reverse(accepted)}
      {_accepted, rejected} -> {:error, {:non_exposable_tools, Enum.reverse(rejected)}}
    end
  end

  def filter_tools(_allowlist), do: {:error, {:non_exposable_tools, [%{reason: :expected_list}]}}

  defp resolve_tool(name, {accepted, rejected}, capabilities_by_name) do
    case Map.fetch(capabilities_by_name, name) do
      {:ok, capability} -> resolve_known_tool(name, capability, accepted, rejected)
      :error -> {accepted, [%{name: name, reason: :unknown_action} | rejected]}
    end
  end

  defp resolve_known_tool(name, capability, accepted, rejected) do
    case non_exposable_reason(capability) do
      nil -> {[capability | accepted], rejected}
      reason -> {accepted, [%{name: name, reason: reason} | rejected]}
    end
  end

  @doc "Return app memory namespace candidates for public resource allowlisting."
  @spec namespace_candidates() :: [map()]
  def namespace_candidates, do: Namespaces.app_namespaces()

  @doc "Resolve an operator allowlist to app memory namespace declarations."
  @spec filter_memory_namespaces([String.t()]) ::
          {:ok, [map()]} | {:error, {:non_exposable_namespaces, [map()]}}
  def filter_memory_namespaces(allowlist) when is_list(allowlist) do
    namespaces = namespace_candidates()
    index = namespace_index(namespaces)

    allowlist
    |> Enum.reduce({[], []}, fn name, {accepted, rejected} ->
      case Map.fetch(index, name) do
        {:ok, namespace} -> {[namespace | accepted], rejected}
        :error -> {accepted, [%{name: name, reason: :unknown_app_namespace} | rejected]}
      end
    end)
    |> case do
      {accepted, []} -> {:ok, Enum.reverse(accepted)}
      {_accepted, rejected} -> {:error, {:non_exposable_namespaces, Enum.reverse(rejected)}}
    end
  end

  def filter_memory_namespaces(_allowlist),
    do: {:error, {:non_exposable_namespaces, [%{reason: :expected_list}]}}

  @doc false
  @spec namespace_identifiers(map()) :: [String.t()]
  def namespace_identifiers(%{app_id: app_id, namespace: namespace}) do
    app = Atom.to_string(app_id)
    name = Atom.to_string(namespace)
    ["#{app}.#{name}", "#{app}:#{name}", name]
  end

  def namespace_identifiers(_namespace), do: []

  defp namespace_index(namespaces) do
    Enum.reduce(namespaces, %{}, fn namespace, index ->
      namespace
      |> namespace_identifiers()
      |> Enum.reduce(index, &Map.put(&2, &1, namespace))
    end)
  end
end
