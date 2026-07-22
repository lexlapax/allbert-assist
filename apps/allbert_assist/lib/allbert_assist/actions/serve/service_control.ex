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

  alias AllbertAssist.Actions.Support.ConfirmationRequest
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
        request_or_deny(operation, params, permission_decision, context)

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

  # M8.14: persist a durable confirmation so `admin confirmations approve <id>`
  # completes the service change (resumed with the same operation + binary).
  defp request_or_deny(operation, params, permission_decision, context) do
    binary = Map.get(params, :binary)

    resume_ref =
      case binary do
        nil -> %{operation: operation}
        value -> %{operation: operation, binary: value}
      end

    attrs = %{
      target_action: %{name: name(), module: inspect(__MODULE__)},
      target_permission: :command_execute,
      target_execution_mode: :service_control,
      params_summary: %{operation: operation, binary: binary || default_binary()},
      resume_params_ref: resume_ref
    }

    case ConfirmationRequest.resolve(permission_decision, attrs, context) do
      {:needs_confirmation, confirmation} ->
        {:ok,
         %{
           message:
             "Service #{operation} is ready for approval. Confirmation request: " <>
               "#{confirmation["id"]}. Nothing was changed.",
           status: :needs_confirmation,
           permission_decision: permission_decision,
           confirmation: confirmation,
           confirmation_id: confirmation["id"],
           actions: [
             action(:needs_confirmation, permission_decision, %{
               operation: operation,
               executed: false,
               confirmation_id: confirmation["id"]
             })
           ]
         }}

      _denied ->
        {:ok,
         %{
           message: permission_decision.reason,
           status: PermissionGate.response_status(permission_decision),
           permission_decision: permission_decision,
           actions: [
             action(:denied, permission_decision, %{operation: operation, executed: false})
           ]
         }}
    end
  end

  defp execute("install", params, permission_decision) do
    binary = Map.get(params, :binary) || default_binary()

    case validate_binary(binary) do
      :ok ->
        File.mkdir_p!(Path.dirname(Service.unit_path()))
        File.write!(Service.unit_path(), Service.render_unit(binary))
        run_all(Service.install_commands(), "install", permission_decision)

      {:error, reason} ->
        {:ok,
         %{
           message: reason,
           status: :error,
           permission_decision: permission_decision,
           actions: [
             action(:error, permission_decision, %{operation: "install", executed: false})
           ]
         }}
    end
  end

  defp execute("uninstall", _params, permission_decision) do
    # The approved action can execute inside the daemon it is uninstalling.
    # Remove the durable unit and reload the manager before the terminal stop;
    # otherwise systemctl/launchctl can kill this process while the unit still
    # exists, leaving a disabled but boot-persistent orphan behind.
    with {:ok, prepare_results} <-
           run_commands(Service.uninstall_prepare_commands(), allow_absent?: true),
         :ok <- remove_unit(),
         {:ok, reload_results} <- run_commands(Service.reload_commands()),
         {:ok, terminal_results} <-
           run_commands(Service.uninstall_terminal_commands(), allow_absent?: true) do
      completed(
        "uninstall",
        permission_decision,
        prepare_results ++ reload_results ++ terminal_results
      )
    else
      {:error, results} when is_list(results) ->
        failed("uninstall", permission_decision, results)

      {:error, reason} ->
        failed("uninstall", permission_decision, [
          %{command: ["remove", Service.unit_path()], exit: 1, output: inspect(reason)}
        ])
    end
  end

  defp remove_unit do
    case File.rm(Service.unit_path()) do
      :ok -> :ok
      {:error, :enoent} -> :ok
      {:error, reason} -> {:error, reason}
    end
  end

  # v0.62 M8.8: the `binary` param is templated into the boot-persistent
  # plist/systemd unit — validate it is an absolute path to an existing regular
  # executable with no shell/XML metacharacters (defense-in-depth; the service
  # unit is also XML-escaped in AllbertAssist.Service).
  defp validate_binary(binary) do
    cond do
      not (is_binary(binary) and Path.type(binary) == :absolute) ->
        {:error, "service install: binary must be an absolute path"}

      Regex.match?(~r/[<>&"'`$;|\s]/, binary) ->
        {:error, "service install: binary path contains disallowed characters"}

      true ->
        # v0.62 M8.18: use lstat (not File.regular?, which follows symlinks) so a
        # symlink can't smuggle in a different target, and require the executable
        # bit — the path is templated into a boot-persistent unit.
        validate_binary_stat(binary)
    end
  end

  defp validate_binary_stat(binary) do
    case File.lstat(binary) do
      {:ok, %File.Stat{type: :symlink}} ->
        {:error, "service install: binary must not be a symlink: #{binary}"}

      {:ok, %File.Stat{type: :regular, mode: mode}} ->
        if Bitwise.band(mode, 0o111) == 0 do
          {:error, "service install: binary is not executable: #{binary}"}
        else
          :ok
        end

      {:ok, _other} ->
        {:error, "service install: binary is not a regular file: #{binary}"}

      {:error, reason} ->
        {:error, "service install: cannot stat #{binary}: #{inspect(reason)}"}
    end
  end

  defp run_all(commands, operation, permission_decision) do
    case run_commands(commands) do
      {:ok, results} -> completed(operation, permission_decision, results)
      {:error, results} -> failed(operation, permission_decision, results)
    end
  end

  defp run_commands(commands, opts \\ []) do
    allow_absent? = Keyword.get(opts, :allow_absent?, false)

    Enum.reduce_while(commands, {:ok, []}, fn {cmd, args}, {:ok, results} ->
      {out, code} = command_runner().(cmd, args, stderr_to_stdout: true)
      result = %{command: [cmd | args], exit: code, output: String.slice(out, 0, 500)}

      if code == 0 or (allow_absent? and already_absent?(out)) do
        {:cont, {:ok, results ++ [result]}}
      else
        {:halt, {:error, results ++ [result]}}
      end
    end)
  end

  defp already_absent?(output) do
    String.match?(
      String.downcase(output),
      ~r/not loaded|not found|could not be found|does not exist/
    )
  end

  defp command_runner do
    Application.get_env(:allbert_assist, __MODULE__, [])
    |> Keyword.get(:command_runner, &System.cmd/3)
  end

  defp completed(operation, permission_decision, results) do
    response(operation, :completed, permission_decision, results)
  end

  defp failed(operation, permission_decision, results) do
    response(operation, :error, permission_decision, results)
  end

  defp response(operation, status, permission_decision, results) do
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
