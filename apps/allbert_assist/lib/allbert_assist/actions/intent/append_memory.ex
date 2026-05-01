defmodule AllbertAssist.Actions.Intent.AppendMemory do
  @moduledoc """
  Appends a markdown memory entry.
  """

  use Jido.Action,
    name: "append_memory",
    description: "Append a user memory to the markdown-backed memory store.",
    category: "intent",
    tags: ["intent", "memory", "durable"],
    schema: [
      memory: [type: :string, required: true, doc: "The memory text the user asked to save."],
      source_text: [type: :string, required: false, doc: "The original user prompt."]
    ],
    output_schema: [
      message: [type: :string, required: true],
      status: [type: :atom, required: true],
      permission_decision: [type: :map, required: true],
      memory: [type: :map, required: true],
      actions: [type: {:list, :map}, required: true]
    ]

  alias AllbertAssist.Memory
  alias AllbertAssist.Security.PermissionGate

  @impl true
  def run(%{memory: memory} = params, context) do
    memory = String.trim(memory)
    permission_decision = PermissionGate.authorize(:memory_write, context)
    request = Map.get(context, :request, %{})

    case Memory.append(%{
           category: category_for(memory),
           body: memory,
           summary: memory,
           source_signal_id: Map.get(request, :input_signal_id, "unknown"),
           actor: Map.get(request, :operator_id, "local"),
           agent: inspect(Map.get(context, :agent, AllbertAssist.Agents.IntentAgent)),
           channel: Map.get(request, :channel, "unknown")
         }) do
      {:ok, entry} ->
        {:ok,
         %{
           message: message(entry),
           status: PermissionGate.response_status(permission_decision),
           permission_decision: permission_decision,
           memory: entry,
           actions: [
             %{
               name: "append_memory",
               status: :completed,
               permission: :memory_write,
               permission_decision: permission_decision,
               durable: true,
               memory_path: entry.path,
               memory_category: entry.category,
               input: %{memory: memory, source_text: Map.get(params, :source_text)}
             }
           ]
         }}

      {:error, reason} ->
        {:error, {:memory_append_failed, reason}}
    end
  end

  defp category_for(memory) do
    if memory =~
         ~r/\b(prefer|preferred|preference|like|dislike|identity|timezone|communication|local_context)\b/i do
      :preferences
    else
      :notes
    end
  end

  defp message(entry) do
    """
    Saved markdown memory.

    Summary: #{entry.summary}
    Category: #{entry.category}
    Path: #{entry.path}

    The memory is durable markdown and remains inspectable at the path above.
    """
    |> String.trim()
  end
end
