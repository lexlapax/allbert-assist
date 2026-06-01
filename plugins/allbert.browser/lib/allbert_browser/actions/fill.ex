defmodule AllbertBrowser.Actions.Fill do
  @moduledoc false

  use AllbertAssist.Action,
    permission: :browser_form_fill,
    exposure: :internal,
    execution_mode: :browser_session,
    skill_backed?: false,
    confirmation: :required,
    resumable?: true,
    plugin_id: "allbert.browser",
    name: "browser_fill",
    description: "Fill a browser form field after opt-in and confirmation.",
    category: "browser",
    tags: ["browser", "form", "confirmation_required"],
    schema: [
      session_id: [type: :string, required: true],
      selector: [type: :string, required: true],
      value: [type: :string, required: false],
      value_preview: [type: :string, required: false]
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
    decision = Actions.authorize(:browser_form_fill, context)
    session_id = Actions.field(params, :session_id)
    selector = Actions.field(params, :selector)

    cond do
      not enabled?() ->
        Actions.denied("browser_fill", :browser_form_fill, decision, :browser_form_fill_disabled)

      decision.decision == :denied ->
        Actions.denied("browser_fill", :browser_form_fill, decision, :permission_denied)

      session_id in [nil, ""] ->
        Actions.denied("browser_fill", :browser_form_fill, decision, :missing_session_id)

      selector in [nil, ""] ->
        Actions.denied("browser_fill", :browser_form_fill, decision, :missing_selector)

      Actions.approval_resume?(context) ->
        fill(params, decision, session_id, selector)

      true ->
        Actions.confirmation(
          "browser_fill",
          :browser_form_fill,
          :browser_session,
          %{
            session_id: session_id,
            selector: selector,
            value_preview: value_preview(params),
            value_redacted?: true
          },
          Map.merge(params, %{action: "browser_fill", value: "[REDACTED]"}),
          context,
          decision
        )
    end
  end

  defp fill(params, decision, session_id, selector) do
    opts = [value: Actions.field(params, :value), value_preview: value_preview(params)]

    case Session.fill(session_id, selector, opts) do
      {:ok, fill} ->
        {:ok,
         %{
           message: "Browser form fill completed.",
           status: :completed,
           session_id: session_id,
           fill: fill,
           permission_decision: decision,
           actions: [
             Actions.action("browser_fill", :completed, :browser_form_fill, decision, %{
               session_id: session_id,
               selector: selector,
               value_redacted?: true
             })
           ]
         }}

      {:error, reason} ->
        Actions.denied("browser_fill", :browser_form_fill, decision, reason)
    end
  end

  defp enabled? do
    case Settings.get("browser.form_fill.enabled") do
      {:ok, true} -> true
      _other -> false
    end
  end

  defp value_preview(params) do
    (Actions.field(params, :value_preview) || "[REDACTED]")
    |> to_string()
    |> String.slice(0, 200)
  end
end
