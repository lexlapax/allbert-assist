defmodule AllbertAssist.Actions.Intent.PlanShellCommand do
  @moduledoc """
  Plans shell work without executing it.

  This action is deliberately inert. It exists so the primary intent agent can
  handle command-shaped requests through an explicit capability instead of
  taking hidden side effects.
  """

  use Jido.Action,
    name: "plan_shell_command",
    description: "Draft a shell-command plan or safety note without executing anything.",
    category: "intent",
    tags: ["intent", "shell", "command_plan", "safe"],
    schema: [
      command: [type: :string, required: true, doc: "The requested shell command or task."],
      source_text: [type: :string, required: false, doc: "The original user prompt."]
    ],
    output_schema: [
      message: [type: :string, required: true],
      status: [type: :atom, required: true],
      actions: [type: {:list, :map}, required: true]
    ]

  @impl true
  def run(%{command: command} = params, _context) do
    command = String.trim(command)
    destructive? = destructive_command?(command)

    {:ok,
     %{
       message: message(command, destructive?),
       status: :denied,
       actions: [
         %{
           name: "plan_shell_command",
           status: :planned_not_executed,
           permission: :command_plan,
           execution: :not_available,
           destructive: destructive?,
           input: %{command: command, source_text: Map.get(params, :source_text)}
         }
       ]
     }}
  end

  defp destructive_command?(command) do
    command
    |> String.downcase()
    |> then(&Regex.match?(~r/\b(rm\s+-|sudo\s+rm|mkfs|diskutil|drop\s+database)\b/, &1))
  end

  defp message(command, destructive?) do
    risk =
      if destructive? do
        "This looks destructive, so it is explicitly blocked."
      else
        "Command execution is not available in v0.01 M3."
      end

    """
    I will not execute shell commands from this milestone.

    Requested command/task:
    #{command}

    #{risk}

    Selected action: plan_shell_command.
    Safe next step: review the command intent, identify affected paths, and wait for the M4 permission gate before any execution path exists.
    """
    |> String.trim()
  end
end
