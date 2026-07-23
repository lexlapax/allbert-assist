defmodule AllbertAssist.Runtime.Audit do
  @moduledoc """
  Runtime-facing audit facade.

  v0.31 keeps the existing markdown audit writers and Security Central audit
  metadata shape intact, but gives runtime actions and future sandbox-trial
  work one module to call. This module does not own policy decisions or
  durable formats; it routes to the existing subsystem writers.
  """

  alias AllbertAssist.Channels.NotifyAudit
  alias AllbertAssist.Execution.Audit, as: ShellAudit
  alias AllbertAssist.Execution.CommandSpec
  alias AllbertAssist.Execution.SkillScriptAudit
  alias AllbertAssist.Execution.SkillScriptSpec
  alias AllbertAssist.External.Audit, as: ExternalAudit
  alias AllbertAssist.External.RequestSpec
  alias AllbertAssist.Mcp.Audit, as: McpAudit
  alias AllbertAssist.Mcp.ServerConfig
  alias AllbertAssist.Packages.Audit, as: PackageAudit
  alias AllbertAssist.Packages.InstallSpec
  alias AllbertAssist.Security.Audit, as: SecurityAudit

  @type audit_kind ::
          :shell_command
          | :skill_script
          | :package_install
          | :external_request
          | :mcp
          | :channel_notify

  @type audit_spec ::
          CommandSpec.t()
          | SkillScriptSpec.t()
          | InstallSpec.t()
          | RequestSpec.t()
          | ServerConfig.t()
          | map()
  @type audit_event ::
          :requested
          | :approved
          | :denied
          | :stale
          | :succeeded
          | :failed
          | :delivered
          | :uncertain
          | :suppressed
          | :timed_out
          | :digest_mismatch
  @type audit_error ::
          {:execution_audit_failed, atom() | {atom(), String.t()}}
          | {:skill_script_audit_failed, atom() | {atom(), String.t()}}
          | {:package_install_audit_failed, atom() | {atom(), String.t()}}
          | {:external_audit_failed, atom() | {atom(), String.t()}}
          | {:channel_notify_audit_failed, atom() | {atom(), String.t()}}

  @doc "Build a redacted Security Central audit event map."
  @spec security_event(map()) :: map()
  defdelegate security_event(decision), to: SecurityAudit, as: :event

  @doc "Append a subsystem audit event through the shared runtime facade."
  @spec append(audit_kind(), audit_event(), audit_spec(), map()) ::
          {:ok, String.t()} | {:error, audit_error()}
  @spec append(audit_kind(), audit_event(), audit_spec(), map(), map()) ::
          {:ok, String.t()} | {:error, audit_error()}
  def append(kind, event, spec, permission_decision, attrs \\ %{})

  def append(:shell_command, event, %CommandSpec{} = spec, permission_decision, attrs) do
    ShellAudit.append(event, spec, permission_decision, attrs)
  end

  def append(:skill_script, event, %SkillScriptSpec{} = spec, permission_decision, attrs) do
    SkillScriptAudit.append(event, spec, permission_decision, attrs)
  end

  def append(:package_install, event, %InstallSpec{} = spec, permission_decision, attrs) do
    PackageAudit.append(event, spec, permission_decision, attrs)
  end

  def append(:external_request, event, %RequestSpec{} = spec, permission_decision, attrs) do
    ExternalAudit.append(event, spec, permission_decision, attrs)
  end

  def append(:mcp, event, %ServerConfig{} = spec, permission_decision, attrs) do
    McpAudit.append(event, spec, permission_decision, attrs)
  end

  def append(:channel_notify, event, attrs, _permission_decision, _extra)
      when is_atom(event) and is_map(attrs) do
    NotifyAudit.append(event, attrs)
  end

  @doc "Return the audit root for a runtime audit kind."
  @spec audit_root(audit_kind()) :: String.t()
  def audit_root(:shell_command), do: ShellAudit.audit_root()
  def audit_root(:skill_script), do: SkillScriptAudit.audit_root()
  def audit_root(:package_install), do: PackageAudit.audit_root()
  def audit_root(:external_request), do: ExternalAudit.audit_root()
  def audit_root(:mcp), do: McpAudit.audit_root()
  def audit_root(:channel_notify), do: NotifyAudit.audit_root()

  @doc "Return the monthly audit path for a runtime audit kind."
  @spec audit_path(audit_kind()) :: String.t()
  @spec audit_path(audit_kind(), DateTime.t()) :: String.t()
  def audit_path(kind, now \\ DateTime.utc_now())
  def audit_path(:shell_command, now), do: ShellAudit.audit_path(now)
  def audit_path(:skill_script, now), do: SkillScriptAudit.audit_path(now)
  def audit_path(:package_install, now), do: PackageAudit.audit_path(now)
  def audit_path(:external_request, now), do: ExternalAudit.audit_path(now)
  def audit_path(:mcp, now), do: McpAudit.audit_path(now)
  def audit_path(:channel_notify, now), do: NotifyAudit.audit_path(now)
end
