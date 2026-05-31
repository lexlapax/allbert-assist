defmodule AllbertBrowser.Actions.ResearchHandoff do
  @moduledoc false

  use AllbertAssist.Action,
    permission: :read_only,
    exposure: :agent,
    execution_mode: :read_only,
    skill_backed?: false,
    confirmation: :not_required,
    plugin_id: "allbert.browser",
    name: "browser_research_handoff",
    description: "Propose a browser research handoff without granting browser authority.",
    category: "browser",
    tags: ["browser", "intent", "handoff"],
    schema: [url: [type: :string, required: false], format: [type: :string, required: false]],
    output_schema: [
      message: [type: :string, required: true],
      status: [type: :atom, required: true],
      actions: [type: {:list, :map}, required: true]
    ]

  @impl true
  def run(params, _context) do
    {:ok,
     %{
       message: "Browser research handoff proposed.",
       status: :completed,
       handoff: %{
         url: Map.get(params, :url) || Map.get(params, "url"),
         format: Map.get(params, :format) || Map.get(params, "format") || "text",
         actions: ["browser_start_session", "browser_navigate", "browser_extract"]
       },
       actions: [
         %{
           name: "browser_research_handoff",
           status: :completed,
           permission: :read_only,
           browser: %{authority: :advisory_only}
         }
       ]
     }}
  end
end
