defmodule AllbertAssist.Artifacts.IngestionSupervisor do
  @moduledoc """
  Supervisor for the Artifacts Central retained-ingestion sensor path.

  The Jido sensor runtime is a supervised child with an explicit dispatch target
  (`AllbertAssist.Artifacts.IngestionConsumer` by default). The retained-media
  caller runs the registered artifact write action only after the consumer
  receives and publishes the redacted sensor signal.
  """

  use Supervisor

  alias AllbertAssist.Artifacts.IngestionConsumer
  alias AllbertAssist.Artifacts.IngestionSensor
  alias Jido.Sensor.Runtime, as: SensorRuntime

  @sensor_child_id AllbertAssist.Artifacts.IngestionSensor.Runtime

  @doc false
  @spec start_link(keyword()) :: Supervisor.on_start()
  def start_link(opts \\ []) do
    Supervisor.start_link(__MODULE__, opts, name: Keyword.get(opts, :name, __MODULE__))
  end

  @doc false
  @spec child_spec(keyword()) :: Supervisor.child_spec()
  def child_spec(opts) do
    %{
      id: Keyword.get(opts, :child_id, __MODULE__),
      start: {__MODULE__, :start_link, [opts]},
      restart: :permanent,
      shutdown: :infinity,
      type: :supervisor
    }
  end

  @doc "Return the stable child id used for the Jido sensor runtime."
  @spec sensor_child_id() :: AllbertAssist.Artifacts.IngestionSensor.Runtime
  def sensor_child_id, do: @sensor_child_id

  @doc "Return the supervised Jido sensor runtime pid, when running."
  @spec sensor_pid(Supervisor.supervisor(), term()) :: pid() | nil
  def sensor_pid(supervisor \\ __MODULE__, child_id \\ @sensor_child_id) do
    supervisor
    |> Supervisor.which_children()
    |> Enum.find_value(fn
      {^child_id, pid, :worker, [SensorRuntime]} when is_pid(pid) -> pid
      _child -> nil
    end)
  catch
    :exit, _reason -> nil
  end

  @impl Supervisor
  def init(opts) do
    consumer_name = Keyword.get(opts, :consumer_name, IngestionConsumer)
    sensor_child_id = Keyword.get(opts, :sensor_child_id, @sensor_child_id)

    consumer_opts =
      opts
      |> Keyword.get(:consumer, [])
      |> Keyword.put_new(:name, consumer_name)
      |> Keyword.put_new(:sensor_supervisor, Keyword.get(opts, :name, __MODULE__))
      |> Keyword.put_new(:sensor_child_id, sensor_child_id)

    sensor_context =
      opts
      |> Keyword.get(:sensor_context, %{})
      |> Map.put_new(:agent_ref, consumer_name)

    sensor_runtime_opts = [
      sensor: IngestionSensor,
      config: Keyword.get(opts, :sensor_config, %{}),
      context: sensor_context,
      id: sensor_child_id
    ]

    children = [
      {IngestionConsumer, consumer_opts},
      Supervisor.child_spec({SensorRuntime, sensor_runtime_opts}, id: sensor_child_id)
    ]

    Supervisor.init(children, strategy: :one_for_one)
  end
end
