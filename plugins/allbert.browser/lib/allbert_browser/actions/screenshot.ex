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
  alias AllbertBrowser.{Actions, Cache, Session}

  @impl true
  def run(params, context) do
    decision = Actions.authorize(:browser_screenshot, context)
    session_id = Actions.field(params, :session_id)

    max_bytes = Actions.field(params, :max_bytes) || setting("browser.screenshot.max_bytes", 524_288)

    cond do
      not Actions.allowed?(decision) ->
        Actions.denied("browser_screenshot", :browser_screenshot, decision, :permission_denied)

      session_id in [nil, ""] ->
        Actions.denied("browser_screenshot", :browser_screenshot, decision, :missing_session_id)

      true ->
        with {:ok, screenshot} <- Session.screenshot(session_id, max_bytes: max_bytes),
             {:ok, artifact} <- cache_screenshot(session_id, screenshot) do
          completed(decision, session_id, put_cache_ref(screenshot, artifact.ref))
        else
          {:error, reason} ->
            Actions.denied("browser_screenshot", :browser_screenshot, decision, reason)
        end
    end
  end

  defp cache_screenshot(session_id, screenshot) do
    content = Map.get(screenshot, :content) || ""

    Cache.put(session_id, "screenshot", content,
      ext: ".png",
      metadata: %{redacted_credential_inputs?: Map.get(screenshot, :redacted_credential_inputs?)}
    )
  end

  defp put_cache_ref(screenshot, ref) do
    screenshot
    |> Map.put(:screenshot_ref, ref)
    |> Map.delete(:content)
  end

  defp setting(key, fallback) do
    case Settings.get(key) do
      {:ok, value} -> value
      {:error, _reason} -> fallback
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
