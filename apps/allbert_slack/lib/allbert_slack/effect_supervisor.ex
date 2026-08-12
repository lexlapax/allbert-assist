defmodule AllbertSlack.EffectSupervisor do
  @moduledoc false

  use Supervisor

  alias AllbertAssist.Channels
  alias AllbertAssist.Pack.{ActivationContext, ActivationGuard}

  @channel_id "slack"

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
      children =
        case Channels.pack_channel_child_spec(@channel_id) do
          {:ok, child_spec} -> [child_spec]
          :skip -> []
        end

      # An effect child is never independently recoverable: a restart changes
      # runtime state while the barrier epoch is still live. Let the gate own a
      # complete teardown and replacement activation instead. Mirrors
      # AllbertAssist.Pack.ResidualEffectSupervisor's `one_for_all`/`max_restarts: 0`.
      Supervisor.init(children, strategy: :one_for_all, max_restarts: 0)
    else
      _other -> {:stop, :product_not_ready}
    end
  end
end
