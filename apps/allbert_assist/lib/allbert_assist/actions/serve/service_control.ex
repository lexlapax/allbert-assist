defmodule AllbertAssist.Actions.Serve.ServiceControl do
  @moduledoc """
  Install / uninstall the per-user `allbert serve` OS service (v0.62 M5, Locked
  Decision 11). Effectful (writes a unit/plist + runs launchctl/systemctl), so
  it carries `:command_execute` and `confirmation: :required` — the safety
  floor means it only runs behind a durable operator confirmation, and it is in
  the `packaging-no-authority-change-001` allowance as a named internal action
  (not an off-spine shell path). Grants no authority beyond what a checkout
  `mix phx.server` already has; the service just makes it managed.
  """

  use AllbertAssist.Action,
    permission: :command_execute,
    exposure: :internal,
    execution_mode: :service_control,
    skill_backed?: false,
    confirmation: :required,
    resumable?: true,
    name: "service_control",
    description:
      "Install or uninstall the per-user allbert serve OS service (confirmation-gated).",
    category: "serve",
    tags: ["serve", "service", "command_execute", "confirmation"],
    schema: [
      operation: [type: :string, required: true],
      binary: [type: :string, required: false],
      dry_run: [type: :boolean, required: false],
      user_id: [type: :string, required: false]
    ],
    output_schema: [
      message: [type: :string, required: true],
      status: [type: :atom, required: true],
      permission_decision: [type: :map, required: true],
      actions: [type: {:list, :map}, required: true]
    ]

  alias AllbertAssist.Security.PermissionGate
  alias AllbertAssist.Service

  @impl true
  def run(params, context) do
    permission_decision = PermissionGate.authorize(:command_execute, context)
    operation = Map.get(params, :operation, "status")

    cond do
      operation not in ["install", "uninstall"] ->
        {:ok,
         %{
           message: "Unknown service operation: #{operation}. Use install or uninstall.",
           status: :error,
           permission_decision: permission_decision,
           actions: [action(:error, permission_decision, %{operation: operation})]
         }}

      # dry_run previews the commands (executes nothing) before the gate.
      Map.get(params, :dry_run, false) ->
        {:ok,
         %{
           message: "Would #{operation} the #{Service.platform()} service.",
           status: :completed,
           permission_decision: permission_decision,
           actions: [
             action(:completed, permission_decision, %{
               operation: operation,
               commands: commands(operation),
               executed: false
             })
           ]
         }}

      not PermissionGate.allowed?(permission_decision) and not approval_resume?(context) ->
        {:ok,
         %{
           message: permission_decision.reason,
           status: PermissionGate.response_status(permission_decision),
           permission_decision: permission_decision,
           actions: [
             action(:denied, permission_decision, %{operation: operation, executed: false})
           ]
         }}

      not Service.manager_available?() ->
        {:ok,
         %{
           message:
             "No user service manager is reachable — run `allbert serve` in the " <>
               "foreground instead (headless/WSL2 degrade).",
           status: :error,
           permission_decision: permission_decision,
           actions: [
             action(:error, permission_decision, %{operation: operation, executed: false})
           ]
         }}

      true ->
        execute(operation, params, permission_decision)
    end
  end

  defp execute("install", params, permission_decision) do
    binary = Map.get(params, :binary) || default_binary()
    File.mkdir_p!(Path.dirname(Service.unit_path()))
    File.write!(Service.unit_path(), Service.render_unit(binary))
    run_all(Service.install_commands(), "install", permission_decision)
  end

  defp execute("uninstall", _params, permission_decision) do
    result = run_all(Service.uninstall_commands(), "uninstall", permission_decision)
    File.rm(Service.unit_path())
    result
  end

  defp run_all(commands, operation, permission_decision) do
    results =
      Enum.map(commands, fn {cmd, args} ->
        {out, code} = System.cmd(cmd, args, stderr_to_stdout: true)
        %{command: [cmd | args], exit: code, output: String.slice(out, 0, 500)}
      end)

    failed? = Enum.any?(results, &(&1.exit != 0))
    status = if failed?, do: :error, else: :completed

    {:ok,
     %{
       message: "Service #{operation} #{status}.",
       status: status,
       permission_decision: permission_decision,
       actions: [
         action(status, permission_decision, %{
           operation: operation,
           executed: true,
           results: results
         })
       ]
     }}
  end

  defp commands("install"), do: Enum.map(Service.install_commands(), &Tuple.to_list/1)
  defp commands("uninstall"), do: Enum.map(Service.uninstall_commands(), &Tuple.to_list/1)

  defp default_binary do
    System.get_env("ALLBERT_BINARY") ||
      Path.join([System.get_env("RELEASE_ROOT") || File.cwd!(), "bin", "allbert"])
  end

  defp approval_resume?(context) do
    get_in(context, [:confirmation, :approved?]) == true ||
      get_in(context, ["confirmation", "approved?"]) == true
  end

  defp action(status, permission_decision, metadata) do
    Map.merge(
      %{
        name: name(),
        status: status,
        permission: :command_execute,
        permission_decision: permission_decision
      },
      metadata
    )
  end
end
