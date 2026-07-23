defmodule AllbertAssist.Channels.Signal.Supervisor do
  @moduledoc """
  Supervises the Signal adapter and its owned signal-cli daemon.

  MuonTrap owns daemon process lifetime; JSON notification lines are forwarded
  to the adapter, which remains the only inbound runtime boundary.
  """

  use Supervisor

  alias AllbertAssist.Channels
  alias AllbertAssist.Channels.Signal.Adapter
  alias AllbertAssist.Channels.Signal.Daemon

  def start_link(opts) do
    Supervisor.start_link(__MODULE__, opts, name: Keyword.get(opts, :name, __MODULE__))
  end

  @impl true
  def init(opts) do
    settings =
      case Channels.channel_settings("signal") do
        {:ok, settings} -> settings
        _other -> %{}
      end

    adapter_name = Keyword.get(opts, :adapter_name, Adapter)
    adapter = {Adapter, Keyword.put(opts, :name, adapter_name)}

    children =
      if daemon_enabled?(settings) do
        [adapter, Daemon.daemon_child_spec(settings, logger_fun: logger_fun(adapter_name))]
      else
        [adapter]
      end

    Supervisor.init(children, strategy: :rest_for_one)
  end

  defp daemon_enabled?(settings) do
    Map.get(settings, "enabled", false) and
      Map.get(settings, "control_mode", "socket") != "stub" and
      Map.get(settings, "daemon_start", "on-start") == "on-start"
  end

  defp logger_fun(adapter) do
    fn line ->
      case Jason.decode(String.trim(line)) do
        {:ok, notification} -> Adapter.daemon_notification(adapter, notification)
        {:error, _reason} -> :ok
      end
    end
  end
end
