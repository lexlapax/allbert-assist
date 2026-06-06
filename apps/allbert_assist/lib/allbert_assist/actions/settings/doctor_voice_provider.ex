defmodule AllbertAssist.Actions.Settings.DoctorVoiceProvider do
  @moduledoc false

  use AllbertAssist.Action,
    permission: :read_only,
    exposure: :agent,
    execution_mode: :settings_read,
    skill_backed?: false,
    confirmation: :not_required,
    name: "doctor_voice_provider",
    description: "Check a voice-capable model profile without exposing secrets or audio.",
    category: "settings",
    tags: ["settings", "models", "voice", "doctor", "read_only"],
    schema: [
      profile: [type: :string, required: true]
    ],
    output_schema: [
      message: [type: :string, required: true],
      status: [type: :atom, required: true],
      actions: [type: {:list, :map}, required: true]
    ]

  alias AllbertAssist.Security.PermissionGate
  alias AllbertAssist.Settings.DoctorDiagnostics
  alias AllbertAssist.Settings.VoiceDoctor

  @impl true
  def run(params, context) do
    permission_decision = PermissionGate.authorize(:read_only, context)
    profile = profile(params)

    with true <- PermissionGate.allowed?(permission_decision),
         {:ok, result} <- VoiceDoctor.diagnose(profile, context) do
      {:ok, completed(result, permission_decision)}
    else
      false ->
        {:ok, denied(profile, permission_decision)}

      {:error, _reason} ->
        {:ok, error(permission_decision)}
    end
  end

  defp profile(params),
    do: field(params, :profile) || field(params, :model_profile) || "voice_stt_fake"

  defp completed(result, permission_decision) do
    doctor = Map.drop(result, [:profile, :provider, :provider_type, :model])

    %{
      message: message(result),
      status: :completed,
      permission_decision: permission_decision,
      profile: result.profile,
      provider: result.provider,
      model: result.model,
      doctor: doctor,
      diagnostics: doctor.diagnostics,
      actions: [
        action(:completed, permission_decision, %{
          model_profile: result.profile,
          provider: result.provider,
          provider_type: result.provider_type,
          model: result.model,
          endpoint_kind: doctor.endpoint_kind,
          redacted_host: doctor.redacted_host,
          provider_capabilities: doctor.provider_capabilities,
          provider_deployment_mode: doctor.provider_deployment_mode,
          diagnostics: doctor.diagnostics
        })
      ]
    }
  end

  defp denied(profile, permission_decision) do
    %{
      message: permission_decision.reason,
      status: PermissionGate.response_status(permission_decision),
      permission_decision: permission_decision,
      diagnostics: [],
      actions: [
        action(:denied, permission_decision, %{
          model_profile: profile,
          error: :permission_denied
        })
      ]
    }
  end

  defp error(permission_decision) do
    diagnostic = DoctorDiagnostics.new(:doctor_failed)

    %{
      message: "Voice provider doctor failed.",
      status: :error,
      permission_decision: permission_decision,
      diagnostics: [diagnostic],
      actions: [
        action(:error, permission_decision, %{
          model_profile: "unresolved",
          error: diagnostic.code
        })
      ]
    }
  end

  defp action(status, permission_decision, metadata) do
    %{
      name: "doctor_voice_provider",
      status: status,
      permission: :read_only,
      permission_decision: permission_decision,
      settings_metadata: metadata
    }
  end

  defp message(result) do
    doctor = Map.drop(result, [:profile, :provider, :provider_type, :model])
    availability = availability_text(doctor.model_available)

    [
      "Voice provider profile #{result.profile}: provider=#{result.provider}, model=#{result.model}.",
      "Doctor: endpoint_kind=#{doctor.endpoint_kind}, deployment=#{doctor.provider_deployment_mode}, endpoint_ok=#{doctor.endpoint_ok}, model_available=#{availability}, stt=#{doctor.speech_to_text_supported}, tts=#{doctor.text_to_speech_supported}, host=#{doctor.redacted_host}.",
      diagnostic_text(doctor.diagnostics)
    ]
    |> Enum.reject(&(&1 in [nil, ""]))
    |> Enum.join(" ")
  end

  defp availability_text(true), do: "true"
  defp availability_text(false), do: "false"
  defp availability_text(:unknown), do: "unknown"

  defp diagnostic_text([]), do: ""

  defp diagnostic_text(diagnostics) do
    diagnostics
    |> Enum.map(& &1.message)
    |> Enum.join(" ")
  end

  defp field(map, key) when is_map(map),
    do: Map.get(map, key) || Map.get(map, Atom.to_string(key))

  defp field(_value, _key), do: nil
end
