defmodule AllbertAssist.Mcp do
  @moduledoc """
  Runtime facade for MCP client operations.

  v0.40 M2 uses bounded per-action client sessions. The facade keeps callers on
  the registered MCP boundary instead of reaching into transport modules.
  """

  alias AllbertAssist.Mcp.Client
  alias AllbertAssist.Mcp.Doctor
  alias AllbertAssist.Mcp.ServerConfig

  @spec resolve_server(String.t()) :: {:ok, ServerConfig.t()} | {:error, term()}
  defdelegate resolve_server(server_id), to: ServerConfig, as: :resolve

  @spec doctor(String.t(), map(), keyword()) :: {:ok, map()} | {:error, term()}
  defdelegate doctor(server_id, context \\ %{}, opts \\ []), to: Doctor, as: :diagnose

  @spec list_tools(String.t(), map(), keyword()) :: {:ok, map()} | {:error, term()}
  def list_tools(server_id, context \\ %{}, opts \\ []) do
    with {:ok, config} <- ServerConfig.resolve(server_id) do
      Client.list_tools(config, context, opts)
    end
  end

  @spec list_resources(String.t(), map(), keyword()) :: {:ok, map()} | {:error, term()}
  def list_resources(server_id, context \\ %{}, opts \\ []) do
    with {:ok, config} <- ServerConfig.resolve(server_id) do
      Client.list_resources(config, context, opts)
    end
  end

  @spec read_resource(String.t(), String.t(), map()) :: {:ok, map()} | {:error, term()}
  def read_resource(server_id, uri, context \\ %{}) do
    with {:ok, config} <- ServerConfig.resolve(server_id) do
      Client.read_resource(config, uri, context)
    end
  end
end
