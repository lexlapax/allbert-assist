defmodule AllbertBrowser.Actions.StartSession do
  @moduledoc false

  use AllbertAssist.Action,
    permission: :browser_session_start,
    exposure: :internal,
    execution_mode: :browser_session,
    skill_backed?: false,
    confirmation: :required,
    resumable?: true,
    plugin_id: "allbert.browser",
    name: "browser_start_session",
    description: "Start a confirmed browser session.",
    category: "browser",
    tags: ["browser", "session", "confirmation_required"],
    schema: [
      purpose: [type: :string, required: false],
      expected_domains: [type: {:list, :string}, required: false]
    ],
    output_schema: [
      message: [type: :string, required: true],
      status: [type: :atom, required: true],
      actions: [type: {:list, :map}, required: true]
    ]

  alias AllbertAssist.Settings
  alias AllbertBrowser.{Actions, Doctor, Session}

  @impl true
  def run(params, context) do
    decision = Actions.authorize(:browser_session_start, context)

    cond do
      Settings.get("browser.enabled") != {:ok, true} ->
        Actions.denied(
          "browser_start_session",
          :browser_session_start,
          decision,
          :browser_disabled
        )

      decision.decision == :denied ->
        Actions.denied(
          "browser_start_session",
          :browser_session_start,
          decision,
          :permission_denied
        )

      not Actions.approval_resume?(context) ->
        Actions.confirmation(
          "browser_start_session",
          :browser_session_start,
          :browser_session,
          %{
            purpose: Actions.field(params, :purpose),
            expected_domains: Actions.field(params, :expected_domains, [])
          },
          Map.put(params, :action, "browser_start_session"),
          context,
          decision
        )

      true ->
        start_session(decision)
    end
  end

  defp start_session(decision) do
    with :ok <- below_session_cap(),
         :ok <- Doctor.fresh_ok?(),
         {:ok, session_id} <- Session.start_session() do
      {:ok,
       %{
         message: "Browser session #{session_id} started.",
         status: :completed,
         session_id: session_id,
         permission_decision: decision,
         actions: [
           Actions.action(
             "browser_start_session",
             :completed,
             :browser_session_start,
             decision,
             %{
               session_id: session_id
             }
           )
         ]
       }}
    else
      {:error, reason} ->
        Actions.denied("browser_start_session", :browser_session_start, decision, reason)
    end
  end

  defp below_session_cap do
    max = elem(Settings.get("browser.session.max_concurrent"), 1)

    if length(Session.list()) < max do
      :ok
    else
      {:error, :max_concurrent_sessions_reached}
    end
  end
end
