defmodule AllbertAssist.Actions.Packages.RunPackageInstall do
  @moduledoc """
  Confirmed package-install action boundary.

  M1 registers the boundary and keeps it inert. M3 replaces the inert response
  with the npm adapter after confirmation, Settings Central checks, and audit
  recording are in place.
  """

  use Jido.Action,
    name: "run_package_install",
    description: "Run a confirmed package manager install through v0.10 policy.",
    category: "packages",
    tags: ["packages", "package_install", "execution"],
    schema: [
      manager: [type: :string, required: true, doc: "Package manager name, such as npm."],
      package: [type: :string, required: true, doc: "Package name requested by the operator."],
      version: [type: :string, required: false, doc: "Optional package version or range."],
      project_root: [type: :string, required: false, doc: "Target project root."],
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
    permission_decision = PermissionGate.authorize(:package_install, context)
    request = request(manager, package, params)

    {:ok,
     %{
       message: message(request, permission_decision),
       status: PermissionGate.response_status(permission_decision),
       permission_decision: permission_decision,
       package_install_request: request,
       actions: [
         %{
           name: "run_package_install",
           status: :not_executed,
           permission: :package_install,
           permission_decision: permission_decision,
           execution: :not_available,
           package_install_request: request
         }
       ]
     }}
  end

  defp request(manager, package, params) do
    %{
      manager: String.trim(manager),
      package: String.trim(package),
      version: trim_optional(Map.get(params, :version)),
      project_root: trim_optional(Map.get(params, :project_root)),
      source_text: Map.get(params, :source_text)
    }
  end

  defp message(request, permission_decision) do
    """
    Package install request recorded, not executed by M1.

    Package: #{request.package}
    Manager: #{request.manager}
    Permission gate decision: #{permission_decision.decision} for package_install.

    M3 wires this boundary to the confirmed npm adapter.
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
