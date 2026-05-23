defmodule AllbertAssist.Actions.Trace.RecordTrace do
  @moduledoc false

  use AllbertAssist.Action,
    permission: :memory_write,
    exposure: :internal,
    execution_mode: :internal_trace,
    skill_backed?: false,
    confirmation: :not_required,
    name: "record_trace",
    description: "Record an inspectable markdown runtime trace when tracing is enabled.",
    category: "trace",
    tags: ["trace", "memory", "internal"],
    schema: [turn: [type: :map, required: true]],
    output_schema: [
      message: [type: :string, required: true],
      status: [type: :atom, required: true],
      actions: [type: {:list, :map}, required: true]
    ]

  alias AllbertAssist.Runtime.Trace
  alias AllbertAssist.Security.PermissionGate

  @impl true
  def run(%{turn: turn}, context) when is_map(turn) do
    permission_decision = PermissionGate.authorize(:memory_write, context)

    with true <- PermissionGate.allowed?(permission_decision),
         {:ok, trace} <- Trace.record_turn(turn) do
      {:ok,
       %{
         message: "Trace recorded.",
         status: :completed,
         trace_id: trace.path,
         trace: trace,
         actions: [action(:completed, permission_decision, trace.path)]
       }}
    else
      false ->
        denied(permission_decision)

      {:disabled, :tracing_disabled} ->
        disabled(permission_decision)

      {:error, reason} ->
        failed(permission_decision, reason)
    end
  end

  def run(_params, context) do
    permission_decision = PermissionGate.authorize(:memory_write, context)
    failed(permission_decision, :invalid_trace_turn)
  end

  defp disabled(permission_decision) do
    {:ok,
     %{
       message: "Trace recording is disabled.",
       status: :completed,
       trace_id: nil,
       actions: [action(:skipped, permission_decision, nil, :tracing_disabled)]
     }}
  end

  defp denied(permission_decision) do
    {:ok,
     %{
       message: "Trace recording was denied.",
       status: :denied,
       trace_id: nil,
       error: :permission_denied,
       actions: [action(:denied, permission_decision, nil, :permission_denied)]
     }}
  end

  defp failed(permission_decision, reason) do
    {:ok,
     %{
       message: "Trace recording failed: #{inspect(reason)}",
       status: :error,
       trace_id: nil,
       error: reason,
       actions: [action(:error, permission_decision, nil, reason)]
     }}
  end

  defp action(status, permission_decision, trace_id, error \\ nil) do
    %{
      name: "record_trace",
      status: status,
      permission: :memory_write,
      permission_decision: permission_decision,
      trace_metadata: %{
        trace_id: trace_id,
        error: error
      }
    }
  end
end
