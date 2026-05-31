defmodule AllbertBrowser.Supervisor do
  @moduledoc """
  Plugin-owned browser supervision tree.

  The browser plugin uses plain OTP supervisors and GenServers because M2 owns
  local process/session state; Jido adds no useful lifecycle semantics here.
  """

  use Supervisor

  def start_link(opts \\ []), do: Supervisor.start_link(__MODULE__, opts, name: __MODULE__)

  @impl true
  def init(_opts) do
    children = [
      {Registry, keys: :unique, name: AllbertBrowser.Session.Registry},
      {DynamicSupervisor, strategy: :one_for_one, name: AllbertBrowser.SessionSupervisor}
    ]

    Supervisor.init(children, strategy: :one_for_one)
  end
end
