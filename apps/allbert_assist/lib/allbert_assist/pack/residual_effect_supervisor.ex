defmodule AllbertAssist.Pack.ResidualEffectSupervisor do
  @moduledoc false

  use Supervisor

  alias AllbertAssist.Pack.{ActivationContext, ActivationGuard}

  @spec start_link(keyword()) :: Supervisor.on_start()
  def start_link(opts \\ []) do
    case Keyword.get(opts, :name) do
      nil -> Supervisor.start_link(__MODULE__, opts)
      name -> Supervisor.start_link(__MODULE__, opts, name: name)
    end
  end

  @impl true
  def init(opts) do
    with %ActivationContext{} = context <- Keyword.get(opts, :allbert_pack_activation),
         :ok <- ActivationGuard.validate(allbert_pack_activation: context) do
      app_registry = Keyword.get(opts, :app_registry, AllbertAssist.App.Registry)

      app_dynamic_supervisor =
        Keyword.get(opts, :app_dynamic_supervisor, AllbertAssist.App.DynamicSupervisor)

      plugin_registry = Keyword.get(opts, :plugin_registry, AllbertAssist.Plugin.Registry)

      plugin_child_supervisor =
        Keyword.get(opts, :plugin_child_supervisor, AllbertAssist.Plugin.ChildSupervisor)

      children =
        [
          {AllbertAssist.App.DynamicSupervisor, name: app_dynamic_supervisor},
          {AllbertAssist.Plugin.ChildSupervisor, name: plugin_child_supervisor},
          {AllbertAssist.Pack.StagedChildren,
           allbert_pack_activation: context,
           app_registry: app_registry,
           app_dynamic_supervisor: app_dynamic_supervisor,
           plugin_registry: plugin_registry,
           plugin_child_supervisor: plugin_child_supervisor}
        ] ++ inject_authorizing_boot_carrier(Keyword.get(opts, :effect_children, []), context)

      # An effect child is never independently recoverable: a restart changes
      # runtime state while the barrier epoch is still live. Let the gate own a
      # complete teardown and replacement activation instead.
      Supervisor.init(children, strategy: :one_for_all, max_restarts: 0)
    else
      _other -> {:stop, :product_not_ready}
    end
  end

  # FirstRun's provider probing and Settings reconciliation are the one
  # residual child-specific completion that must happen while Readiness is
  # authorizing. It consumes the context synchronously and exits; ordinary
  # long-lived children receive no activation carrier.
  defp inject_authorizing_boot_carrier(children, context) do
    Enum.map(children, fn
      {AllbertAssist.FirstRun.Enablement.BootWorker, child_opts} when is_list(child_opts) ->
        {AllbertAssist.FirstRun.Enablement.BootWorker,
         Keyword.put(child_opts, :allbert_pack_activation, context)}

      child ->
        child
    end)
  end
end
