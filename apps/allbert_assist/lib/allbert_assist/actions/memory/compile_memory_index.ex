defmodule AllbertAssist.Actions.Memory.CompileMemoryIndex do
  @moduledoc "Compatibility action that rebuilds the derived Memory projection."

  use AllbertAssist.Action,
    permission: :read_only,
    exposure: :internal,
    execution_mode: :memory_index_compile,
    skill_backed?: false,
    confirmation: :not_required,
    name: "compile_memory_index",
    description: "Rebuild the derived Memory projection from canonical Markdown claims.",
    category: "memory",
    tags: ["memory", "index", "read_only"],
    schema: [
      user_id: [type: :string, required: false],
      max_entries: [type: :integer, required: false]
    ],
    output_schema: [
      message: [type: :string, required: true],
      status: [type: :atom, required: true],
      permission_decision: [type: :map, required: true],
      result: [type: :map, required: false],
      actions: [type: {:list, :map}, required: true]
    ]

  alias AllbertAssist.Memory.Projection
  alias AllbertAssist.Paths
  alias AllbertAssist.Security.PermissionGate
  alias AllbertAssist.Settings

  @impl true
  def run(params, context) do
    permission_decision = PermissionGate.authorize(:read_only, context)
    started = System.monotonic_time(:millisecond)

    with {:allowed, true} <- {:allowed, PermissionGate.allowed?(permission_decision)},
         {:ok, projection} <- projection_owner(context),
         max_entries <- max_entries(params),
         {:ok, result} <- Projection.rebuild_with_options([max_entries: max_entries], projection) do
      completed(permission_decision, compatibility_result(result, max_entries, started))
    else
      {:allowed, false} ->
        denied(permission_decision)

      {:error, {:memory_projection_rebuild_limit_exceeded, details}} ->
        degraded(permission_decision, details, started)

      {:error, reason} ->
        error(permission_decision, reason)
    end
  end

  defp compatibility_result(result, max_entries, started) do
    %{
      path: result.path,
      entry_count: result.claim_count,
      categories: result.categories,
      derived_at: result.derived_at,
      elapsed_ms: elapsed_ms(started),
      max_entries: max_entries,
      generation_id: result.generation_id,
      projection_revision: result.projection_revision,
      revision_count: result.revision_count,
      excluded_count: result.excluded_count,
      partial?: false,
      degraded?: false
    }
  end

  defp completed(permission_decision, result) do
    {:ok,
     %{
       message:
         "Compiled Memory projection with #{result.entry_count} entries in #{result.elapsed_ms}ms.",
       status: :completed,
       permission_decision: permission_decision,
       result: result,
       actions: [action(:completed, permission_decision, nil, result)]
     }}
  end

  defp degraded(permission_decision, details, started) do
    result = %{
      path: Path.join(Paths.memory_projection_root(), "current.sqlite3"),
      entry_count: details.processed_entries,
      categories: [],
      derived_at: DateTime.utc_now() |> DateTime.truncate(:second) |> DateTime.to_iso8601(),
      elapsed_ms: elapsed_ms(started),
      max_entries: details.max_entries,
      discovered_entries: details.discovered_entries,
      partial?: true,
      degraded?: true
    }

    {:ok,
     %{
       message:
         "Memory projection rebuild stopped at the #{details.max_entries}-entry cap; no incomplete generation was promoted.",
       status: :degraded,
       permission_decision: permission_decision,
       result: result,
       actions: [action(:degraded, permission_decision, nil, result)]
     }}
  end

  defp projection_owner(context) do
    case Map.get(context, :memory_projection) || Process.whereis(Projection) do
      nil -> {:error, :memory_projection_owner_unavailable}
      projection -> {:ok, projection}
    end
  end

  defp max_entries(params) do
    case Map.get(params, :max_entries) || Map.get(params, "max_entries") do
      value when is_integer(value) -> value
      _other -> settings_value("memory.max_index_entries", 1000)
    end
  end

  defp settings_value(key, default) do
    case Settings.get(key) do
      {:ok, value} -> value
      _other -> default
    end
  end

  defp elapsed_ms(started), do: System.monotonic_time(:millisecond) - started

  defp denied(permission_decision) do
    {:ok,
     %{
       message: permission_decision.reason,
       status: PermissionGate.response_status(permission_decision),
       permission_decision: permission_decision,
       actions: [action(:denied, permission_decision, nil, nil)]
     }}
  end

  defp error(permission_decision, reason) do
    {:ok,
     %{
       message: "Unable to compile memory index: #{inspect(reason)}",
       status: :error,
       error: reason,
       permission_decision: permission_decision,
       actions: [action(:error, permission_decision, reason, nil)]
     }}
  end

  defp action(status, permission_decision, error, result) do
    %{
      name: "compile_memory_index",
      status: status,
      permission: :read_only,
      permission_decision: permission_decision,
      execution: :memory_projection_rebuild,
      error: error,
      index_path: result && result.path,
      entry_count: result && result.entry_count,
      elapsed_ms: result && result.elapsed_ms
    }
    |> Enum.reject(fn {_key, value} -> is_nil(value) end)
    |> Map.new()
  end
end
