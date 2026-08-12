defmodule AllbertResearch.Runtime do
  @moduledoc false

  alias AllbertAssist.Objectives.AgentRegistry
  alias Jido.AgentServer

  @agent_id "research.specialist"

  @spec agent_id() :: String.t()
  def agent_id, do: @agent_id

  def metadata do
    %{
      app_id: :allbert_research,
      type: :research_delegate,
      allowed_commands: [:research, :summarize_url],
      advisory?: true,
      authority_surface: :none
    }
  end

  @spec start_link(module(), keyword()) :: GenServer.on_start()
  def start_link(module, opts \\ []) do
    name = Keyword.get(opts, :name, module)

    with {:ok, pid} <-
           AgentServer.start_link(
             jido: AllbertAssist.Jido,
             agent: module,
             id: @agent_id,
             name: name,
             initial_state: initial_state()
           ) do
      register_if_available(name, module)
      {:ok, pid}
    end
  end

  @spec child_spec(module(), keyword()) :: Supervisor.child_spec()
  def child_spec(module, opts \\ []) do
    %{
      id: Keyword.get(opts, :child_id, module),
      start: {module, :start_link, [opts]},
      restart: :permanent,
      shutdown: 5_000,
      type: :worker
    }
  end

  @spec register_if_available(GenServer.server(), module()) :: :ok
  def register_if_available(server, module) do
    if Process.whereis(AgentRegistry) do
      AgentRegistry.unregister(@agent_id)

      case AgentRegistry.register(@agent_id, server, module, metadata()) do
        {:ok, _entry} -> :ok
        {:error, _reason} -> :ok
      end
    else
      :ok
    end
  end

  defp initial_state do
    %{
      agent_id: @agent_id,
      role: :research_specialist,
      allowed_commands: metadata().allowed_commands,
      last_command: nil,
      last_result: nil,
      last_summary: nil
    }
  end
end
