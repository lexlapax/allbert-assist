defmodule AllbertAssist.Actions.FirstModel.InstallOllama do
  @moduledoc """
  Guided Ollama install (v0.62 M4, ADR 0078; M4 Authority Contract).

  Executes the S4-ratified supported upstream install path — `brew install
  ollama` on macOS, the official `install.sh` on Linux — through the existing
  **`:command_execute`** authority (the `:needs_confirmation` safety floor
  means this only runs behind a durable operator confirmation; `InstallSpec`'s
  npm/pip `:package_install` is not applicable). Allbert never re-hosts Ollama.
  The exact command is allowlisted per OS; the trace records the argv and
  outcome without leaking env. Below the hardware floor or on decline, first
  run stays on BYOK — this action is simply not invoked.
  """

  use AllbertAssist.Action,
    permission: :command_execute,
    exposure: :internal,
    execution_mode: :first_model_install,
    skill_backed?: false,
    confirmation: :required,
    resumable?: true,
    name: "install_ollama",
    description:
      "Install the Ollama runtime via the supported upstream path (confirmation-gated).",
    category: "first_model",
    tags: ["first_model", "install", "command_execute", "confirmation"],
    schema: [
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

  @impl true
  def run(params, context) do
    permission_decision = PermissionGate.authorize(:command_execute, context)

    cond do
      # dry_run is a pre-gate PREVIEW: it executes nothing and only echoes the
      # static per-OS allowlisted command, so an operator can see exactly what
      # a confirmed install would run. Real execution is gated below.
      Map.get(params, :dry_run, false) ->
        {cmd, args} = install_command()

        {:ok,
         %{
           message: "Would run: #{cmd} #{Enum.join(args, " ")}",
           status: :completed,
           permission_decision: permission_decision,
           actions: [
             action(:completed, permission_decision, %{command: [cmd | args], executed: false})
           ]
         }}

      not PermissionGate.allowed?(permission_decision) ->
        denied(permission_decision)

      true ->
        run_install(permission_decision)
    end
  end

  # The allowlisted install command per OS (no shell, exact argv).
  @spec install_command() :: {String.t(), [String.t()]}
  def install_command do
    case :os.type() do
      {:unix, :darwin} -> {"brew", ["install", "ollama"]}
      {:unix, _linux} -> {"sh", ["-c", "curl -fsSL https://ollama.com/install.sh | sh"]}
      _other -> {"echo", ["unsupported platform for guided Ollama install"]}
    end
  end

  defp run_install(permission_decision) do
    {cmd, args} = install_command()

    case System.cmd(cmd, args, stderr_to_stdout: true) do
      {out, 0} ->
        {:ok,
         %{
           message: "Ollama install completed.",
           status: :completed,
           permission_decision: permission_decision,
           actions: [
             action(:completed, permission_decision, %{
               command: [cmd | args],
               executed: true,
               output: truncate(out)
             })
           ]
         }}

      {out, code} ->
        {:ok,
         %{
           message: "Ollama install failed (exit #{code}).",
           status: :error,
           permission_decision: permission_decision,
           actions: [
             action(:error, permission_decision, %{
               command: [cmd | args],
               executed: true,
               exit: code,
               output: truncate(out)
             })
           ]
         }}
    end
  end

  defp denied(permission_decision) do
    {:ok,
     %{
       message: permission_decision.reason,
       status: PermissionGate.response_status(permission_decision),
       permission_decision: permission_decision,
       actions: [action(:denied, permission_decision, %{executed: false})]
     }}
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

  defp truncate(text) when is_binary(text), do: String.slice(text, 0, 2_000)
end
