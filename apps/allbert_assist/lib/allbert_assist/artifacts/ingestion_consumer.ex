defmodule AllbertAssist.Artifacts.IngestionConsumer do
  @moduledoc """
  Core consumer for retained artifact ingestion signals.

  Retained-media callers submit bytes here. The consumer asks the supervised
  Jido sensor runtime to emit a redacted ingestion-request signal, receives that
  signal through the configured dispatch target, and publishes it to Allbert's
  SignalBus. Once dispatch is confirmed, the caller process stores bytes by
  running the registered `put_artifact` action through
  `AllbertAssist.Actions.Runner`; this keeps Ecto sandbox ownership with the
  caller in tests while preserving the supervised sensor path.
  """

  use GenServer

  alias AllbertAssist.Actions.Runner
  alias AllbertAssist.Artifacts.IngestionSupervisor
  alias AllbertAssist.Artifacts.Store
  alias AllbertAssist.Maps
  alias AllbertAssist.Runtime.Redactor
  alias AllbertAssist.Settings
  alias AllbertAssist.Signals
  alias Jido.Sensor.Runtime, as: SensorRuntime
  alias Jido.Signal

  @default_timeout 15_000
  @ingest_requested_type "allbert.artifact.ingest_requested"

  @type ingest_result :: {:ok, map()} | {:error, term()}

  @doc false
  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: Keyword.get(opts, :name, __MODULE__))
  end

  @doc false
  @spec child_spec(keyword()) :: Supervisor.child_spec()
  def child_spec(opts) do
    %{
      id: Keyword.get(opts, :child_id, __MODULE__),
      start: {__MODULE__, :start_link, [opts]},
      restart: :permanent,
      shutdown: 5_000,
      type: :worker
    }
  end

  @doc "Request retained artifact ingestion through the supervised sensor path."
  @spec ingest(binary(), map(), keyword()) :: ingest_result()
  def ingest(bytes, metadata, opts \\ [])

  def ingest(bytes, metadata, opts) when is_binary(bytes) and is_map(metadata) do
    context = Keyword.get(opts, :context, %{})

    with {:ok, signal} <- request_signal(bytes, metadata, context, opts) do
      run_put_artifact(signal, bytes, metadata, context)
    end
  end

  def ingest(_bytes, _metadata, _opts), do: {:error, :invalid_artifact_ingestion_request}

  defp request_signal(bytes, metadata, context, opts) do
    server = Keyword.get(opts, :server, __MODULE__)
    timeout = Keyword.get(opts, :timeout, ingestion_timeout_ms())
    GenServer.call(server, {:emit_ingest_request, bytes, metadata, context}, timeout)
  end

  @impl GenServer
  def init(opts) do
    {:ok,
     %{
       sensor_supervisor: Keyword.get(opts, :sensor_supervisor, IngestionSupervisor),
       sensor_child_id:
         Keyword.get(opts, :sensor_child_id, IngestionSupervisor.sensor_child_id()),
       pending: %{}
     }}
  end

  @impl GenServer
  def handle_call({:emit_ingest_request, bytes, metadata, context}, from, state) do
    case sensor_pid(state) do
      {:ok, sensor_pid} ->
        request_id = request_id()
        request = request(request_id, bytes, metadata, context)
        :ok = SensorRuntime.event(sensor_pid, {:ingest, request})

        pending = Map.put(state.pending, request_id, %{from: from})

        {:noreply, %{state | pending: pending}}

      {:error, reason} ->
        {:reply, {:error, reason}, state}
    end
  end

  @impl GenServer
  def handle_info({:signal, %Signal{type: @ingest_requested_type} = signal}, state) do
    request_id = field(signal.data, :request_id)

    case Map.pop(state.pending, request_id) do
      {nil, pending} ->
        {:noreply, %{state | pending: pending}}

      {%{from: from}, pending} ->
        :ok = Signals.log(signal)
        GenServer.reply(from, {:ok, signal})
        {:noreply, %{state | pending: pending}}
    end
  end

  def handle_info(_message, state), do: {:noreply, state}

  defp sensor_pid(%{sensor_supervisor: supervisor, sensor_child_id: child_id}) do
    case IngestionSupervisor.sensor_pid(supervisor, child_id) do
      pid when is_pid(pid) -> {:ok, pid}
      nil -> {:error, :artifact_ingestion_sensor_unavailable}
    end
  end

  defp request(request_id, bytes, metadata, context) do
    %{
      request_id: request_id,
      byte_size: byte_size(bytes),
      content_sha256: Store.sha256(bytes),
      metadata: Redactor.redact_artifact_metadata(metadata),
      user_id: context_value(context, :user_id),
      operator_id: context_value(context, :operator_id)
    }
  end

  defp run_put_artifact(signal, bytes, metadata, caller_context) do
    context = sensor_context(caller_context, signal)

    case Runner.run(
           "put_artifact",
           %{bytes: bytes, metadata: metadata},
           context
         ) do
      {:ok, %{status: :completed, artifact: artifact} = response} ->
        {:ok, attach_ingestion(artifact, signal, response)}

      {:ok, %{error: reason}} ->
        {:error, reason}

      {:ok, %{status: status}} ->
        {:error, {:artifact_ingestion_not_completed, status}}
    end
  end

  defp attach_ingestion(artifact, signal, response) do
    artifact
    |> Map.put(:path, Store.object_path!(artifact.sha256))
    |> Map.put(:ingestion, %{
      action_name: "put_artifact",
      signal_id: signal.id,
      signal_type: signal.type,
      permission_decision: Map.get(response, :permission_decision),
      runner_metadata: Map.get(response, :runner_metadata)
    })
  end

  defp sensor_context(context, signal) when is_map(context) do
    request =
      case field(context, :request) do
        request when is_map(request) -> request
        _request -> %{}
      end

    context
    |> Map.put_new(:actor, context_value(context, :operator_id, "artifact_sensor"))
    |> Map.put_new(:channel, :artifact_sensor)
    |> Map.put(:request, request)
    |> put_in_request(:input_signal_id, signal.id)
    |> put_in_request(:source_signal_id, signal.id)
    |> put_in_request(:channel, :artifact_sensor)
  end

  defp sensor_context(_context, signal),
    do: sensor_context(%{request: %{input_signal_id: signal.id}}, signal)

  defp put_in_request(context, key, value) do
    request = Map.get(context, :request, %{})
    Map.put(context, :request, Map.put_new(request, key, value))
  end

  defp context_value(context, key, default \\ nil)

  defp context_value(context, key, default) when is_map(context) do
    request = field(context, :request) || %{}
    field(context, key) || field(request, key) || default
  end

  defp context_value(_context, _key, default), do: default

  defp field(map, key), do: Maps.field(map, key)

  defp ingestion_timeout_ms do
    case Settings.get("artifacts.ingestion_timeout_ms") do
      {:ok, value} when is_integer(value) and value > 0 -> value
      _other -> @default_timeout
    end
  end

  defp request_id do
    "artifact_ingest_" <> Base.url_encode64(:crypto.strong_rand_bytes(12), padding: false)
  end
end
