defmodule AllbertAssist.Actions.Voice.StartLocalRuntime do
  @moduledoc false

  use AllbertAssist.Action,
    permission: :voice_local_runtime_manage,
    exposure: :internal,
    execution_mode: :voice_local_runtime,
    skill_backed?: false,
    confirmation: :not_required,
    name: "voice_local_runtime_start",
    description: "Start the Allbert-owned loopback local voice runtime.",
    category: "voice",
    tags: ["voice", "local_runtime", "server", "internal"],
    schema: [],
    output_schema: [
      message: [type: :string, required: true],
      status: [type: :atom, required: true],
      actions: [type: {:list, :map}, required: true]
    ]

  alias AllbertAssist.Runtime.Redactor
  alias AllbertAssist.Security.PermissionGate
  alias AllbertAssist.Voice.LocalRuntime.Config
  alias AllbertAssist.Voice.LocalRuntime.Server

  @permission :voice_local_runtime_manage

  @impl true
  def run(_params, context) do
    permission_decision = PermissionGate.authorize(@permission, context)

    cond do
      permission_decision.decision == :denied ->
        {:ok, stopped(permission_decision, :permission_denied)}

      permission_decision.decision == :needs_confirmation ->
        {:ok, stopped(permission_decision, :permission_needs_confirmation)}

      true ->
        start_runtime(permission_decision)
    end
  end

  defp start_runtime(permission_decision) do
    config = Config.build()

    if config.enabled? do
      case Server.start(config) do
        {:ok, %{pid: pid, config: config, token_path: token_path}} ->
          {:ok,
           %{
             message: "Allbert local voice runtime listening on #{config.base_url}.",
             status: :running,
             base_url: config.base_url,
             bind: "127.0.0.1",
             port: config.port,
             pid: inspect(pid),
             token_path: token_path,
             permission_decision: permission_decision,
             actions: [action(:running, permission_decision, config, token_path)]
           }}

        {:error, reason} ->
          {:ok,
           %{
             message:
               "Allbert local voice runtime failed to start: #{inspect(Redactor.redact(reason))}",
             status: :failed,
             error: Redactor.redact(reason),
             permission_decision: permission_decision,
             actions: [action(:failed, permission_decision, config, nil)]
           }}
      end
    else
      {:ok,
       %{
         message: "Allbert local voice runtime is disabled in Settings Central.",
         status: :failed,
         error: :voice_local_runtime_disabled,
         permission_decision: permission_decision,
         actions: [action(:failed, permission_decision, config, nil)]
       }}
    end
  end

  defp stopped(permission_decision, reason) do
    %{
      message: permission_decision.reason,
      status: PermissionGate.response_status(permission_decision),
      error: reason,
      permission_decision: permission_decision,
      actions: [
        %{
          name: "voice_local_runtime_start",
          status: PermissionGate.response_status(permission_decision),
          permission: @permission,
          permission_decision: permission_decision
        }
      ]
    }
  end

  defp action(status, permission_decision, config, token_path) do
    %{
      name: "voice_local_runtime_start",
      status: status,
      permission: @permission,
      permission_decision: permission_decision,
      voice_local_runtime: %{
        enabled?: config.enabled?,
        base_url: config.base_url,
        bind: "127.0.0.1",
        port: config.port,
        ollama_base_url: config.ollama_base_url,
        ollama_stt_model: config.ollama_stt_model,
        stt_model_alias: config.stt_model_alias,
        tts_model_alias: config.tts_model_alias,
        token_path: token_path
      }
    }
  end
end
