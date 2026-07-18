defmodule AllbertAssist.Actions.Voice.CaptureWorkspaceVoice do
  @moduledoc false

  use AllbertAssist.Action,
    permission: :microphone_capture,
    exposure: :internal,
    execution_mode: :live_microphone_capture,
    skill_backed?: false,
    confirmation: :required,
    resumable?: true,
    name: "capture_workspace_voice",
    description: "Request a per-session workspace microphone capture grant.",
    category: "voice",
    tags: ["voice", "microphone", "workspace", "confirmation_required", "internal"],
    schema: [
      capture_id: [type: :string, required: false],
      session_id: [type: :string, required: true],
      thread_id: [type: :string, required: true],
      user_id: [type: :string, required: false]
    ],
    output_schema: [
      message: [type: :string, required: true],
      status: [type: :atom, required: true],
      actions: [type: {:list, :map}, required: true]
    ]

  alias AllbertAssist.Confirmations
  alias AllbertAssist.Confirmations.Origin
  alias AllbertAssist.Maps
  alias AllbertAssist.Resources.ResourceURI
  alias AllbertAssist.Runtime.Redactor
  alias AllbertAssist.Security.PermissionGate
  alias AllbertAssist.Settings

  @permission :microphone_capture

  @impl true
  def run(params, context) when is_map(params) do
    permission_decision = PermissionGate.authorize(@permission, context)

    with :ok <- voice_enabled?(),
         false <- permission_decision.decision == :denied,
         {:ok, capture} <- capture_spec(params, context) do
      if approved_resume?(context) do
        {:ok, completed(capture, permission_decision, context)}
      else
        create_confirmation(capture, context, permission_decision)
      end
    else
      true ->
        {:ok, denied(:permission_denied, permission_decision)}

      {:error, reason} ->
        {:ok, denied(reason, permission_decision)}
    end
  end

  def run(_params, context) do
    permission_decision = PermissionGate.authorize(@permission, context)
    {:ok, denied(:invalid_params, permission_decision)}
  end

  defp create_confirmation(capture, context, permission_decision) do
    attrs = %{
      origin: Origin.from_context(context, "capture_workspace_voice"),
      target_action: %{name: "capture_workspace_voice", module: inspect(__MODULE__)},
      target_permission: @permission,
      target_execution_mode: :live_microphone_capture,
      security_decision: permission_decision,
      source_signal_id: source_signal_id(context),
      source_trace_id: source_trace_id(context),
      runner_metadata: runner_metadata(context),
      params_summary: capture_summary(capture),
      resume_params_ref: capture_resume_params(capture)
    }

    case Confirmations.create(attrs) do
      {:ok, confirmation} ->
        {:ok,
         %{
           message: "Workspace microphone capture needs confirmation.",
           status: :needs_confirmation,
           permission_decision: permission_decision,
           capture: capture_summary(capture),
           confirmation: confirmation,
           confirmation_id: confirmation_id(confirmation),
           actions: [
             action(:needs_confirmation, permission_decision, %{
               capture_id: capture.id,
               resource_uri: capture.resource_uri,
               confirmation_id: confirmation_id(confirmation)
             })
             |> Map.put(:confirmation_metadata, confirmation_metadata(confirmation))
           ]
         }}

      {:error, reason} ->
        {:ok, denied(reason, permission_decision)}
    end
  end

  defp completed(capture, permission_decision, context) do
    output_data =
      capture
      |> Map.take([
        :id,
        :resource_uri,
        :session_id,
        :thread_id,
        :user_id,
        :max_bytes,
        :max_duration_ms,
        :retention_enabled,
        :retention_root
      ])
      |> Map.put(:approved_at_ms, System.monotonic_time(:millisecond))

    %{
      message: "Workspace microphone capture approved.",
      status: :completed,
      permission_decision: permission_decision,
      capture: Redactor.redact_audio_metadata(output_data),
      output_data: output_data,
      actions: [
        action(:completed, permission_decision, %{
          capture_id: capture.id,
          resource_uri: capture.resource_uri,
          confirmation_id: get_in(context, [:confirmation, :id])
        })
      ]
    }
  end

  defp denied(reason, permission_decision) do
    %{
      message: "Workspace microphone capture denied: #{inspect(reason)}.",
      status: :denied,
      error: reason,
      permission_decision: permission_decision,
      actions: [action(:denied, permission_decision, %{error: reason})]
    }
  end

  defp action(status, permission_decision, metadata) do
    %{
      name: "capture_workspace_voice",
      status: status,
      permission: @permission,
      permission_decision: permission_decision,
      voice_metadata: Redactor.redact_audio_metadata(metadata)
    }
  end

  defp capture_spec(params, context) do
    with {:ok, session_id} <- non_empty(field(params, :session_id) || field(context, :session_id)),
         {:ok, thread_id} <- non_empty(field(params, :thread_id) || field(context, :thread_id)),
         {:ok, capture_id} <- capture_id(field(params, :capture_id)),
         {:ok, resource_uri} <- ResourceURI.mic_capture(capture_id),
         {:ok, max_bytes} <- Settings.get("voice.audio.max_bytes"),
         {:ok, max_duration_ms} <- Settings.get("voice.audio.max_duration_ms"),
         {:ok, retention_enabled} <- Settings.get("voice.audio.retention_enabled"),
         {:ok, retention_root} <- Settings.get("voice.audio.retention_root") do
      {:ok,
       %{
         id: capture_id,
         resource_uri: resource_uri,
         session_id: session_id,
         thread_id: thread_id,
         user_id: field(params, :user_id) || field(context, :user_id) || field(context, :actor),
         max_bytes: max_bytes,
         max_duration_ms: max_duration_ms,
         retention_enabled: retention_enabled,
         retention_root: retention_root
       }}
    end
  end

  defp capture_summary(capture) do
    %{
      capture_id: capture.id,
      resource_uri: capture.resource_uri,
      session_id: capture.session_id,
      thread_id: capture.thread_id,
      user_id: capture.user_id,
      max_bytes: capture.max_bytes,
      max_duration_ms: capture.max_duration_ms,
      retention_enabled: capture.retention_enabled,
      retention_root: Redactor.redact_audio_resource_uri(capture.retention_root)
    }
  end

  defp capture_resume_params(capture) do
    %{
      capture_id: capture.id,
      session_id: capture.session_id,
      thread_id: capture.thread_id,
      user_id: capture.user_id
    }
  end

  defp voice_enabled? do
    case Settings.get("voice.enabled") do
      {:ok, true} -> :ok
      {:ok, false} -> {:error, :voice_disabled}
      {:error, reason} -> {:error, reason}
    end
  end

  defp approved_resume?(%{confirmation: %{approved?: true}}), do: true
  defp approved_resume?(%{"confirmation" => %{"approved?" => true}}), do: true
  defp approved_resume?(_context), do: false

  defp capture_id(value) when is_binary(value) do
    value = String.trim(value)

    if value == "" do
      generated_capture_id()
    else
      {:ok, value}
    end
  end

  defp capture_id(_value), do: generated_capture_id()

  defp generated_capture_id do
    token = 12 |> :crypto.strong_rand_bytes() |> Base.url_encode64(padding: false)
    {:ok, "cap_#{token}"}
  end

  defp non_empty(value) when is_binary(value) do
    value = String.trim(value)
    if value == "", do: {:error, :missing_capture_context}, else: {:ok, value}
  end

  defp non_empty(_value), do: {:error, :missing_capture_context}

  defp source_signal_id(context),
    do: field(context, :input_signal_id) || field(context, :source_signal_id)

  defp source_trace_id(context), do: field(context, :trace_id) || field(context, :source_trace_id)

  defp runner_metadata(context) do
    context
    |> Map.take([:actor, :user_id, :operator_id, :channel, :surface, :response_target])
    |> Enum.reject(fn {_key, value} -> is_nil(value) end)
    |> Map.new()
  end

  defp confirmation_id(%{"id" => id}), do: id
  defp confirmation_id(%{id: id}), do: id

  defp confirmation_metadata(confirmation) do
    %{
      id: confirmation_id(confirmation),
      status: field(confirmation, :status),
      target_action: get_in(confirmation, ["target_action", "name"]) || "capture_workspace_voice"
    }
  end

  defp field(map, key) when is_map(map), do: Maps.field_truthy(map, key)
end
