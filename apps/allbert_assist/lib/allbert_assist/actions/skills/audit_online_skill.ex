defmodule AllbertAssist.Actions.Skills.AuditOnlineSkill do
  @moduledoc """
  Audits cached online skill metadata before any import can be considered.
  """

  use Jido.Action,
    name: "audit_online_skill",
    description: "Produce an audit placeholder for cached online skill metadata.",
    category: "skills",
    tags: ["skills", "online", "audit", "read_only"],
    schema: [
      source: [type: :string, required: true, doc: "Configured online skill source."],
      id: [type: :string, required: true, doc: "Source-local skill identifier."]
    ],
    output_schema: [
      message: [type: :string, required: true],
      status: [type: :atom, required: true],
      permission_decision: [type: :map, required: true],
      actions: [type: {:list, :map}, required: true]
    ]

  alias AllbertAssist.Security.PermissionGate

  @impl true
  def run(%{source: source, id: id}, context) do
    permission_decision = PermissionGate.authorize(:read_only, context)
    audit = %{source: String.trim(source), id: String.trim(id), import_enabled?: false}

    {:ok,
     %{
       message: message(audit),
       status: PermissionGate.response_status(permission_decision),
       permission_decision: permission_decision,
       online_skill_audit: audit,
       actions: [
         %{
           name: "audit_online_skill",
           status: :completed,
           permission: :read_only,
           requested_permission: :online_skill_import,
           permission_decision: permission_decision,
           execution: :not_available,
           online_skill_audit: audit
         }
       ]
     }}
  end

  defp message(audit) do
    """
    Online skill audit placeholder created.

    Source: #{audit.source}
    Skill id: #{audit.id}
    Import remains disabled by default until online_skill_import is explicitly enabled and confirmed.
    """
    |> String.trim()
  end
end
