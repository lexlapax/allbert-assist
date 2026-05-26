defmodule AllbertAssist.DynamicPlugins.Delegate do
  @moduledoc """
  Reviewed delegation shim for generated dynamic actions.

  Generated action source may not call effectful Allbert subsystems directly.
  This module is the narrow runtime bridge allowed by the trusted validator: it
  resolves a small, operator-enabled set of reviewed facade actions and invokes
  them through the normal action runner so their existing Security Central
  behavior remains authoritative.
  """

  alias AllbertAssist.Actions.Registry
  alias AllbertAssist.Actions.Runner
  alias AllbertAssist.Settings

  @facade_permissions %{
    "append_memory" => :memory_write,
    "external_network_request" => :external_network
  }

  @hard_facades Map.keys(@facade_permissions) |> Enum.sort()

  @doc "Return the shipped hard ceiling for generated facade delegation."
  @spec hard_facades() :: [String.t()]
  def hard_facades, do: @hard_facades

  @doc "Return the reviewed permission carried by an approved delegation facade."
  @spec facade_permission(String.t()) :: {:ok, atom()} | {:error, term()}
  def facade_permission(facade_name) when is_binary(facade_name) do
    case Map.fetch(@facade_permissions, facade_name) do
      {:ok, permission} -> {:ok, permission}
      :error -> {:error, {:dynamic_delegate_facade_not_supported, facade_name}}
    end
  end

  def facade_permission(facade_name),
    do: {:error, {:dynamic_delegate_facade_not_supported, facade_name}}

  @doc """
  Run an operator-enabled reviewed facade through the canonical action runner.

  The function returns the facade runner result on success. Unknown,
  non-allowlisted, disabled, or permission-mismatched facades fail closed with
  `{:error, reason}`.
  """
  @spec run(String.t(), map(), map()) :: {:ok, map()} | {:error, term()}
  def run(facade_name, params, context)
      when is_binary(facade_name) and is_map(params) and is_map(context) do
    with {:ok, expected_permission} <- facade_permission(facade_name),
         :ok <- ensure_enabled(facade_name),
         {:ok, module} <- Registry.resolve(facade_name),
         {:ok, capability} <- Registry.capability(module),
         :ok <- ensure_facade_permission(facade_name, capability.permission, expected_permission) do
      Runner.run(facade_name, params, delegate_context(context, facade_name, module, capability))
    end
  end

  def run(facade_name, _params, _context),
    do: {:error, {:dynamic_delegate_invalid_invocation, facade_name}}

  defp ensure_enabled(facade_name) do
    case Settings.get("dynamic_codegen.allowed_facades") do
      {:ok, allowed} when is_list(allowed) ->
        if facade_name in allowed do
          :ok
        else
          {:error, {:dynamic_delegate_facade_not_enabled, facade_name}}
        end

      _other ->
        {:error, {:dynamic_delegate_facade_not_enabled, facade_name}}
    end
  end

  defp ensure_facade_permission(_facade_name, permission, permission), do: :ok

  defp ensure_facade_permission(facade_name, actual_permission, expected_permission) do
    {:error,
     {:dynamic_delegate_facade_permission_mismatch,
      %{facade: facade_name, actual: actual_permission, expected: expected_permission}}}
  end

  defp delegate_context(context, facade_name, module, capability) do
    Map.put(context, :dynamic_codegen_delegate, %{
      facade_name: facade_name,
      facade_module: module,
      facade_permission: capability.permission
    })
  end
end
