defmodule AllbertAssist.Application do
  # See https://hexdocs.pm/elixir/Application.html
  # for more information on OTP Applications
  @moduledoc false

  use Application

  alias AllbertAssist.Workspace.Fragment.Guard, as: FragmentGuard
  alias AllbertAssist.Workspace.Fragment.SigningSecret

  @impl true
  def start(_type, _args) do
    maybe_bootstrap_workspace_signing_secret!()

    children =
      [
        AllbertAssist.Repo,
        {Ecto.Migrator,
         repos: Application.fetch_env!(:allbert_assist, :ecto_repos), skip: skip_migrations?()},
        {DNSCluster, query: Application.get_env(:allbert_assist, :dns_cluster_query) || :ignore},
        {Phoenix.PubSub, name: AllbertAssist.PubSub},
        {Jido.Signal.Bus, name: AllbertAssist.SignalBus},
        AllbertAssist.Objectives.AgentRegistry,
        AllbertAssist.Jido
      ]
      |> maybe_add_plugin_supervisor()
      |> maybe_add_app_supervisor()
      |> maybe_add_workspace_fragment_guard()
      |> maybe_add_jido_backed_supervisor()
      |> maybe_add_session_scratchpad()
      |> maybe_add_channels_supervisor()

    Supervisor.start_link(children, strategy: :one_for_one, name: AllbertAssist.Supervisor)
  end

  defp maybe_add_plugin_supervisor(children) do
    opts = Application.get_env(:allbert_assist, AllbertAssist.Plugin.Registry, [])
    children ++ [{AllbertAssist.Plugin.Supervisor, opts}]
  end

  defp maybe_add_session_scratchpad(children) do
    opts = Application.get_env(:allbert_assist, AllbertAssist.Session.Scratchpad, [])
    children ++ [{AllbertAssist.Session.Scratchpad, opts}]
  end

  defp maybe_add_app_supervisor(children) do
    opts = Application.get_env(:allbert_assist, AllbertAssist.App.Registry, [])

    if Keyword.get(opts, :enabled?, true) do
      children ++ [{AllbertAssist.App.Supervisor, opts}]
    else
      children ++ [{AllbertAssist.App.Supervisor, Keyword.put(opts, :enabled?, false)}]
    end
  end

  defp maybe_add_workspace_fragment_guard(children) do
    children ++ [FragmentGuard]
  end

  defp maybe_add_jido_backed_supervisor(children) do
    opts = Application.get_env(:allbert_assist, AllbertAssist.JidoBacked.Supervisor, [])
    scheduler_opts = Application.get_env(:allbert_assist, AllbertAssist.Jobs.Scheduler, [])

    children ++
      [
        {AllbertAssist.JidoBacked.Supervisor, opts |> Keyword.put_new(:scheduler, scheduler_opts)}
      ]
  end

  defp maybe_add_channels_supervisor(children) do
    opts = Application.get_env(:allbert_assist, AllbertAssist.Channels.Supervisor, [])
    children ++ [{AllbertAssist.Channels.Supervisor, opts}]
  end

  defp skip_migrations?() do
    # By default, sqlite migrations are run when using a release
    System.get_env("RELEASE_NAME") == nil
  end

  defp maybe_bootstrap_workspace_signing_secret! do
    opts =
      Application.get_env(
        :allbert_assist,
        SigningSecret,
        []
      )

    if Keyword.get(opts, :bootstrap_on_start?, true) do
      SigningSecret.ensure!()
    end
  end
end
