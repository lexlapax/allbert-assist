defmodule AllbertAssist.Actions.Packages.PlanPackageInstall do
  @moduledoc """
  Builds a package-install request plan without invoking a package manager.
  """

  use Jido.Action,
    name: "plan_package_install",
    description: "Plan a package installation without executing a package manager.",
    category: "packages",
    tags: ["packages", "package_install", "plan", "safe"],
    schema: [
      manager: [type: :string, required: true, doc: "Package manager name, such as npm."],
      package: [type: :string, required: true, doc: "Package name requested by the operator."],
      version: [type: :string, required: false, doc: "Optional package version or range."],
      project_root: [type: :string, required: false, doc: "Optional target project root."],
      source_text: [type: :string, required: false, doc: "The original user prompt."]
    ],
    output_schema: [
      message: [type: :string, required: true],
      status: [type: :atom, required: true],
      permission_decision: [type: :map, required: true],
      actions: [type: {:list, :map}, required: true]
    ]

  alias AllbertAssist.Security.PermissionGate

  @impl true
  def run(%{manager: manager, package: package} = params, context) do
    permission_decision = PermissionGate.authorize(:read_only, context)
    plan = plan(manager, package, params)

    {:ok,
     %{
       message: message(plan),
       status: PermissionGate.response_status(permission_decision),
       permission_decision: permission_decision,
       install_plan: plan,
       actions: [
         %{
           name: "plan_package_install",
           status: :planned_not_executed,
           permission: :read_only,
           requested_permission: :package_install,
           permission_decision: permission_decision,
           execution: :not_available,
           install_plan: plan
         }
       ]
     }}
  end

  defp plan(manager, package, params) do
    %{
      manager: String.trim(manager),
      package: String.trim(package),
      version: trim_optional(Map.get(params, :version)),
      project_root: trim_optional(Map.get(params, :project_root)),
      source_text: Map.get(params, :source_text),
      next_action: "run_package_install"
    }
  end

  defp message(plan) do
    target =
      [plan.package, plan.version]
      |> Enum.reject(&is_nil/1)
      |> Enum.join("@")

    """
    Package install planned, not executed.

    Target: #{target}
    Manager: #{plan.manager}
    Project root: #{plan.project_root || "not specified"}

    A confirmed package install must go through run_package_install, Security Central, and the v0.10 package sandbox settings.
    """
    |> String.trim()
  end

  defp trim_optional(value) when is_binary(value) do
    case String.trim(value) do
      "" -> nil
      trimmed -> trimmed
    end
  end

  defp trim_optional(_value), do: nil
end
