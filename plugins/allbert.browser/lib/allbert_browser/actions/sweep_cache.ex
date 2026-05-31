defmodule AllbertBrowser.Actions.SweepCache do
  @moduledoc false

  use AllbertAssist.Action,
    permission: :browser_extract,
    exposure: :internal,
    execution_mode: :local,
    skill_backed?: false,
    confirmation: :not_required,
    plugin_id: "allbert.browser",
    name: "browser_sweep_cache",
    description: "Sweep expired browser cache artifacts.",
    category: "browser",
    tags: ["browser", "cache"],
    schema: [],
    output_schema: [
      message: [type: :string, required: true],
      status: [type: :atom, required: true],
      actions: [type: {:list, :map}, required: true]
    ]

  alias AllbertBrowser.{Actions, Cache}

  @impl true
  def run(_params, context) do
    decision = Actions.authorize(:browser_extract, context)

    if Actions.allowed?(decision) do
      {:ok, removed} = Cache.sweep_expired()

      {:ok,
       %{
         message: "Browser cache swept.",
         status: :completed,
         removed: removed,
         permission_decision: decision,
         actions: [
           Actions.action("browser_sweep_cache", :completed, :browser_extract, decision, %{
             removed: removed
           })
         ]
       }}
    else
      Actions.denied("browser_sweep_cache", :browser_extract, decision, :permission_denied)
    end
  end
end
