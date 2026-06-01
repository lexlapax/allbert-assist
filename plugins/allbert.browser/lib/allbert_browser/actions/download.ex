defmodule AllbertBrowser.Actions.Download do
  @moduledoc false

  use AllbertAssist.Action,
    permission: :browser_download,
    exposure: :internal,
    execution_mode: :browser_session,
    skill_backed?: false,
    confirmation: :required,
    resumable?: true,
    plugin_id: "allbert.browser",
    name: "browser_download",
    description: "Download a browser resource after opt-in and confirmation.",
    category: "browser",
    tags: ["browser", "download", "confirmation_required"],
    schema: [
      session_id: [type: :string, required: true],
      url: [type: :string, required: true],
      filename: [type: :string, required: false]
    ],
    output_schema: [
      message: [type: :string, required: true],
      status: [type: :atom, required: true],
      actions: [type: {:list, :map}, required: true]
    ]

  alias AllbertAssist.Settings
  alias AllbertBrowser.{Actions, NavigationPolicy, Session}

  @impl true
  def run(params, context) do
    decision = Actions.authorize(:browser_download, context)
    session_id = Actions.field(params, :session_id)
    url = Actions.field(params, :url)

    with :ok <- required(session_id, :missing_session_id),
         :ok <- required(url, :missing_url),
         :ok <- NavigationPolicy.preflight(url) do
      run_authorized(params, context, decision, session_id, url)
    else
      {:error, reason} -> Actions.denied("browser_download", :browser_download, decision, reason)
    end
  end

  defp run_authorized(params, context, decision, session_id, url) do
    cond do
      not enabled?() ->
        Actions.denied(
          "browser_download",
          :browser_download,
          decision,
          :browser_download_disabled
        )

      decision.decision == :denied ->
        Actions.denied("browser_download", :browser_download, decision, :permission_denied)

      Actions.approval_resume?(context) ->
        download(params, decision, session_id, url)

      true ->
        Actions.confirmation(
          "browser_download",
          :browser_download,
          :browser_session,
          %{
            session_id: session_id,
            url: url,
            filename: Actions.field(params, :filename)
          },
          Map.put(params, :action, "browser_download"),
          context,
          decision
        )
    end
  end

  defp download(params, decision, session_id, url) do
    opts = [filename: Actions.field(params, :filename)]

    case Session.download(session_id, url, opts) do
      {:ok, download} ->
        {:ok,
         %{
           message: "Browser download completed.",
           status: :completed,
           session_id: session_id,
           download: download,
           permission_decision: decision,
           actions: [
             Actions.action("browser_download", :completed, :browser_download, decision, %{
               session_id: session_id,
               url: url,
               download_ref: Map.get(download, :download_ref)
             })
           ]
         }}

      {:error, reason} ->
        Actions.denied("browser_download", :browser_download, decision, reason)
    end
  end

  defp enabled? do
    case Settings.get("browser.download.enabled") do
      {:ok, true} -> true
      _other -> false
    end
  end

  defp required(value, reason) when value in [nil, ""], do: {:error, reason}
  defp required(_value, _reason), do: :ok
end
