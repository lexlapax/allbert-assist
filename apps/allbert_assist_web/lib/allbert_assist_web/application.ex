defmodule AllbertAssistWeb.Application do
  # See https://hexdocs.pm/elixir/Application.html
  # for more information on OTP Applications
  @moduledoc false

  use Application

  @impl true
  def start(_type, _args) do
    children = [
      AllbertAssistWeb.Telemetry,
      {Phoenix.PubSub, name: AllbertAssistWeb.PubSub},
      AllbertAssistWeb.SignalBridge,
      # Start a worker by calling: AllbertAssistWeb.Worker.start_link(arg)
      # {AllbertAssistWeb.Worker, arg},
      # Start to serve requests, typically the last entry
      AllbertAssistWeb.Endpoint
    ]

    # See https://hexdocs.pm/elixir/Supervisor.html
    # for other strategies and supported options
    opts = [strategy: :one_for_one, name: AllbertAssistWeb.Supervisor]
    Supervisor.start_link(children, opts)
  end

  # Tell Phoenix to update the endpoint configuration
  # whenever the application is updated.
  @impl true
  def config_change(changed, _new, removed) do
    AllbertAssistWeb.Endpoint.config_change(changed, removed)
    :ok
  end
end
