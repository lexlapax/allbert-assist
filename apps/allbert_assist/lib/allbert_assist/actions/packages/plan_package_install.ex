defmodule AllbertAssist.Actions.Packages.PlanPackageInstall do
  @moduledoc """
  Builds a package-install request plan without invoking a package manager.
  """

  use AllbertAssist.Action,
    permission: :read_only,
    exposure: :agent,
    execution_mode: :package_install_plan,
    skill_backed?: true,
    confirmation: :not_required,
    notes: "Plans package work only; package managers must run through run_package_install.",
    name: "plan_package_install",
    description: "Plan a package installation without executing a package manager.",
    category: "packages",
    tags: ["packages", "package_install", "plan", "safe"],
    schema: [
      manager: [type: :string, required: true, doc: "Package manager name, such as npm."],
      package: [type: :string, required: false, doc: "Package requested by the operator."],
      packages: [type: {:list, :string}, required: false, doc: "Package specs requested."],
      version: [type: :string, required: false, doc: "Optional package version."],
      project_root: [type: :string, required: false, doc: "Optional target project root."],
      cwd: [type: :string, required: false, doc: "Optional target project root alias."],
      save_mode: [type: :string, required: false, doc: "prod, dev, optional, peer, or no-save."],
      source_text: [type: :string, required: false, doc: "The original user prompt."]
    ],
    output_schema: [
      message: [type: :string, required: true],
      status: [type: :atom, required: true],
      permission_decision: [type: :map, required: true],
      actions: [type: {:list, :map}, required: true]
    ]

  alias AllbertAssist.Packages.InstallSpec
  alias AllbertAssist.Security.PermissionGate

  @impl true
  def run(params, context) when is_map(params) do
    permission_decision = PermissionGate.authorize(:read_only, context)

    case InstallSpec.normalize(params, context: context) do
      {:ok, spec} ->
        planned_response(spec, permission_decision)

      {:error, spec} ->
        denied_response(spec, permission_decision)
    end
  end

  def run(_params, context) do
    permission_decision = PermissionGate.authorize(:read_only, context)
    spec = %InstallSpec{policy_decision: :denied, denial_reason: :invalid_params}
    denied_response(spec, permission_decision)
  end

  defp planned_response(spec, permission_decision) do
    plan = InstallSpec.summary(spec)

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
           execution: :not_started,
           install_plan: plan
         }
       ]
     }}
  end

  defp denied_response(spec, permission_decision) do
    plan = InstallSpec.summary(spec)

    {:ok,
     %{
       message: "Package install plan was denied: #{inspect(spec.denial_reason)}.",
       status: :denied,
       permission_decision: permission_decision,
       install_plan: plan,
       actions: [
         %{
           name: "plan_package_install",
           status: :denied,
           permission: :read_only,
           requested_permission: :package_install,
           permission_decision: permission_decision,
           execution: :not_started,
           install_plan: plan,
           denial_reason: spec.denial_reason
         }
       ]
     }}
  end

  defp message(plan) do
    """
    Package install planned, not executed.

    Manager: #{plan.manager}
    Packages: #{Enum.join(plan.packages, ", ")}
    Project root: #{plan.resolved_target_root}
    Dry-run argv: #{Enum.join(plan.dry_run_argv, " ")}
    Execution available: #{plan.execution_available?}

    A confirmed package install must go through run_package_install, Security Central, and the v0.10 package sandbox settings.
    """
    |> String.trim()
  end
end
