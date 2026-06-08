defmodule AllbertAssist.Artifacts.IngestionSensor do
  @moduledoc """
  Advisory Jido sensor for retained artifact ingestion requests.

  The sensor emits redacted ingestion-request signals only. The paired core
  consumer is the explicit dispatch target and confirms signal delivery; the
  retained-media caller then runs the registered `put_artifact` action. This
  sensor never writes the artifact store directly and never grants authority by
  itself.
  """

  @ingest_requested_type "allbert.artifact.ingest_requested"
  @source "/allbert/artifacts/ingestion_sensor"

  use Jido.Sensor,
    name: "artifact_ingestion_sensor",
    description: "Emits advisory retained-artifact ingestion requests.",
    schema: Zoi.object(%{}, coerce: true)

  @doc "Return the signal type emitted for retained artifact ingestion requests."
  @spec ingest_requested_type() :: String.t()
  def ingest_requested_type, do: @ingest_requested_type

  @doc "Return the source used by emitted ingestion-request signals."
  @spec source() :: String.t()
  def source, do: @source

  @impl Jido.Sensor
  def init(_config, context) do
    {:ok, %{dispatch_target: field(context, :agent_ref)}}
  end

  @impl Jido.Sensor
  def handle_event({:ingest, request}, state) when is_map(request) do
    signal =
      Jido.Signal.new!(
        @ingest_requested_type,
        redacted_request(request),
        source: @source,
        subject: subject(request)
      )

    {:ok, state, [{:emit, signal}]}
  end

  def handle_event(_event, state), do: {:ok, state}

  defp redacted_request(request) do
    %{
      request_id: field(request, :request_id),
      byte_size: field(request, :byte_size),
      content_sha256: field(request, :content_sha256),
      metadata: field(request, :metadata) || %{},
      advisory_only?: true
    }
    |> Enum.reject(fn {_key, value} -> is_nil(value) end)
    |> Map.new()
  end

  defp subject(request) do
    field(request, :user_id) || field(request, :operator_id)
  end

  defp field(map, key) when is_map(map) do
    Map.get(map, key, Map.get(map, Atom.to_string(key)))
  end

  defp field(_map, _key), do: nil
end
