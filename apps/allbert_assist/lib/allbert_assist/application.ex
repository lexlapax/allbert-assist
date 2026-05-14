defmodule AllbertAssist.Application do
  # See https://hexdocs.pm/elixir/Application.html
  # for more information on OTP Applications
  @moduledoc false

  use Application

  @impl true
  def start(_type, _args) do
    children =
      [
        AllbertAssist.Repo,
        {Ecto.Migrator,
         repos: Application.fetch_env!(:allbert_assist, :ecto_repos), skip: skip_migrations?()},
        {DNSCluster, query: Application.get_env(:allbert_assist, :dns_cluster_query) || :ignore},
        {Phoenix.PubSub, name: AllbertAssist.PubSub},
        {Jido.Signal.Bus, name: AllbertAssist.SignalBus},
        AllbertAssist.Jido
      ]
      |> maybe_add_scheduler()

    Supervisor.start_link(children, strategy: :one_for_one, name: AllbertAssist.Supervisor)
  end

  defp maybe_add_scheduler(children) do
    opts = Application.get_env(:allbert_assist, AllbertAssist.Jobs.Scheduler, [])

    if Keyword.get(opts, :enabled?, true) do
      children ++ [{AllbertAssist.Jobs.Scheduler, opts}]
    else
      children
    end
  end

  defp skip_migrations?() do
    # By default, sqlite migrations are run when using a release
    System.get_env("RELEASE_NAME") == nil
  end
end
