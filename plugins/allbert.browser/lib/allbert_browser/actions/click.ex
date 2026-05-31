defmodule AllbertBrowser.Actions.Click do
  @moduledoc false

  use AllbertAssist.Action,
    permission: :browser_interact,
    exposure: :internal,
    execution_mode: :browser_session,
    skill_backed?: false,
    confirmation: :required,
    resumable?: true,
    plugin_id: "allbert.browser",
    name: "browser_click",
    description: "Click a browser element after operator confirmation.",
    category: "browser",
    tags: ["browser", "click", "confirmation_required"],
    schema: [
      session_id: [type: :string, required: true],
      selector: [type: :string, required: true],
      visible_label_preview: [type: :string, required: false]
    ],
    output_schema: [
      message: [type: :string, required: true],
      status: [type: :atom, required: true],
      actions: [type: {:list, :map}, required: true]
    ]

  alias AllbertBrowser.{Actions, Session}

  @impl true
  def run(params, context) do
    decision = Actions.authorize(:browser_interact, context)
    session_id = Actions.field(params, :session_id)
    selector = Actions.field(params, :selector)
    label_preview = params |> Actions.field(:visible_label_preview, "") |> preview()

    cond do
      decision.decision == :denied ->
        Actions.denied("browser_click", :browser_interact, decision, :permission_denied)

      session_id in [nil, ""] ->
        Actions.denied("browser_click", :browser_interact, decision, :missing_session_id)

      selector in [nil, ""] ->
        Actions.denied("browser_click", :browser_interact, decision, :missing_selector)

      not Actions.approval_resume?(context) ->
        Actions.confirmation(
          "browser_click",
          :browser_interact,
          :browser_session,
          %{
            session_id: session_id,
            selector: selector,
            visible_label_preview: label_preview
          },
          Map.merge(params, %{action: "browser_click", visible_label_preview: label_preview}),
          context,
          decision
        )

      true ->
        click(decision, session_id, selector, label_preview)
    end
  end

  defp click(decision, session_id, selector, label_preview) do
    case Session.click(session_id, selector, visible_label_preview: label_preview) do
      {:ok, click} ->
        {:ok,
         %{
           message: "Browser click completed.",
           status: :completed,
           session_id: session_id,
           click: click,
           permission_decision: decision,
           actions: [
             Actions.action("browser_click", :completed, :browser_interact, decision, %{
               session_id: session_id,
               selector: selector,
               visible_label_preview: label_preview
             })
           ]
         }}

      {:error, reason} ->
        Actions.denied("browser_click", :browser_interact, decision, reason)
    end
  end

  defp preview(value) when is_binary(value), do: String.slice(value, 0, 200)
  defp preview(_value), do: ""
end
