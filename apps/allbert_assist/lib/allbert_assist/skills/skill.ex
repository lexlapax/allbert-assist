defmodule AllbertAssist.Skills.Skill do
  @moduledoc """
  Registry record for a discovered Agent Skill.
  """

  alias AllbertAssist.Skills.AgentSkillSpec
  alias AllbertAssist.Skills.CapabilityContract

  @enforce_keys [
    :name,
    :title,
    :description,
    :source_scope,
    :source_path,
    :trust_status,
    :kind,
    :activation_mode
  ]
  defstruct [
    :name,
    :original_name,
    :title,
    :description,
    :source_scope,
    :source_path,
    :trust_status,
    :kind,
    :activation_mode,
    :plugin_id,
    :spec,
    :capability_contract,
    :contract_validation,
    :permission,
    :status,
    :instructions,
    enabled?: true,
    aliases: [],
    diagnostics: []
  ]

  @type source_scope ::
          :built_in
          | :built_in_legacy
          | :project_native
          | :project_interoperable
          | :app
          | :plugin
          | :user_native
          | :user_interoperable
          | :configured_scan_path
          | :imported_cache

  @type trust_status :: :trusted | :pending

  @type kind ::
          :instruction
          | :workflow
          | :capability_candidate
          | :native_action
          | :external_candidate

  @type t :: %__MODULE__{
          name: String.t(),
          original_name: nil | String.t(),
          title: String.t(),
          description: String.t(),
          source_scope: source_scope(),
          source_path: String.t(),
          trust_status: trust_status(),
          kind: kind(),
          activation_mode: atom(),
          plugin_id: nil | String.t(),
          spec: nil | AgentSkillSpec.t(),
          capability_contract: nil | CapabilityContract.t(),
          contract_validation: nil | map(),
          permission: nil | atom(),
          status: nil | atom(),
          instructions: nil | String.t(),
          enabled?: boolean(),
          aliases: [String.t()],
          diagnostics: [map()]
        }
end
