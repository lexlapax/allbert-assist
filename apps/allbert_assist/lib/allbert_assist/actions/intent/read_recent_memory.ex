defmodule AllbertAssist.Actions.Intent.ReadRecentMemory do
  @moduledoc """
  Reads recent markdown-backed memory entries.
  """

  use AllbertAssist.Action,
    permission: :read_only,
    exposure: :agent,
    execution_mode: :read_only,
    skill_backed?: true,
    confirmation: :not_required,
    name: "read_recent_memory",
    description: "Read recent entries from the markdown-backed memory store.",
    category: "intent",
    tags: ["intent", "memory", "read_only", "durable"],
    schema: [
      # v0.65 local-knowledge fix: optional so launch-path recall prompts like
      # "show what you remember" run (and return recent memory) instead of stalling on a
      # missing slot. `Memory.recent` treats an empty query as "most recent, unfiltered".
      query: [type: :string, required: false, doc: "Optional memory recall question."]
    ],
    output_schema: [
      message: [type: :string, required: true],
      status: [type: :atom, required: true],
      permission_decision: [type: :map, required: true],
      memories: [type: {:list, :map}, required: true],
      actions: [type: {:list, :map}, required: true]
    ]

  alias AllbertAssist.Memory
  alias AllbertAssist.Security.PermissionGate

  @impl true
  def run(params, context) do
    query = Map.get(params, :query) || ""
    permission_decision = PermissionGate.authorize(:read_only, context)
    {:ok, entries} = Memory.recent(query: query, limit: 5)

    {:ok,
     %{
       message: message(entries),
       status: PermissionGate.response_status(permission_decision),
       permission_decision: permission_decision,
       memories: entries,
       actions: [
         %{
           name: "read_recent_memory",
           status: :completed,
           permission: :read_only,
           permission_decision: permission_decision,
           durable_source_ready: true,
           memory_count: length(entries),
           input: %{query: query}
         }
       ]
     }}
  end

  defp message([]) do
    """
    Selected action: read_recent_memory.

    I did not find markdown memory entries for that request yet.
    """
    |> String.trim()
  end

  defp message(entries) do
    memory_lines =
      entries
      |> Enum.map(fn entry ->
        "- #{entry.summary} (#{entry.category}, #{entry.timestamp})\n  #{memory_excerpt(entry)}\n  #{entry.path}"
      end)
      |> Enum.join("\n")

    """
    Selected action: read_recent_memory.

    I found these markdown-backed memories:

    #{memory_lines}
    """
    |> String.trim()
  end

  defp memory_excerpt(entry) do
    entry.body
    |> String.replace(~r/\s+/, " ")
    |> String.trim()
    |> String.slice(0, 180)
  end
end
