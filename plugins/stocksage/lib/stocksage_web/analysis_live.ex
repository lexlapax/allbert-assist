defmodule StockSageWeb.AnalysisLive do
  @moduledoc """
  StockSage-owned LiveView shell for analysis index and detail surfaces.
  """

  use AllbertAssistWeb, :live_view

  alias AllbertAssist.Actions.Runner
  alias AllbertAssist.{Confirmations, Objectives}
  alias AllbertAssist.Surface.Node
  alias StockSage.Analyses
  alias StockSage.Memory, as: StockSageMemory
  alias StockSage.Progress
  alias StockSage.SurfaceNodes
  alias StockSageWeb.Components.AppShell
  alias StockSageWeb.Components.SurfaceRenderer
  alias StockSageWeb.Live

  @impl true
  def mount(_params, _session, socket) do
    {:ok,
     socket
     |> Live.assign_context(:stocksage_analyses)
     |> assign(:analysis_id, nil)
     |> assign(:analysis, nil)
     |> assign(:analyses, [])
     |> assign(:load_error, nil)
     |> assign(:objective, nil)
     |> assign(:objective_steps, [])
     |> assign(:pending_confirmations, [])
     |> assign(:reflection_entries, [])
     |> assign(:reflection_error, nil)
     |> assign(:reflection_notice, nil)
     |> assign(:surface_nodes, [])
     |> assign(:progress_topic, nil)
     |> stream(:progress, [])}
  end

  @impl true
  def handle_params(params, _uri, socket) do
    analysis_id = Map.get(params, "id")

    {:noreply,
     socket
     |> assign(:analysis_id, analysis_id)
     |> load_analysis_state(analysis_id)
     |> maybe_subscribe_progress(analysis_id)}
  end

  @impl true
  def handle_event("cancel_objective", %{"objective-id" => objective_id}, socket) do
    _ =
      Objectives.cancel(socket.assigns.user_id, objective_id, "Cancelled from StockSage surface.")

    {:noreply, load_analysis_state(socket, socket.assigns.analysis_id)}
  end

  @impl true
  def handle_event("generate_reflection", %{"outcome-id" => outcome_id}, socket) do
    context = %{
      active_app: :stocksage,
      user_id: socket.assigns.user_id,
      session_id: socket.assigns.session_id,
      thread_id: Map.get(socket.assigns, :thread_id),
      objective_id: socket.assigns.objective && socket.assigns.objective.id,
      request: %{
        active_app: :stocksage,
        user_id: socket.assigns.user_id,
        source: :stocksage_live
      }
    }

    case Runner.run(
           "generate_reflection",
           %{user_id: socket.assigns.user_id, outcome_id: outcome_id},
           context
         ) do
      {:ok, %{status: :completed, reflection: reflection}} ->
        {:noreply,
         socket
         |> assign(:reflection_notice, "Reflection generated for #{reflection.symbol}.")
         |> assign(:reflection_error, nil)
         |> load_analysis_state(socket.assigns.analysis_id)}

      {:ok, response} ->
        {:noreply,
         socket
         |> assign(:reflection_notice, nil)
         |> assign(
           :reflection_error,
           Map.get(response, :message) || "Could not generate reflection."
         )
         |> load_analysis_state(socket.assigns.analysis_id)}
    end
  end

  @impl true
  def handle_info({:stocksage_progress, payload}, socket) do
    {:noreply, stream_insert(socket, :progress, Progress.normalize_payload(payload), at: -1)}
  end

  @impl true
  def render(assigns) do
    ~H"""
    <main
      id="stocksage-analyses"
      class="min-h-screen overflow-x-hidden bg-zinc-950 px-4 py-6 text-zinc-100 sm:px-6"
      data-active-app={@active_app}
      data-analysis-id={@analysis_id}
      data-surface={@stocksage_surface}
    >
      <a
        href="#stocksage-main-content"
        class="sr-only focus:not-sr-only focus:absolute focus:left-4 focus:top-4 focus:z-50 focus:rounded focus:bg-emerald-300 focus:px-3 focus:py-2 focus:text-zinc-950"
      >
        Skip to StockSage content
      </a>
      <AppShell.disabled_state :if={!@web_enabled?} />
      <section :if={@web_enabled?} class="mx-auto flex max-w-6xl flex-col gap-5">
        <header
          id="stocksage-main-content"
          class="flex flex-col gap-3 border-b border-zinc-800 pb-4 md:flex-row md:items-end md:justify-between"
          tabindex="-1"
        >
          <div class="min-w-0">
            <p class="text-sm font-semibold uppercase text-emerald-300">StockSage</p>
            <h1 class="break-words text-3xl font-semibold tracking-normal">
              {if @analysis_id, do: "Analysis #{@analysis_id}", else: "Analyses"}
            </h1>
          </div>
          <AppShell.nav current={:analyses} />
        </header>

        <AppShell.state_panel
          :if={@load_error}
          id="stocksage-analysis-error"
          title="Analysis unavailable"
          body={@load_error}
          tone={:error}
          role="alert"
        />

        <section
          :if={!@analysis_id}
          id="stocksage-analysis-index"
          class="rounded border border-zinc-800 bg-zinc-900 p-5"
        >
          <h2 class="text-lg font-semibold">Recent analyses</h2>
          <ul :if={@analyses != []} class="mt-4 divide-y divide-zinc-800">
            <li :for={analysis <- @analyses} class="py-3">
              <.link
                navigate={~p"/stocksage/analyses/#{analysis.id}"}
                class="font-medium text-emerald-200 hover:text-emerald-100 focus:outline-none focus-visible:ring-2 focus-visible:ring-emerald-300"
              >
                {analysis.symbol || analysis.id}
              </.link>
              <p class="mt-1 text-sm text-zinc-400">
                {analysis.status} · {analysis.engine} · {analysis.summary || "No summary yet"}
              </p>
            </li>
          </ul>
        </section>

        <AppShell.state_panel
          :if={!@analysis_id && @analyses == []}
          id="stocksage-analysis-index-empty"
          title="No persisted analyses"
          body="Completed or failed StockSage analyses will appear here after they are recorded."
          tone={:muted}
        />

        <AppShell.state_panel
          :if={@analysis_id && is_nil(@analysis) && is_nil(@load_error)}
          id="stocksage-analysis-empty"
          title="Loading analysis"
          body="Persisted StockSage analysis detail is loading."
          tone={:muted}
          role="status"
        />
        <section
          :if={@surface_nodes != []}
          id="stocksage-analysis-surface-nodes"
          class="grid gap-4"
          aria-label="StockSage analysis cards"
        >
          <SurfaceRenderer.node :for={node <- @surface_nodes} node={node} />
        </section>

        <AppShell.state_panel
          :if={@reflection_notice}
          id="stocksage-reflection-notice"
          title="Reflection ready"
          body={@reflection_notice}
          tone={:success}
          role="status"
        />

        <AppShell.state_panel
          :if={@reflection_error}
          id="stocksage-reflection-error"
          title="Reflection unavailable"
          body={@reflection_error}
          tone={:error}
          role="alert"
        />

        <section
          :if={@analysis && @analysis.outcomes != []}
          id="stocksage-outcome-reflection-actions"
          class="rounded border border-zinc-800 bg-zinc-900 p-5"
        >
          <h2 class="text-lg font-semibold">Outcomes</h2>
          <div class="mt-4 overflow-x-auto">
            <table class="min-w-full text-left text-sm">
              <thead class="text-xs uppercase text-zinc-500">
                <tr>
                  <th class="py-2 pr-4 font-medium">Symbol</th>
                  <th class="py-2 pr-4 font-medium">Label</th>
                  <th class="py-2 pr-4 font-medium">Return</th>
                  <th class="py-2 pr-4 font-medium">Observed</th>
                  <th class="py-2 pr-4 font-medium">Reflection</th>
                </tr>
              </thead>
              <tbody class="divide-y divide-zinc-800">
                <tr
                  :for={outcome <- @analysis.outcomes}
                  id={"stocksage-analysis-outcome-#{outcome.id}"}
                >
                  <td class="py-3 pr-4 font-medium text-zinc-100">{outcome.symbol}</td>
                  <td class="py-3 pr-4 text-zinc-300">{outcome.label}</td>
                  <td class="py-3 pr-4 text-zinc-300">{decimal_value(outcome.return_pct)}</td>
                  <td class="py-3 pr-4 text-zinc-400">{date_value(outcome.observed_on)}</td>
                  <td class="py-3 pr-4">
                    <button
                      id={"stocksage-generate-reflection-#{outcome.id}"}
                      type="button"
                      phx-click="generate_reflection"
                      phx-value-outcome-id={outcome.id}
                      disabled={outcome.label == "pending"}
                      class="rounded border border-emerald-500/60 px-3 py-2 text-sm text-emerald-100 hover:border-emerald-300 focus:outline-none focus-visible:ring-2 focus-visible:ring-emerald-300 disabled:cursor-not-allowed disabled:border-zinc-700 disabled:text-zinc-500"
                    >
                      Generate
                    </button>
                  </td>
                </tr>
              </tbody>
            </table>
          </div>
        </section>

        <section
          :if={@reflection_entries != []}
          id="stocksage-reflections"
          class="rounded border border-zinc-800 bg-zinc-900 p-5"
        >
          <h2 class="text-lg font-semibold">Reflections</h2>
          <article
            :for={entry <- @reflection_entries}
            id={"stocksage-reflection-#{entry.id}"}
            class="mt-4 rounded border border-zinc-800 bg-zinc-950 p-4 text-sm"
          >
            <div class="flex flex-col gap-1 md:flex-row md:items-center md:justify-between">
              <span class="font-medium text-emerald-200">{entry.tags["symbol"] || entry.kind}</span>
              <span class="text-xs text-zinc-500">
                {entry.tags["label"] || "outcome"} · StockSage local
              </span>
            </div>
            <p class="mt-3 whitespace-pre-line text-zinc-300">{entry.content}</p>
          </article>
        </section>

        <section
          :if={@analysis_id && is_nil(@load_error)}
          id="stocksage-progress"
          class="rounded border border-zinc-800 bg-zinc-900 p-5"
          aria-label="StockSage analysis progress"
        >
          <div class="flex flex-col gap-1 md:flex-row md:items-center md:justify-between">
            <h2 class="text-lg font-semibold">Progress</h2>
          </div>
          <div
            id="stocksage-progress-stream"
            class="mt-4 space-y-2"
            phx-update="stream"
            role="list"
          >
            <article
              :for={{dom_id, progress} <- @streams.progress}
              id={dom_id}
              class="rounded border border-zinc-800 bg-zinc-950 p-3 text-sm"
              role="listitem"
              data-stage={progress.stage}
              data-status={progress.status}
            >
              <div class="flex flex-col gap-1 md:flex-row md:items-center md:justify-between">
                <span class="font-medium text-emerald-200">{progress.stage}</span>
                <span class="text-xs text-zinc-400">{progress.status} · {progress.at}</span>
              </div>
              <p :if={progress.summary} class="mt-1 text-zinc-300">{progress.summary}</p>
            </article>
          </div>
        </section>

        <section
          :if={@objective}
          id="stocksage-objective-state"
          class="rounded border border-zinc-800 bg-zinc-900 p-5"
        >
          <div class="flex flex-col gap-3 md:flex-row md:items-start md:justify-between">
            <div>
              <p class="text-sm font-semibold uppercase text-emerald-300">Objective</p>
              <h2 class="mt-1 text-xl font-semibold tracking-normal">{@objective.title}</h2>
              <p class="mt-1 text-xs text-zinc-400">{@objective.id}</p>
            </div>
            <span class="rounded bg-zinc-800 px-2 py-1 text-xs font-semibold text-zinc-200">
              {@objective.status}
            </span>
          </div>

          <p class="mt-3 max-w-3xl text-sm text-zinc-300">{@objective.objective}</p>

          <div class="mt-4 flex flex-wrap gap-2">
            <.link
              navigate={~p"/objectives/#{@objective.id}"}
              class="rounded border border-zinc-700 px-3 py-2 text-sm hover:border-emerald-400 focus:outline-none focus-visible:ring-2 focus-visible:ring-emerald-300"
            >
              Open objective
            </.link>
            <button
              :if={cancelable_objective?(@objective)}
              id="stocksage-cancel-objective"
              type="button"
              phx-click="cancel_objective"
              phx-value-objective-id={@objective.id}
              class="rounded border border-red-500/60 px-3 py-2 text-sm text-red-200 hover:border-red-300 focus:outline-none focus-visible:ring-2 focus-visible:ring-red-300"
            >
              Cancel objective
            </button>
          </div>

          <ol :if={@objective_steps != []} id="stocksage-objective-steps" class="mt-4 space-y-2">
            <li
              :for={step <- @objective_steps}
              class="rounded border border-zinc-800 bg-zinc-950 p-3 text-sm"
            >
              <div class="flex flex-col gap-2 md:flex-row md:items-center md:justify-between">
                <span class="font-medium">{step.delegate_agent_id || step.kind}</span>
                <span class="text-xs text-zinc-400">{step.status}</span>
              </div>
              <p :if={step.result_summary} class="mt-1 text-zinc-300">{step.result_summary}</p>
            </li>
          </ol>
        </section>

        <section
          :if={@pending_confirmations != []}
          id="stocksage-confirmation-links"
          class="rounded border border-amber-500/40 bg-amber-500/10 p-5"
        >
          <h2 class="text-lg font-semibold text-amber-100">Pending confirmations</h2>
          <ul class="mt-3 space-y-2 text-sm text-amber-50">
            <li :for={confirmation <- @pending_confirmations}>
              <.link
                navigate={~p"/settings"}
                class="underline underline-offset-4 focus:outline-none focus-visible:ring-2 focus-visible:ring-amber-200"
              >
                Review confirmation {confirmation["id"]}
              </.link>
            </li>
          </ul>
        </section>
      </section>
    </main>
    """
  end

  defp load_analysis_state(socket, nil) do
    socket
    |> assign(:analysis, nil)
    |> assign(:analyses, Analyses.list_analyses(socket.assigns.user_id, limit: 25))
    |> assign(:load_error, nil)
    |> assign(:objective, nil)
    |> assign(:objective_steps, [])
    |> assign(:pending_confirmations, [])
    |> assign(:reflection_entries, [])
    |> assign(:surface_nodes, [])
    |> stream(:progress, [], reset: true)
  end

  defp load_analysis_state(socket, analysis_id) do
    case Analyses.get_analysis_with_details(socket.assigns.user_id, analysis_id) do
      {:ok, analysis} ->
        {objective, steps} = objective_state(socket.assigns.user_id, analysis.objective_id)
        progress_items = Progress.persisted_items(analysis, steps)

        surface_nodes =
          case SurfaceNodes.from_analysis(analysis) do
            {:ok, nodes} -> nodes
            {:error, _diagnostics} -> detail_surface_nodes(analysis_id)
          end

        socket
        |> assign(:analysis, analysis)
        |> assign(:analyses, [])
        |> assign(:load_error, nil)
        |> assign(:objective, objective)
        |> assign(:objective_steps, steps)
        |> assign(:pending_confirmations, pending_confirmations(analysis, objective))
        |> assign(:reflection_entries, reflection_entries(socket.assigns.user_id, analysis.id))
        |> assign(:surface_nodes, surface_nodes)
        |> stream(:progress, progress_items, reset: true)

      {:error, :not_found} ->
        socket
        |> assign(:analysis, nil)
        |> assign(:analyses, [])
        |> assign(:load_error, "No StockSage analysis was found for #{analysis_id}.")
        |> assign(:objective, nil)
        |> assign(:objective_steps, [])
        |> assign(:pending_confirmations, [])
        |> assign(:reflection_entries, [])
        |> assign(:surface_nodes, [])
        |> stream(:progress, [], reset: true)
    end
  end

  defp maybe_subscribe_progress(socket, nil) do
    socket.assigns.progress_topic
    |> Progress.unsubscribe_topic()

    assign(socket, :progress_topic, nil)
  end

  defp maybe_subscribe_progress(socket, "") do
    maybe_subscribe_progress(socket, nil)
  end

  defp maybe_subscribe_progress(socket, analysis_id) do
    next_topic = Progress.topic(socket.assigns.user_id, analysis_id)
    previous_topic = socket.assigns.progress_topic

    if connected?(socket) and socket.assigns.web_enabled? do
      if previous_topic != next_topic do
        Progress.unsubscribe_topic(previous_topic)
        Progress.subscribe(socket.assigns.user_id, analysis_id)
      end
    end

    assign(socket, :progress_topic, next_topic)
  end

  defp objective_state(_user_id, nil), do: {nil, []}
  defp objective_state(_user_id, ""), do: {nil, []}

  defp objective_state(user_id, objective_id) do
    case Objectives.get_objective(user_id, objective_id) do
      {:ok, objective} -> {objective, Objectives.list_steps(objective.id)}
      {:error, _reason} -> {nil, []}
    end
  end

  defp pending_confirmations(analysis, objective) do
    objective_id = (objective && objective.id) || analysis.objective_id

    if is_binary(objective_id) and objective_id != "" do
      Confirmations.list(status: :pending)
      |> Enum.filter(&(confirmation_objective_id(&1) == objective_id))
    else
      []
    end
  rescue
    _exception -> []
  end

  defp confirmation_objective_id(record) do
    record["objective_id"] ||
      get_in(record, ["params_summary", "objective_id"]) ||
      get_in(record, ["resume_params_ref", "objective_id"]) ||
      get_in(record, ["origin", "objective_id"])
  end

  defp reflection_entries(user_id, analysis_id) do
    StockSageMemory.list_entries(user_id, kind: "reflection", analysis_id: analysis_id, limit: 10)
  rescue
    _exception -> []
  end

  defp detail_surface_nodes(nil), do: []

  defp detail_surface_nodes(analysis_id) do
    [
      %Node{
        id: "analysis-card-#{safe_dom_id(analysis_id)}",
        component: :analysis_card,
        props: %{
          analysis_id: analysis_id,
          title: "Analysis #{analysis_id}",
          status: "loading",
          summary: "Loading persisted StockSage analysis detail.",
          engine: "native"
        }
      }
    ]
  end

  defp cancelable_objective?(%{status: status}) do
    status not in ["cancelled", "completed", "failed", "abandoned"]
  end

  defp safe_dom_id(value) do
    value
    |> to_string()
    |> String.replace(~r/[^a-zA-Z0-9_-]/, "-")
    |> String.slice(0, 64)
  end

  defp date_value(%Date{} = date), do: Date.to_iso8601(date)
  defp date_value(nil), do: "not recorded"
  defp date_value(value), do: to_string(value)

  defp decimal_value(%Decimal{} = value), do: Decimal.to_string(value, :normal)
  defp decimal_value(nil), do: "pending"
  defp decimal_value(value), do: to_string(value)
end
