defmodule AllbertBrowser.Actions.Navigate do
  @moduledoc false

  use AllbertAssist.Action,
    permission: :browser_navigate,
    exposure: :internal,
    execution_mode: :browser_session,
    skill_backed?: false,
    confirmation: :required,
    resumable?: true,
    plugin_id: "allbert.browser",
    name: "browser_navigate",
    description: "Navigate an existing browser session after policy and grant checks.",
    category: "browser",
    tags: ["browser", "navigation", "confirmation_required"],
    schema: [
      session_id: [type: :string, required: true],
      url: [type: :string, required: true],
      wait_until: [type: :string, required: false],
      referer: [type: :string, required: false]
    ],
    output_schema: [
      message: [type: :string, required: true],
      status: [type: :atom, required: true],
      actions: [type: {:list, :map}, required: true]
    ]

  alias AllbertAssist.Resources.{Grants, Ref, ResourceURI, Scope}
  alias AllbertBrowser.{Actions, NavigationPolicy, Session}

  @impl true
  def run(params, context) do
    decision = Actions.authorize(:browser_navigate, context)
    session_id = Actions.field(params, :session_id)
    url = Actions.field(params, :url)

    with :ok <- valid_required(session_id, :missing_session_id),
         :ok <- valid_required(url, :missing_url),
         :ok <- NavigationPolicy.preflight(url),
         {:ok, ref} <- navigation_ref(url) do
      run_authorized(params, context, decision, session_id, url, ref)
    else
      {:error, reason} -> Actions.denied("browser_navigate", :browser_navigate, decision, reason)
    end
  end

  defp run_authorized(params, context, decision, session_id, url, ref) do
    cond do
      decision.decision == :denied ->
        Actions.denied("browser_navigate", :browser_navigate, decision, :permission_denied)

      Actions.approval_resume?(context) or grant?(ref, context) ->
        navigate(params, decision, session_id, url, ref)

      true ->
        Actions.confirmation(
          "browser_navigate",
          :browser_navigate,
          :browser_session,
          %{session_id: session_id, url: url, resource_refs: [Ref.to_map(ref)]},
          Map.put(params, :action, "browser_navigate"),
          context,
          decision
        )
    end
  end

  defp navigate(params, decision, session_id, url, ref) do
    case Session.navigate(session_id, url, wait_until: Actions.field(params, :wait_until)) do
      {:ok, page_meta} ->
        {:ok,
         %{
           message: "Browser navigated to #{url}.",
           status: :completed,
           session_id: session_id,
           page: page_meta,
           resource_refs: [Ref.to_map(ref)],
           permission_decision: decision,
           actions: [
             Actions.action("browser_navigate", :completed, :browser_navigate, decision, %{
               session_id: session_id,
               url: url,
               page: page_meta
             })
           ]
         }}

      {:error, reason} ->
        Actions.denied("browser_navigate", :browser_navigate, decision, reason)
    end
  end

  defp navigation_ref(url) do
    with {:ok, resource_uri} <- ResourceURI.url(url, :exact),
         {:ok, prefix_uri} <- ResourceURI.url(url, :prefix) do
      Ref.new(%{
        resource_uri: resource_uri,
        origin_kind: :remote_url,
        operation_class: :browser_navigate,
        access_mode: :fetch,
        scope: Scope.url_prefix(prefix_uri),
        downstream_consumer: :browser_navigator
      })
    end
  end

  defp grant?(ref, context) do
    match?(
      {:ok, _grant},
      Grants.find_applicable(ref, permission: :browser_navigate, context: context)
    )
  end

  defp valid_required(value, reason) when value in [nil, ""], do: {:error, reason}
  defp valid_required(_value, _reason), do: :ok
end
