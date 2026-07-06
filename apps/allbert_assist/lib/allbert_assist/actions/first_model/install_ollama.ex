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

  alias AllbertAssist.Actions.Support.ConfirmationRequest
  alias AllbertAssist.Security.PermissionGate

  @install_script_url "https://ollama.com/install.sh"
  @script_placeholder "<tmp>/ollama-install.sh"

  @impl true
  def run(params, context) do
    permission_decision = PermissionGate.authorize(:command_execute, context)

    cond do
      # dry_run is a pre-gate PREVIEW: it executes nothing and only echoes the
      # static per-OS allowlisted command, so an operator can see exactly what
      # a confirmed install would run. Real execution is gated below.
      Map.get(params, :dry_run, false) ->
        dry_run(permission_decision)

      not PermissionGate.allowed?(permission_decision) and not approval_resume?(context) ->
        request_or_deny(permission_decision, context)

      true ->
        run_install(permission_decision)
    end
  end

  @doc "The allowlisted install commands per OS (no shell pipeline, exact argv)."
  @spec install_commands() ::
          {:ok, [{String.t(), [String.t()]}]} | {:error, :unsupported_platform}
  def install_commands do
    case :os.type() do
      {:unix, :darwin} ->
        {:ok, [{"brew", ["install", "ollama"]}]}

      {:unix, _linux} ->
        # v0.62 M8.11 note: this downloads Ollama's official install.sh over TLS
        # and runs it — supply-chain trust in ollama.com, NOT a pinned checksum
        # (the upstream script has no published per-release digest). It executes
        # only behind the :command_execute confirmation. Checksum/signature
        # pinning of third-party installers is a recorded v0.64 M0.a
        # packaging-trust intake item (ADR 0076); until then the operator
        # confirms the exact fetch+exec shown in the confirmation record.
        {:ok,
         [
           {"curl", ["-fsSL", @install_script_url, "-o", @script_placeholder]},
           {"sh", [@script_placeholder]}
         ]}

      _other ->
        {:error, :unsupported_platform}
    end
  end

  @doc false
  @spec install_command() :: {String.t(), [String.t()]} | {:error, :unsupported_platform}
  def install_command do
    case install_commands() do
      {:ok, [command | _rest]} -> command
      {:error, reason} -> {:error, reason}
    end
  end

  defp run_install(permission_decision) do
    case materialized_install_commands() do
      {:ok, commands, cleanup} ->
        results = run_commands(commands)
        cleanup.()

        if Enum.any?(results, &(&1.exit != 0)) do
          failed(permission_decision, results)
        else
          completed(permission_decision, results)
        end

      {:error, reason} ->
        unsupported(permission_decision, reason)
    end
  end

  defp dry_run(permission_decision) do
    case install_commands() do
      {:ok, commands} ->
        {:ok,
         %{
           message: "Would run: #{render_commands(commands)}",
           status: :completed,
           permission_decision: permission_decision,
           actions: [
             action(:completed, permission_decision, %{
               commands: commands_for_trace(commands),
               executed: false
             })
           ]
         }}

      {:error, reason} ->
        unsupported(permission_decision, reason)
    end
  end

  defp materialized_install_commands do
    case install_commands() do
      {:ok, commands} ->
        script_path =
          Path.join(
            System.tmp_dir!(),
            "allbert-ollama-install-#{System.unique_integer([:positive])}.sh"
          )

        materialized =
          Enum.map(commands, fn {cmd, args} ->
            {cmd, Enum.map(args, &if(&1 == @script_placeholder, do: script_path, else: &1))}
          end)

        {:ok, materialized, fn -> File.rm(script_path) end}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp run_commands(commands) do
    commands
    |> Enum.reduce_while([], fn {cmd, args}, acc ->
      {out, code} = System.cmd(cmd, args, stderr_to_stdout: true)
      result = %{command: [cmd | args], exit: code, output: truncate(out)}

      if code == 0 do
        {:cont, [result | acc]}
      else
        {:halt, [result | acc]}
      end
    end)
    |> Enum.reverse()
  end

  defp completed(permission_decision, results) do
    {:ok,
     %{
       message: "Ollama install completed.",
       status: :completed,
       permission_decision: permission_decision,
       actions: [
         action(:completed, permission_decision, %{
           commands: Enum.map(results, & &1.command),
           executed: true,
           results: results
         })
       ]
     }}
  end

  defp failed(permission_decision, results) do
    exit = results |> List.last() |> Map.fetch!(:exit)

    {:ok,
     %{
       message: "Ollama install failed (exit #{exit}).",
       status: :error,
       permission_decision: permission_decision,
       actions: [
         action(:error, permission_decision, %{
           commands: Enum.map(results, & &1.command),
           executed: true,
           results: results
         })
       ]
     }}
  end

  defp unsupported(permission_decision, reason) do
    {:ok,
     %{
       message: "Guided Ollama install is unavailable on this platform: #{reason}.",
       status: :error,
       permission_decision: permission_decision,
       actions: [action(:error, permission_decision, %{executed: false, error: reason})]
     }}
  end

  # M8.14: persist a durable confirmation so `admin confirmations approve <id>`
  # completes the install; genuine denials still return :denied.
  defp request_or_deny(permission_decision, context) do
    attrs = %{
      target_action: %{name: name(), module: inspect(__MODULE__)},
      target_permission: :command_execute,
      target_execution_mode: :first_model_install,
      params_summary: install_summary(),
      resume_params_ref: %{}
    }

    case ConfirmationRequest.resolve(permission_decision, attrs, context) do
      {:needs_confirmation, confirmation} ->
        {:ok,
         %{
           message:
             "Ollama install is ready for approval. Confirmation request: #{confirmation["id"]}. Nothing was installed.",
           status: :needs_confirmation,
           permission_decision: permission_decision,
           confirmation: confirmation,
           confirmation_id: confirmation["id"],
           actions: [
             action(:needs_confirmation, permission_decision, %{
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
           actions: [action(:denied, permission_decision, %{executed: false})]
         }}
    end
  end

  defp install_summary do
    case install_commands() do
      {:ok, commands} -> %{commands: render_commands(commands)}
      _error -> %{}
    end
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

  defp truncate(text) when is_binary(text), do: String.slice(text, 0, 2_000)

  defp render_commands(commands) do
    commands
    |> Enum.map(fn {cmd, args} -> Enum.join([cmd | args], " ") end)
    |> Enum.join(" followed by ")
  end

  defp commands_for_trace(commands), do: Enum.map(commands, fn {cmd, args} -> [cmd | args] end)
end
