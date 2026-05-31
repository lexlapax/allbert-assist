defmodule AllbertBrowser.Actions.Screenshot do
  @moduledoc false

  use AllbertAssist.Action,
    permission: :browser_screenshot,
    exposure: :internal,
    execution_mode: :browser_session,
    skill_backed?: false,
    confirmation: :not_required,
    plugin_id: "allbert.browser",
    name: "browser_screenshot",
    description: "Capture a bounded browser screenshot with credential-input redaction.",
    category: "browser",
    tags: ["browser", "screenshot", "read_only"],
    schema: [
      session_id: [type: :string, required: true],
      max_bytes: [type: :integer, required: false]
    ],
    output_schema: [
      message: [type: :string, required: true],
      status: [type: :atom, required: true],
      actions: [type: {:list, :map}, required: true]
    ]

  alias AllbertAssist.Settings
  alias AllbertBrowser.{Actions, Session}

  @impl true
  def run(params, context) do
    decision = Actions.authorize(:browser_screenshot, context)
    session_id = Actions.field(params, :session_id)

    max_bytes =
      Actions.field(params, :max_bytes) || elem(Settings.get("browser.screenshot.max_bytes"), 1)

    cond do
      not Actions.allowed?(decision) ->
        Actions.denied("browser_screenshot", :browser_screenshot, decision, :permission_denied)

      session_id in [nil, ""] ->
        Actions.denied("browser_screenshot", :browser_screenshot, decision, :missing_session_id)

      true ->
        case Session.screenshot(session_id, max_bytes: max_bytes) do
          {:ok, screenshot} ->
            completed(decision, session_id, screenshot)

          {:error, reason} ->
            Actions.denied("browser_screenshot", :browser_screenshot, decision, reason)
        end
    end
  end

  defp completed(decision, session_id, screenshot) do
    {:ok,
     %{
       message: "Browser screenshot completed.",
       status: :completed,
       session_id: session_id,
       screenshot: screenshot,
       permission_decision: decision,
       actions: [
         Actions.action("browser_screenshot", :completed, :browser_screenshot, decision, %{
           session_id: session_id,
           screenshot_ref: screenshot.screenshot_ref,
           redacted_credential_inputs?: screenshot.redacted_credential_inputs?
         })
       ]
     }}
  end
end
