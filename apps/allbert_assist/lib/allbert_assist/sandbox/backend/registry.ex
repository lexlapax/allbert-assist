defmodule AllbertAssist.Sandbox.Backend.Registry do
  @moduledoc """
  Static v0.36 sandbox backend registry.

  The registry is a plain stateless module: backend membership is reviewed code
  compiled with Allbert, not user/plugin metadata and not runtime state. A
  GenServer or Jido.Agent would not add useful lifecycle behavior here.
  """

  alias AllbertAssist.Sandbox.Backends.AppleContainer
  alias AllbertAssist.Sandbox.Backends.Docker
  alias AllbertAssist.Sandbox.Backends.DockerRunsc
  alias AllbertAssist.Sandbox.Backends.PodmanRootless

  @backends [AppleContainer, PodmanRootless, DockerRunsc, Docker]

  @type backend_module :: AppleContainer | Docker | DockerRunsc | PodmanRootless

  @spec backends() :: [backend_module(), ...]
  def backends, do: @backends

  @spec ids() :: [atom()]
  def ids, do: Enum.map(@backends, & &1.id())

  @spec module_for(atom() | String.t()) :: {:ok, module()} | {:error, {:unknown_backend, term()}}
  def module_for(id) when is_binary(id) do
    case Enum.find(@backends, &(Atom.to_string(&1.id()) == id)) do
      nil -> {:error, {:unknown_backend, id}}
      module -> {:ok, module}
    end
  end

  def module_for(id) when is_atom(id) do
    case Enum.find(@backends, &(&1.id() == id)) do
      nil -> {:error, {:unknown_backend, id}}
      module -> {:ok, module}
    end
  end
end
