defmodule AllbertAssist.Application do
  # See https://hexdocs.pm/elixir/Application.html
  # for more information on OTP Applications
  @moduledoc false

  use Application

  alias AllbertAssist.Database
  alias AllbertAssist.Runtime.Attach
  alias AllbertAssist.Runtime.WriterLock.Holder, as: WriterLockHolder
  alias AllbertAssist.Settings.ProviderCatalog
  alias AllbertAssist.Workspace.Fragment.Guard, as: FragmentGuard
  alias AllbertAssist.Workspace.Fragment.SigningSecret

  @impl true
  def start(_type, _args) do
    maybe_bootstrap_workspace_signing_secret!()
    ProviderCatalog.configure_jido_model_aliases!()
    Database.migrate_before_supervision!()

    children =
      [
        AllbertAssist.Repo,
        # v0.62 M5: in serve/daemon mode only (ALLBERT_HOLD_WRITER_LOCK), hold
        # the single-writer lock so a second `allbert` command refuses to boot
        # a competing writer (Locked Decision 5). Absent in dev/test.
        writer_lock_child(),
        {DNSCluster, query: Application.get_env(:allbert_assist, :dns_cluster_query) || :ignore},
        {Phoenix.PubSub, name: AllbertAssist.PubSub},
        {Jido.Signal.Bus, name: AllbertAssist.SignalBus},
        {Registry, keys: :unique, name: AllbertAssist.Coding.TurnRegistry},
        {Task.Supervisor, name: AllbertAssist.TaskSupervisor},
        AllbertAssist.Settings.Supervisor,
        AllbertAssist.Artifacts.GC,
        AllbertAssist.PublicProtocol.RateLimiter,
        AllbertAssist.PublicProtocol.ResultReadbackSweeper,
        AllbertAssist.Objectives.AgentRegistry,
        AllbertAssist.Intent.Router.Index,
        AllbertAssist.Intent.Router.PendingStore,
        AllbertAssist.Jido
      ]
      |> Enum.reject(&is_nil/1)
      |> maybe_add_plugin_supervisor()
      |> maybe_add_app_supervisor()
      |> maybe_add_dynamic_plugins_supervisor()
      |> maybe_add_workspace_fragment_guard()
      |> maybe_add_jido_backed_supervisor()
      |> maybe_add_session_scratchpad()
      |> maybe_add_channels_supervisor()
      |> maybe_add_attach_server()

    Supervisor.start_link(children, strategy: :one_for_one, name: AllbertAssist.Supervisor)
  end

  defp writer_lock_child do
    if WriterLockHolder.enabled?() do
      WriterLockHolder
    end
  end

  defp maybe_add_attach_server(children) do
    if WriterLockHolder.enabled?() do
      children ++ [Attach.Server]
    else
      children
    end
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

  defp maybe_add_dynamic_plugins_supervisor(children) do
    opts = Application.get_env(:allbert_assist, AllbertAssist.DynamicPlugins.Supervisor, [])
    children ++ [{AllbertAssist.DynamicPlugins.Supervisor, opts}]
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
