defmodule AllbertAssist.Actions.Voice.LocalRuntimeDoctor do
  @moduledoc false

  use AllbertAssist.Action,
    permission: :read_only,
    exposure: :internal,
    execution_mode: :settings_read,
    skill_backed?: false,
    confirmation: :not_required,
    name: "voice_local_runtime_doctor",
    description:
      "Inspect the Allbert-owned local voice runtime and its configured local backends.",
    category: "voice",
    tags: ["voice", "local_runtime", "doctor", "internal"],
    schema: [],
    output_schema: [
      message: [type: :string, required: true],
      status: [type: :atom, required: true],
      doctor: [type: :map, required: true],
      actions: [type: {:list, :map}, required: true]
    ]

  alias AllbertAssist.Security.PermissionGate
  alias AllbertAssist.Voice.LocalRuntime

  @impl true
  def run(_params, context) do
    permission_decision = PermissionGate.authorize(:voice_local_runtime_manage, context)
    doctor = LocalRuntime.doctor()

    {:ok,
     %{
       message: message(doctor),
       status: :completed,
       doctor: doctor,
       permission_decision: permission_decision,
       actions: [
         %{
           name: "voice_local_runtime_doctor",
           status: :completed,
           permission: :read_only,
           permission_decision: permission_decision,
           voice_local_runtime: doctor
         }
       ]
     }}
  rescue
    exception ->
      {:ok,
       %{
         message: "Allbert local voice runtime doctor failed.",
         status: :failed,
         error: {exception.__struct__, Exception.message(exception)},
         actions: [
           %{
             name: "voice_local_runtime_doctor",
             status: :failed,
             permission: :read_only
           }
         ]
       }}
  end

  defp message(%{enabled?: true, diagnostic_codes: []}),
    do: "Allbert local voice runtime is enabled and local backends are available."

  defp message(%{enabled?: false}),
    do: "Allbert local voice runtime is disabled in Settings Central."

  defp message(_doctor),
    do: "Allbert local voice runtime is configured but one or more local backends need attention."
end
