defmodule AllbertAssist.Actions.Memory.CompileMemoryIndex do
  @moduledoc "Rebuilds the derived markdown memory index."

  use Jido.Action,
    name: "compile_memory_index",
    description: "Rebuild the derived memory index from markdown source files.",
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

  alias AllbertAssist.Memory
  alias AllbertAssist.Memory.Compiler
  alias AllbertAssist.Security.PermissionGate
  alias AllbertAssist.Settings

  @impl true
  def run(params, context) do
    permission_decision = PermissionGate.authorize(:read_only, context)

    with {:allowed, true} <- {:allowed, PermissionGate.allowed?(permission_decision)},
         {:ok, result} <- Compiler.compile_index(Memory.root(), max_entries: max_entries(params)) do
      {:ok,
       %{
         message:
           "Compiled memory index with #{result.entry_count} entries in #{result.elapsed_ms}ms.",
         status: :completed,
         permission_decision: permission_decision,
         result: result,
         actions: [
           %{
             name: "compile_memory_index",
             status: :completed,
             permission: :read_only,
             permission_decision: permission_decision,
             execution: :derived_index_write,
             index_path: result.path,
             entry_count: result.entry_count,
             elapsed_ms: result.elapsed_ms
           }
         ]
       }}
    else
      {:allowed, false} -> denied(permission_decision)
      {:error, reason} -> error(permission_decision, reason)
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

  defp denied(permission_decision) do
    {:ok,
     %{
       message: permission_decision.reason,
       status: PermissionGate.response_status(permission_decision),
       permission_decision: permission_decision,
       actions: [action(:denied, permission_decision, nil)]
     }}
  end

  defp error(permission_decision, reason) do
    {:ok,
     %{
       message: "Unable to compile memory index: #{inspect(reason)}",
       status: :error,
       error: reason,
       permission_decision: permission_decision,
       actions: [action(:error, permission_decision, reason)]
     }}
  end

  defp action(status, permission_decision, error) do
    %{
      name: "compile_memory_index",
      status: status,
      permission: :read_only,
      permission_decision: permission_decision,
      error: error
    }
    |> Enum.reject(fn {_key, value} -> is_nil(value) end)
    |> Map.new()
  end
end
