defmodule AllbertAssist.Skills.AgentSkillSpec do
  @moduledoc """
  Parsed standard Agent Skill declaration.

  This struct mirrors the external `SKILL.md` format closely. Allbert-specific
  metadata is preserved as inert data in v0.03; it is not execution authority.
  """

  alias AllbertAssist.Skills.Resource

  @enforce_keys [:root_path, :skill_file_path, :name, :description, :body]
  defstruct [
    :root_path,
    :skill_file_path,
    :name,
    :description,
    :license,
    :compatibility,
    :body,
    allowed_tools: [],
    metadata: %{},
    external_fields: %{},
    resources: [],
    diagnostics: []
  ]

  @type diagnostic :: %{
          required(:severity) => :error | :warning | :info,
          required(:code) => atom(),
          required(:message) => String.t(),
          optional(:path) => String.t(),
          optional(:field) => String.t(),
          optional(:value) => term()
        }

  @type t :: %__MODULE__{
          root_path: String.t(),
          skill_file_path: String.t(),
          name: String.t(),
          description: String.t(),
          license: term(),
          compatibility: term(),
          allowed_tools: [term()],
          metadata: map(),
          external_fields: map(),
          body: String.t(),
          resources: [Resource.t()],
          diagnostics: [diagnostic()]
        }
end
