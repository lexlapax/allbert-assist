defmodule StockSage.Agents.Runtime do
  @moduledoc false

  alias AllbertAssist.Objectives.AgentRegistry
  alias Jido.AgentServer
  alias StockSage.Agents

  @spec start_link(module(), String.t(), keyword()) :: GenServer.on_start()
  def start_link(module, agent_id, opts \\ []) do
    name = Keyword.get(opts, :name, module)
    spec = Agents.spec!(agent_id)

    with {:ok, pid} <-
           AgentServer.start_link(
             jido: AllbertAssist.Jido,
             agent: module,
             id: agent_id,
             name: name,
             initial_state: initial_state(spec)
           ) do
      register_if_available(agent_id, name, module, spec)
      {:ok, pid}
    end
  end

  @spec child_spec(module(), String.t(), keyword()) :: Supervisor.child_spec()
  def child_spec(module, _agent_id, opts \\ []) do
    %{
      id: Keyword.get(opts, :child_id, module),
      start: {module, :start_link, [opts]},
      restart: :permanent,
      shutdown: 5_000,
      type: :worker
    }
  end

  defp initial_state(spec) do
    %{
      agent_id: spec.id,
      role: spec.role,
      prompt_version: spec.prompt_version,
      prompt_path: Agents.prompt_path(spec),
      model_profile: model_profile(spec),
      tool_names: spec.tool_names,
      last_command: nil,
      last_result: nil
    }
  end

  defp model_profile(%{role: :quality_gate}), do: nil
  defp model_profile(spec), do: StockSage.Agents.ModelProfile.resolve(spec.role)

  defp register_if_available(agent_id, server, module, spec) do
    if Process.whereis(AgentRegistry) do
      AgentRegistry.unregister(agent_id)

      metadata =
        spec
        |> Map.take([:role, :prompt_file, :prompt_version, :type, :tool_modules, :tool_names])
        |> Map.put(:app_id, :stocksage)
        |> Map.put(:prompt_path, Agents.prompt_path(spec))
        |> Map.put(:model_profile, model_profile(spec))

      case AgentRegistry.register(agent_id, server, module, metadata) do
        {:ok, _entry} -> :ok
        {:error, _reason} -> :ok
      end
    else
      :ok
    end
  end
end
