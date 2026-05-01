defmodule AllbertAssist.Actions.Intent.ReadRecentMemory do
  @moduledoc """
  Selects the future markdown recent-memory read capability.
  """

  use Jido.Action,
    name: "read_recent_memory",
    description:
      "Prepare a recent-memory read against the markdown-backed memory store planned in M5.",
    category: "intent",
    tags: ["intent", "memory", "read_only", "planned"],
    schema: [
      query: [type: :string, required: true, doc: "The memory recall question."]
    ],
    output_schema: [
      message: [type: :string, required: true],
      status: [type: :atom, required: true],
      actions: [type: {:list, :map}, required: true]
    ]

  @impl true
  def run(%{query: query}, _context) do
    {:ok,
     %{
       message: message(),
       status: :completed,
       actions: [
         %{
           name: "read_recent_memory",
           status: :selected,
           permission: :read_only,
           durable_source_ready: false,
           milestone: "v0.01 M5",
           input: %{query: query}
         }
       ]
     }}
  end

  defp message do
    """
    Selected action: read_recent_memory.

    The markdown memory source is not implemented until M5, so there is no durable memory to read yet.
    """
    |> String.trim()
  end
end
