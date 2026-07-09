defmodule AllbertAssist.Actions.Serve.ServeHealth do
  @moduledoc """
  Read the runtime health snapshot + service posture (v0.62 M5). Read-only:
  the same `AllbertAssist.Health` snapshot the `/health` route serves, plus the
  per-user service unit path and whether a service manager is reachable. No
  authority, no secret.
  """

  use AllbertAssist.Action,
    permission: :read_only,
    exposure: :internal,
    execution_mode: :settings_read,
    skill_backed?: false,
    confirmation: :not_required,
    name: "serve_health",
    description: "Runtime/web/channels health snapshot and per-user service posture.",
    category: "serve",
    tags: ["serve", "health", "read_only", "operator"],
    schema: [surface: [type: :string, required: false]],
    output_schema: [
      message: [type: :string, required: true],
      status: [type: :atom, required: true],
      permission_decision: [type: :map, required: true],
      health: [type: :map, required: true],
      actions: [type: {:list, :map}, required: true]
    ]

  alias AllbertAssist.Actions.Operator.Support
  alias AllbertAssist.Health
  alias AllbertAssist.Service

  @impl true
  def run(_params, context) do
    Support.read_only(name(), context, fn permission_decision ->
      snapshot = Health.snapshot()

      report =
        Map.merge(snapshot, %{
          service_platform: Service.platform(),
          service_unit_path: Service.unit_path(),
          service_manager_available: Service.manager_available?()
        })

      {:ok,
       %{
         message:
           "Health: #{snapshot.status}. service_platform=#{report.service_platform} " <>
             "service_manager_available=#{report.service_manager_available} " <>
             "service_unit_path=#{report.service_unit_path}",
         surface_payload:
           "Health: #{snapshot.status}. service_platform=#{report.service_platform} " <>
             "service_manager_available=#{report.service_manager_available}",
         status: :completed,
         permission_decision: permission_decision,
         health: report,
         actions: [Support.action(name(), :completed, permission_decision, report)]
       }}
    end)
  end
end
