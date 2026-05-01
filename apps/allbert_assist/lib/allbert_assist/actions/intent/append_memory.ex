defmodule AllbertAssist.Actions.Intent.AppendMemory do
  @moduledoc """
  Selects the future markdown memory append capability without persisting yet.

  Durable markdown writes are Milestone 5. This action gives the intent agent a
  typed memory-write decision surface now, while keeping persistence out of M4.
  """

  use Jido.Action,
    name: "append_memory",
    description:
      "Prepare a user memory for the markdown-backed append action planned in v0.01 M5.",
    category: "intent",
    tags: ["intent", "memory", "planned"],
    schema: [
      memory: [type: :string, required: true, doc: "The memory text the user asked to save."],
      source_text: [type: :string, required: false, doc: "The original user prompt."]
    ],
    output_schema: [
      message: [type: :string, required: true],
      status: [type: :atom, required: true],
      permission_decision: [type: :map, required: true],
      actions: [type: {:list, :map}, required: true]
    ]

  alias AllbertAssist.Security.PermissionGate

  @impl true
  def run(%{memory: memory} = params, context) do
    memory = String.trim(memory)
    permission_decision = PermissionGate.authorize(:memory_write, context)

    {:ok,
     %{
       message: message(memory),
       status: PermissionGate.response_status(permission_decision),
       permission_decision: permission_decision,
       actions: [
         %{
           name: "append_memory",
           status: :selected,
           permission: :memory_write,
           permission_decision: permission_decision,
           durable: false,
           milestone: "v0.01 M5",
           input: %{memory: memory, source_text: Map.get(params, :source_text)}
         }
       ]
     }}
  end

  defp message(memory) do
    """
    Selected action: append_memory.

    I would save this as markdown memory once M5 lands:
    #{memory}

    M4 gates and validates the memory action; it does not persist durable memory yet.
    """
    |> String.trim()
  end
end
