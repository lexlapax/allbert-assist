defmodule AllbertResearch.App do
  @moduledoc """
  App contract for the shipped research specialist delegate.

  The app contributes inert intent descriptors only. Research execution remains
  behind objective `delegate_agent` steps targeting `research.specialist`.
  """

  use AllbertAssist.App

  @impl true
  def app_id, do: :allbert_research

  @impl true
  def display_name, do: "Research"

  @impl true
  def version, do: "0.46.0"

  @impl true
  def validate(_opts), do: :ok

  def intent_descriptors do
    [
      %{
        app_id: :allbert_research,
        action_name: "research",
        label: "Delegate research",
        examples: [
          "research supply chain resilience",
          "summarize the research on local-first agents"
        ],
        synonyms: [
          "research",
          "research topic",
          "summarize research",
          "delegate research"
        ],
        required_slots: [],
        handoff_required?: true,
        capability: inert_capability()
      },
      %{
        app_id: :allbert_research,
        action_name: "summarize_url",
        label: "Delegate URL summary",
        examples: [
          "research https://example.com and summarize",
          "summarize https://example.com with research"
        ],
        synonyms: [
          "research url",
          "summarize url",
          "summarize page",
          "delegate url summary"
        ],
        required_slots: [],
        handoff_required?: true,
        capability: inert_capability()
      }
    ]
  end

  defp inert_capability do
    %{
      registered?: false,
      permission: :read_only,
      exposure: :agent,
      execution_mode: :read_only,
      confirmation: :not_required
    }
  end
end
