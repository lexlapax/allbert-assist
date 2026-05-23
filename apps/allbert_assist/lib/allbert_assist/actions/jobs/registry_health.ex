defmodule AllbertAssist.Actions.Jobs.RegistryHealth do
  @moduledoc """
  Read-only registry health summary for scheduled job templates.
  """

  use AllbertAssist.Action,
    permission: :read_only,
    exposure: :internal,
    execution_mode: :read_only,
    skill_backed?: false,
    confirmation: :not_required,
    name: "registry_health",
    description: "Summarize action, skill, and settings registry health.",
    category: "jobs",
    tags: ["jobs", "registry", "read_only"],
    schema: [],
    output_schema: [
      message: [type: :string, required: true],
      status: [type: :atom, required: true],
      permission_decision: [type: :map, required: true],
      registry_health: [type: :map, required: true],
      actions: [type: {:list, :map}, required: true]
    ]

  alias AllbertAssist.Actions.Registry
  alias AllbertAssist.Security.PermissionGate
  alias AllbertAssist.Settings
  alias AllbertAssist.Skills

  @impl true
  def run(_params, context) do
    permission_decision = PermissionGate.authorize(:read_only, context)
    health = health(context)

    {:ok,
     %{
       message: message(health),
       status: PermissionGate.response_status(permission_decision),
       permission_decision: permission_decision,
       registry_health: health,
       actions: [
         %{
           name: "registry_health",
           status: :completed,
           permission: :read_only,
           permission_decision: permission_decision,
           registry_health: health
         }
       ]
     }}
  end

  defp health(context) do
    skills = ok_list(Skills.list(context))
    diagnostics = ok_list(Skills.diagnostics(context))
    settings = ok_list(Settings.list())

    %{
      actions: %{
        total: length(Registry.names()),
        agent: length(Registry.agent_modules()),
        internal: length(Registry.internal_capabilities()),
        duplicate_names: Registry.duplicate_names()
      },
      skills: %{
        enabled: length(skills),
        diagnostics: length(diagnostics)
      },
      settings: %{
        resolved: length(settings),
        writable: Enum.count(settings, & &1.writable?)
      }
    }
  end

  defp message(health) do
    """
    Registry health:
    Actions: #{health.actions.total} total, #{health.actions.agent} agent, #{health.actions.internal} internal
    Skills: #{health.skills.enabled} enabled, #{health.skills.diagnostics} diagnostics
    Settings: #{health.settings.resolved} resolved, #{health.settings.writable} writable
    """
    |> String.trim()
  end

  defp ok_list({:ok, values}) when is_list(values), do: values
  defp ok_list(_other), do: []
end
