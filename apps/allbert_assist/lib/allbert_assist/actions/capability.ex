defmodule AllbertAssist.Actions.Capability do
  @moduledoc """
  Canonical action capability metadata for registered Allbert actions.

  This is descriptive metadata used by skill contract validation and operator
  traces. It does not execute actions and does not grant permission.
  """

  @enforce_keys [
    :name,
    :module,
    :permission,
    :exposure,
    :execution_mode,
    :skill_backed?
  ]
  defstruct [
    :name,
    :module,
    :permission,
    :exposure,
    :execution_mode,
    :skill_backed?,
    :app_id,
    :plugin_id,
    retry_safety: :unknown,
    confirmation: nil,
    notes: nil,
    resumable?: false
  ]

  @type exposure :: :agent | :internal
  @reviewed_safe_execution_modes [
    :artifact_doctor,
    :artifact_read,
    :browser_diagnostic,
    :channel_diagnostic,
    :confirmation_read,
    :intent_operator_read,
    :marketplace_browse,
    :marketplace_diagnostic,
    :mcp_discovery,
    :mcp_doctor,
    :mcp_resource_read,
    :memory_index_compile,
    :memory_read,
    :objectives_read,
    :package_install_plan,
    :plan_preview,
    :read_only,
    :resource_grant_read,
    :security_status,
    :self_improvement_discovery,
    :settings_read,
    :skill_validation,
    :template_render,
    :template_validate,
    :unsupported_resource_workflow,
    :workflow_expand
  ]
  @type execution_mode ::
          :read_only
          | :memory_write
          | :memory_promotion
          | :command_plan_only
          | :local_process
          | :unsupported_resource_workflow
          | :external_network_unavailable
          | :req_http
          | :package_install_plan
          | :package_manager_process
          | :online_skill_search
          | :online_skill_detail
          | :online_skill_audit
          | :online_skill_import
          | :direct_skill_import
          | :local_skill_import
          | :artifact_read
          | :artifact_write
          | :artifact_delete
          | :artifact_doctor
          | :settings_read
          | :settings_write
          | :confirmation_decision
          | :confirmation_cleanup
          | :confirmation_read
          | :skill_validation
          | :skill_script_process
          | :skill_write
          | :secret_write
          | :security_status
          | :internal_trace
          | :local_domain
          | :notes_file_write
          | :mcp_doctor
          | :mcp_discovery
          | :mcp_server_connect
          | :mcp_resource_read
          | :mcp_tool_call
          | :self_improvement_discovery
          | :self_improvement_draft
          | :workflow_draft_promotion

  @type t :: %__MODULE__{
          name: String.t(),
          module: module(),
          permission: atom(),
          exposure: exposure(),
          execution_mode: execution_mode(),
          skill_backed?: boolean(),
          app_id: atom() | nil,
          plugin_id: String.t() | nil,
          retry_safety: :safe | :unsafe | :unknown,
          confirmation: nil | atom(),
          notes: nil | String.t(),
          resumable?: boolean()
        }

  @doc "Build capability metadata from a registered Jido action module."
  @spec new(module(), map()) :: t()
  def new(module, attrs) when is_atom(module) and is_map(attrs) do
    %__MODULE__{
      name: module.name(),
      module: module,
      permission: Map.fetch!(attrs, :permission),
      exposure: Map.fetch!(attrs, :exposure),
      execution_mode: Map.fetch!(attrs, :execution_mode),
      skill_backed?: Map.fetch!(attrs, :skill_backed?),
      app_id: Map.get(attrs, :app_id),
      plugin_id: Map.get(attrs, :plugin_id),
      retry_safety: reviewed_retry_safety(attrs),
      confirmation: Map.get(attrs, :confirmation),
      notes: Map.get(attrs, :notes),
      resumable?: Map.get(attrs, :resumable?, false)
    }
  end

  @doc "Return compact, trace-safe capability metadata."
  @spec summary(t()) :: map()
  def summary(%__MODULE__{} = capability) do
    %{
      name: capability.name,
      module: capability.module,
      registered?: true,
      permission: capability.permission,
      exposure: capability.exposure,
      execution_mode: capability.execution_mode,
      skill_backed?: capability.skill_backed?,
      confirmation: capability.confirmation,
      resumable?: capability.resumable?,
      retry_safety: capability.retry_safety
    }
    |> put_if_present(:app_id, capability.app_id)
    |> put_if_present(:plugin_id, capability.plugin_id)
  end

  defp put_if_present(map, _key, nil), do: map
  defp put_if_present(map, key, value), do: Map.put(map, key, value)

  # M2 catalog sweep: only execution modes reviewed as read-only/idempotent
  # upgrade the additive default. Every other or future mode stays unknown
  # unless its action declares an explicit value.
  defp reviewed_retry_safety(%{retry_safety: safety}) when safety in [:safe, :unsafe], do: safety

  defp reviewed_retry_safety(attrs) do
    if Map.get(attrs, :execution_mode) in @reviewed_safe_execution_modes,
      do: :safe,
      else: :unknown
  end
end
