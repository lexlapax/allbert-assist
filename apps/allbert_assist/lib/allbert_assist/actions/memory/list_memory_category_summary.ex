defmodule AllbertAssist.Actions.Memory.ListMemoryCategorySummary do
  @moduledoc "Reads a derived memory category summary."

  use AllbertAssist.Action,
    permission: :read_only,
    exposure: :internal,
    execution_mode: :memory_read,
    skill_backed?: false,
    confirmation: :not_required,
    name: "list_memory_category_summary",
    description: "Read the derived summary for one memory category.",
    category: "memory",
    tags: ["memory", "summary", "read_only"],
    schema: [
      category: [type: :string, required: true]
    ],
    output_schema: [
      message: [type: :string, required: true],
      status: [type: :atom, required: true],
      permission_decision: [type: :map, required: true],
      summary: [type: :map, required: false],
      actions: [type: {:list, :map}, required: true]
    ]

  alias AllbertAssist.Memory
  alias AllbertAssist.Security.PermissionGate

  @categories Memory.categories()

  @impl true
  def run(params, context) do
    permission_decision = PermissionGate.authorize(:read_only, context)

    with {:allowed, true} <- {:allowed, PermissionGate.allowed?(permission_decision)},
         {:ok, category} <- normalize_category(value(params, :category)),
         {:ok, summary} <- read_summary(category) do
      {:ok,
       %{
         message: "Read derived memory summary: #{summary.path}",
         status: :completed,
         permission_decision: permission_decision,
         summary: summary,
         actions: [
           %{
             name: "list_memory_category_summary",
             status: :completed,
             permission: :read_only,
             permission_decision: permission_decision,
             category: category,
             summary_path: summary.path
           }
         ]
       }}
    else
      {:allowed, false} -> denied(permission_decision)
      {:error, reason} -> error(permission_decision, reason)
    end
  end

  defp read_summary(category) do
    path = Path.join([Memory.root(), Atom.to_string(category), ".summary.md"])

    case File.read(path) do
      {:ok, content} ->
        {:ok,
         %{path: path, category: category, derived_at: derived_at(content), content: content}}

      {:error, :enoent} ->
        {:error, :not_found}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp derived_at(content) do
    case Regex.run(~r/^# Rebuilt: (.+)$/m, content) do
      [_, value] -> String.trim(value)
      _match -> nil
    end
  end

  defp normalize_category(category)
       when is_atom(category) and category in @categories,
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
       message: "Unable to read memory summary: #{inspect(reason)}",
       status: :error,
       error: reason,
       permission_decision: permission_decision,
       actions: [action(:error, permission_decision, reason)]
     }}
  end

  defp action(status, permission_decision, error) do
    %{
      name: "list_memory_category_summary",
      status: status,
      permission: :read_only,
      permission_decision: permission_decision,
      error: error
    }
    |> Enum.reject(fn {_key, value} -> is_nil(value) end)
    |> Map.new()
  end
end
