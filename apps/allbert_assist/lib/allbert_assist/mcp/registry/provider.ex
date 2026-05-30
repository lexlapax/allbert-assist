defmodule AllbertAssist.Mcp.Registry.Provider do
  @moduledoc """
  Behaviour for MCP registry backends used by tool discovery.

  Providers expose remote registry search and manifest fetch behind one port so
  official and optional keyed registries can be composed without callers knowing
  their wire format.
  """

  @type query :: String.t()
  @type opts :: map()
  @type registry_result :: map()
  @type manifest_ref :: String.t() | map()

  @callback provider_id() :: atom()
  @callback search(query(), opts()) :: {:ok, [registry_result()]} | {:error, term()}
  @callback fetch_manifest(manifest_ref(), opts()) :: {:ok, map()} | {:error, term()}
end
