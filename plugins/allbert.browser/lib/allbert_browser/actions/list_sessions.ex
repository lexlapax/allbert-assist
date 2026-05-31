defmodule AllbertBrowser.Actions.ListSessions do
  @moduledoc false

  use AllbertAssist.Action,
    permission: :browser_extract,
    exposure: :internal,
    execution_mode: :browser_session,
    skill_backed?: false,
    confirmation: :not_required,
    plugin_id: "allbert.browser",
    name: "browser_list_sessions",
    description: "List active browser sessions.",
    category: "browser",
    tags: ["browser", "session", "read_only"],
    schema: [],
    output_schema: [
      message: [type: :string, required: true],
      status: [type: :atom, required: true],
      actions: [type: {:list, :map}, required: true]
    ]

  alias AllbertBrowser.{Actions, Session}

  @impl true
  def run(_params, context) do
    decision = Actions.authorize(:browser_extract, context)

    if Actions.allowed?(decision) do
      sessions = Enum.map(Session.list(), &summary/1)

      {:ok,
       %{
         message: "Browser sessions listed.",
         status: :completed,
         sessions: sessions,
         permission_decision: decision,
         actions: [
           Actions.action("browser_list_sessions", :completed, :browser_extract, decision, %{
             count: length(sessions)
           })
         ]
       }}
    else
      Actions.denied("browser_list_sessions", :browser_extract, decision, :permission_denied)
    end
  end

  defp summary(session) do
    created_at = Map.get(session, :created_at)

    %{
      session_id: Map.get(session, :session_id),
      age_ms: age_ms(created_at),
      last_visited_host: last_visited_host(Map.get(session, :last_url)),
      last_url: Map.get(session, :last_url),
      created_at: created_at && DateTime.to_iso8601(created_at)
    }
  end

  defp age_ms(%DateTime{} = created_at), do: DateTime.diff(DateTime.utc_now(), created_at, :millisecond)
  defp age_ms(_created_at), do: nil

  defp last_visited_host(nil), do: nil
  defp last_visited_host(url), do: URI.parse(url).host
end
