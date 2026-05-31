defmodule AllbertBrowser.Actions.CloseSession do
  @moduledoc false

  use AllbertAssist.Action,
    permission: :browser_extract,
    exposure: :internal,
    execution_mode: :browser_session,
    skill_backed?: false,
    confirmation: :not_required,
    plugin_id: "allbert.browser",
    name: "browser_close_session",
    description: "Close an active browser session.",
    category: "browser",
    tags: ["browser", "session"],
    schema: [session_id: [type: :string, required: true]],
    output_schema: [
      message: [type: :string, required: true],
      status: [type: :atom, required: true],
      actions: [type: {:list, :map}, required: true]
    ]

  alias AllbertBrowser.{Actions, Session}

  @impl true
  def run(params, context) do
    decision = Actions.authorize(:browser_extract, context)
    session_id = Actions.field(params, :session_id)

    cond do
      not Actions.allowed?(decision) ->
        Actions.denied("browser_close_session", :browser_extract, decision, :permission_denied)

      session_id in [nil, ""] ->
        Actions.denied("browser_close_session", :browser_extract, decision, :missing_session_id)

      true ->
        case Session.close(session_id) do
          :ok -> completed(decision, session_id)
          {:error, reason} -> Actions.denied("browser_close_session", :browser_extract, decision, reason)
        end
    end
  end

  defp completed(decision, session_id) do
    {:ok,
     %{
       message: "Browser session closed.",
       status: :completed,
       session_id: session_id,
       permission_decision: decision,
       actions: [
         Actions.action("browser_close_session", :completed, :browser_extract, decision, %{
           session_id: session_id
         })
       ]
     }}
  end
end
