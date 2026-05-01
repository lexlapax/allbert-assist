defmodule AllbertAssist.Actions.Intent.AppendMemory do
  @moduledoc """
  Selects the future markdown memory append capability without persisting yet.

  Durable markdown writes are Milestone 5. This action gives the intent agent a
  typed memory-write decision surface now, while keeping persistence out of M3.
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
      actions: [type: {:list, :map}, required: true]
    ]

  @impl true
  def run(%{memory: memory} = params, _context) do
    memory = String.trim(memory)

    {:ok,
     %{
       message: message(memory),
       status: :completed,
       actions: [
         %{
           name: "append_memory",
           status: :selected,
           permission: :memory_write,
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

    M3 only selects and validates the memory action; it does not persist durable memory yet.
    """
    |> String.trim()
  end
end
