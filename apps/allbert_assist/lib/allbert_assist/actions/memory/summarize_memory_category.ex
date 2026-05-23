defmodule AllbertAssist.Actions.Memory.SummarizeMemoryCategory do
  @moduledoc "Builds a derived category summary markdown file."

  use AllbertAssist.Action,
    permission: :read_only,
    exposure: :internal,
    execution_mode: :memory_summary_compile,
    skill_backed?: false,
    confirmation: :not_required,
    name: "summarize_memory_category",
    description: "Build a derived memory category summary without model calls.",
    category: "memory",
    tags: ["memory", "summary", "read_only"],
    schema: [
      category: [type: :string, required: true],
      user_id: [type: :string, required: false]
    ],
    output_schema: [
      message: [type: :string, required: true],
      status: [type: :atom, required: true],
      permission_decision: [type: :map, required: true],
      result: [type: :map, required: false],
      actions: [type: {:list, :map}, required: true]
    ]

  alias AllbertAssist.Actions.Memory.Context
  alias AllbertAssist.Memory
  alias AllbertAssist.Memory.Compiler
  alias AllbertAssist.Security.PermissionGate

  @impl true
  def run(params, context) do
    permission_decision = PermissionGate.authorize(:read_only, context)

    with {:allowed, true} <- {:allowed, PermissionGate.allowed?(permission_decision)},
         {:ok, user_id} <- Context.user_id(params, context),
         {:ok, category} <- normalize_category(value(params, :category)),
         {:ok, result} <- Compiler.summarize_category(Memory.root(), category, user_id: user_id) do
      {:ok,
       %{
         message: "Wrote derived memory summary: #{result.path}",
         status: :completed,
         permission_decision: permission_decision,
         result: Map.delete(result, :summary),
         actions: [
           %{
             name: "summarize_memory_category",
             status: :completed,
             permission: :read_only,
             permission_decision: permission_decision,
             category: category,
             summary_path: result.path,
             entry_count: result.entry_count
           }
         ]
       }}
    else
      {:allowed, false} -> denied(permission_decision)
      {:error, reason} -> error(permission_decision, reason)
    end
  end

  defp normalize_category(category)
       when is_atom(category) and category in [:notes, :preferences, :traces, :skills],
       do: {:ok, category}

  defp normalize_category(category) when is_binary(category) do
    category
    |> String.to_existing_atom()
    |> normalize_category()
  rescue
    ArgumentError -> {:error, {:invalid_category, category}}
  end

  defp normalize_category(category), do: {:error, {:invalid_category, category}}

  defp value(params, key), do: Map.get(params, key) || Map.get(params, Atom.to_string(key))

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
       message: "Unable to summarize memory category: #{inspect(reason)}",
       status: :error,
       error: reason,
       permission_decision: permission_decision,
       actions: [action(:error, permission_decision, reason)]
     }}
  end

  defp action(status, permission_decision, error) do
    %{
      name: "summarize_memory_category",
      status: status,
      permission: :read_only,
      permission_decision: permission_decision,
      error: error
    }
    |> Enum.reject(fn {_key, value} -> is_nil(value) end)
    |> Map.new()
  end
end
