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
      permission_decision: [type: :map, required: true],
      actions: [type: {:list, :map}, required: true]
    ]

  alias AllbertAssist.Security.PermissionGate

  @impl true
  def run(%{command: command} = params, context) do
    command = String.trim(command)
    destructive? = destructive_command?(command)
    plan_decision = PermissionGate.authorize(:command_plan, context)
    execute_decision = PermissionGate.authorize(:command_execute, context)

    {:ok,
     %{
       message: message(command, destructive?, execute_decision),
       status: PermissionGate.response_status(execute_decision),
       permission_decision: execute_decision,
       actions: [
         %{
           name: "plan_shell_command",
           status: :planned_not_executed,
           permission: :command_plan,
           permission_decision: plan_decision,
           requested_permission: :command_execute,
           requested_permission_decision: execute_decision,
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

  defp message(command, destructive?, execute_decision) do
    risk =
      if destructive? do
        "This looks destructive, so it is explicitly blocked."
      else
        "This planning action does not execute commands. Confirmed shell execution must route through the registered run_shell_command action and Security Central."
      end

    """
    I will not execute shell commands from this planning response.

    Requested command/task:
    #{command}

    #{risk}
    Permission gate decision: #{execute_decision.decision} for command_execute.

    Selected action: plan_shell_command.
    Safe next step: review the command intent, identify affected paths, and keep execution blocked until a future confirmed execution path exists.
    """
    |> String.trim()
  end
end
