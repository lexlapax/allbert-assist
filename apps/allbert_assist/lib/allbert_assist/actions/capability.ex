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
    confirmation: nil,
    notes: nil,
    resumable?: false
  ]

  @type exposure :: :agent | :internal
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
      resumable?: capability.resumable?
    }
    |> put_if_present(:app_id, capability.app_id)
    |> put_if_present(:plugin_id, capability.plugin_id)
  end

  defp put_if_present(map, _key, nil), do: map
  defp put_if_present(map, key, value), do: Map.put(map, key, value)
end
