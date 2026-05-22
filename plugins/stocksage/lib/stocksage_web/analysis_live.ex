defmodule StockSageWeb.AnalysisLive do
  @moduledoc """
  StockSage-owned LiveView shell for analysis index and detail surfaces.
  """

  use AllbertAssistWeb, :live_view

  alias AllbertAssist.Actions.Runner
  alias AllbertAssist.Memory, as: AllbertMemory
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
     |> assign(:rerun_error, nil)
     |> assign(:rerun_notice, nil)
     |> assign(:sync_error, nil)
     |> assign(:sync_notice, nil)
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
  def handle_event("rerun_analysis", %{"engine" => engine}, socket) do
    with %{id: _analysis_id} = analysis <- socket.assigns.analysis,
         {:ok, params} <- rerun_params(analysis, engine),
         {:ok, response} <- Runner.run("run_analysis", params, rerun_context(socket)) do
      case response do
        %{status: :needs_confirmation, confirmation_id: confirmation_id} ->
          {:noreply,
           socket
           |> assign(
             :rerun_notice,
             "Rerun confirmation #{confirmation_id} queued for #{analysis.symbol} using #{rerun_label(engine)}."
           )
           |> assign(:rerun_error, nil)
           |> load_analysis_state(socket.assigns.analysis_id)}

        %{status: :completed, analysis_id: new_analysis_id} ->
          {:noreply,
           socket
           |> assign(:rerun_notice, "Rerun completed as analysis #{new_analysis_id}.")
           |> assign(:rerun_error, nil)
           |> load_analysis_state(socket.assigns.analysis_id)}

        response ->
          {:noreply,
           socket
           |> assign(:rerun_notice, nil)
           |> assign(:rerun_error, Map.get(response, :message) || "Could not rerun analysis.")
           |> load_analysis_state(socket.assigns.analysis_id)}
      end
    else
      nil ->
        {:noreply,
         socket
         |> assign(:rerun_notice, nil)
         |> assign(:rerun_error, "No analysis is loaded to rerun.")}

      {:error, reason} ->
        {:noreply,
         socket
         |> assign(:rerun_notice, nil)
         |> assign(:rerun_error, "Could not rerun analysis: #{inspect(reason)}.")}
    end
  end

  @impl true
  def handle_event("sync_lesson", %{"entry-id" => entry_id}, socket) do
    with {:ok, entry} <- StockSageMemory.get_entry(socket.assigns.user_id, entry_id),
         {:ok, params} <- sync_lesson_params(socket.assigns.user_id, entry),
         {:ok, response} <- Runner.run("sync_app_lesson", params, sync_lesson_context(socket)) do
      case response do
        %{status: :completed, memory: memory} ->
          update_synced_reflection(entry, memory)

          {:noreply,
           socket
           |> assign(:sync_notice, "Synced lesson to Allbert markdown memory.")
           |> assign(:sync_error, nil)
           |> load_analysis_state(socket.assigns.analysis_id)}

        %{status: :needs_confirmation, confirmation_id: confirmation_id} ->
          mark_pending_reflection(entry, response)

          {:noreply,
           socket
           |> assign(
             :sync_notice,
             "Lesson sync requires confirmation #{confirmation_id}. No Allbert markdown memory was written."
           )
           |> assign(:sync_error, nil)
           |> load_analysis_state(socket.assigns.analysis_id)}

        response ->
          {:noreply,
           socket
           |> assign(:sync_notice, nil)
           |> assign(:sync_error, Map.get(response, :message) || "Could not sync lesson.")
           |> load_analysis_state(socket.assigns.analysis_id)}
      end
    else
      {:error, reason} ->
        {:noreply,
         socket
         |> assign(:sync_notice, nil)
         |> assign(:sync_error, "Could not sync lesson: #{inspect(reason)}.")
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

        <AppShell.state_panel
          :if={@rerun_notice}
          id="stocksage-rerun-notice"
          title="Rerun queued"
          body={@rerun_notice}
          tone={:success}
          role="status"
        />

        <AppShell.state_panel
          :if={@rerun_error}
          id="stocksage-rerun-error"
          title="Rerun unavailable"
          body={@rerun_error}
          tone={:error}
          role="alert"
        />

        <AppShell.state_panel
          :if={@sync_notice}
          id="stocksage-sync-notice"
          title="Lesson sync queued"
          body={@sync_notice}
          tone={:success}
          role="status"
        />

        <AppShell.state_panel
          :if={@sync_error}
          id="stocksage-sync-error"
          title="Lesson sync unavailable"
          body={@sync_error}
          tone={:error}
          role="alert"
        />

        <section
          :if={@analysis}
          id="stocksage-analysis-rerun"
          class="rounded border border-zinc-800 bg-zinc-900 p-5"
        >
          <div class="flex flex-col gap-3 md:flex-row md:items-center md:justify-between">
            <h2 class="text-lg font-semibold">Rerun</h2>
            <div class="flex flex-wrap gap-2">
              <button
                id="stocksage-rerun-native"
                type="button"
                phx-click="rerun_analysis"
                phx-value-engine="native"
                class="rounded border border-emerald-500/60 px-3 py-2 text-sm text-emerald-100 hover:border-emerald-300 focus:outline-none focus-visible:ring-2 focus-visible:ring-emerald-300"
              >
                Native
              </button>
              <button
                id="stocksage-rerun-python"
                type="button"
                phx-click="rerun_analysis"
                phx-value-engine="python"
                class="rounded border border-zinc-700 px-3 py-2 text-sm text-zinc-200 hover:border-emerald-300 focus:outline-none focus-visible:ring-2 focus-visible:ring-emerald-300"
              >
                Python
              </button>
              <button
                id="stocksage-rerun-both"
                type="button"
                phx-click="rerun_analysis"
                phx-value-engine="both"
                class="rounded border border-zinc-700 px-3 py-2 text-sm text-zinc-200 hover:border-emerald-300 focus:outline-none focus-visible:ring-2 focus-visible:ring-emerald-300"
              >
                Parity
              </button>
            </div>
          </div>
        </section>

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
                {entry.tags["label"] || "outcome"} · {reflection_memory_label(entry)}
              </span>
            </div>
            <p class="mt-3 whitespace-pre-line text-zinc-300">{entry.content}</p>
            <div class="mt-4 flex flex-wrap gap-2">
              <button
                id={"stocksage-sync-lesson-#{entry.id}"}
                type="button"
                phx-click="sync_lesson"
                phx-value-entry-id={entry.id}
                disabled={entry.promoted_to_allbert_memory or sync_pending?(entry)}
                class="rounded border border-amber-400/70 px-3 py-2 text-sm text-amber-100 hover:border-amber-200 focus:outline-none focus-visible:ring-2 focus-visible:ring-amber-200 disabled:cursor-not-allowed disabled:border-zinc-700 disabled:text-zinc-500"
              >
                {sync_button_label(entry)}
              </button>
            </div>
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

    Confirmations.list(status: :pending)
    |> Enum.filter(fn confirmation ->
      (is_binary(objective_id) and objective_id != "" and
         confirmation_objective_id(confirmation) == objective_id) or
        get_in(confirmation, ["params_summary", "source_analysis_id"]) == analysis.id
    end)
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
    user_id
    |> StockSageMemory.list_entries(kind: "reflection", analysis_id: analysis_id, limit: 10)
    |> Enum.map(&refresh_sync_state(user_id, &1))
  rescue
    _exception -> []
  end

  defp rerun_context(socket) do
    %{
      active_app: :stocksage,
      user_id: socket.assigns.user_id,
      actor: socket.assigns.user_id,
      channel: :live_view,
      session_id: socket.assigns.session_id,
      thread_id: Map.get(socket.assigns, :thread_id),
      surface: "stocksage_analysis",
      request: %{
        active_app: :stocksage,
        user_id: socket.assigns.user_id,
        operator_id: socket.assigns.user_id,
        channel: :live_view,
        source: :stocksage_live
      }
    }
  end

  defp rerun_params(analysis, engine) do
    with {:ok, engine} <- rerun_engine(engine),
         {:ok, ticker} <- rerun_ticker(analysis),
         {:ok, analysis_date} <- rerun_analysis_date(analysis) do
      {:ok,
       %{
         user_id: analysis.user_id,
         ticker: ticker,
         analysis_date: analysis_date,
         engine: engine,
         evidence_mode: rerun_evidence_mode(analysis),
         thread_id: analysis.thread_id,
         session_id: analysis.session_id,
         source_analysis_id: analysis.id
       }}
    end
  end

  defp rerun_engine(engine) when engine in ["native", "python", "both"], do: {:ok, engine}
  defp rerun_engine(_engine), do: {:error, :invalid_rerun_engine}

  defp rerun_ticker(%{symbol: symbol}) when is_binary(symbol) do
    case String.trim(symbol) do
      "" -> {:error, :missing_ticker}
      ticker -> {:ok, ticker}
    end
  end

  defp rerun_ticker(_analysis), do: {:error, :missing_ticker}

  defp rerun_analysis_date(%{analysis_date: %Date{} = date}), do: {:ok, Date.to_iso8601(date)}

  defp rerun_analysis_date(%{analysis_date: date}) when is_binary(date) do
    case String.trim(date) do
      "" -> {:ok, Date.utc_today() |> Date.to_iso8601()}
      date -> {:ok, date}
    end
  end

  defp rerun_analysis_date(_analysis), do: {:ok, Date.utc_today() |> Date.to_iso8601()}

  defp rerun_evidence_mode(%{metadata: %{"evidence_mode" => mode}})
       when mode in ["live", "fixture", "compare"],
       do: mode

  defp rerun_evidence_mode(_analysis), do: nil

  defp rerun_label("native"), do: "native"
  defp rerun_label("python"), do: "Python comparison"
  defp rerun_label("both"), do: "parity"
  defp rerun_label(engine), do: engine

  defp sync_lesson_context(socket) do
    %{
      active_app: :stocksage,
      user_id: socket.assigns.user_id,
      actor: socket.assigns.user_id,
      channel: :live_view,
      session_id: socket.assigns.session_id,
      thread_id: Map.get(socket.assigns, :thread_id),
      objective_id: socket.assigns.objective && socket.assigns.objective.id,
      surface: "stocksage_analysis",
      request: %{
        active_app: :stocksage,
        user_id: socket.assigns.user_id,
        operator_id: socket.assigns.user_id,
        channel: :live_view,
        source: :stocksage_live
      }
    }
  end

  defp sync_lesson_params(user_id, entry) do
    with {:ok, outcome_id} <- metadata_required(entry, "outcome_id"),
         {:ok, outcome} <- Analyses.get_outcome(user_id, outcome_id),
         {:ok, holding_period_days} <- positive_horizon(outcome.horizon_days) do
      {:ok,
       %{
         user_id: user_id,
         app_id: "stocksage",
         namespace: "stocksage",
         analysis_id: outcome.analysis_id,
         outcome_id: outcome.id,
         objective_id: analysis_field(outcome.analysis, :objective_id),
         ticker: outcome.symbol,
         rating: analysis_recommendation(outcome.analysis),
         realized_return: decimal_value(outcome.return_pct),
         holding_period_days: holding_period_days,
         lesson_text: entry.content,
         source: "stocksage_reflection",
         resolved_at: date_value(outcome.observed_on)
       }}
    end
  end

  defp update_synced_reflection(entry, memory) do
    metadata =
      entry.metadata
      |> Map.put("allbert_memory_path", Map.get(memory, :path))
      |> Map.put("allbert_memory_idempotency_key", Map.get(memory, :idempotency_key))
      |> Map.delete("pending_allbert_confirmation_id")

    StockSageMemory.update_entry(entry, %{
      promoted_to_allbert_memory: true,
      allbert_memory_path: Map.get(memory, :path),
      metadata: metadata
    })
  end

  defp mark_pending_reflection(entry, response) do
    action = response |> Map.get(:actions, []) |> List.first() || %{}

    metadata =
      entry.metadata
      |> Map.put("pending_allbert_confirmation_id", Map.get(response, :confirmation_id))
      |> Map.put("allbert_memory_idempotency_key", Map.get(action, :idempotency_key))

    StockSageMemory.update_entry(entry, %{metadata: metadata})
  end

  defp refresh_sync_state(user_id, entry) do
    cond do
      entry.promoted_to_allbert_memory ->
        entry

      sync_key = entry.metadata["allbert_memory_idempotency_key"] ->
        case AllbertMemory.list_entries(
               user_id: user_id,
               app_id: :stocksage,
               namespace: :stocksage,
               idempotency_key: sync_key,
               limit: 1
             ) do
          {:ok, [memory_entry | _rest]} ->
            case update_synced_reflection(entry, %{
                   path: memory_entry.path,
                   idempotency_key: memory_entry.idempotency_key
                 }) do
              {:ok, updated} -> updated
              {:error, _reason} -> entry
            end

          _other ->
            entry
        end

      true ->
        entry
    end
  end

  defp metadata_required(entry, key) do
    entry.metadata
    |> Map.get(key)
    |> case do
      value when is_binary(value) and value != "" -> {:ok, value}
      _value -> {:error, {:missing_reflection_metadata, key}}
    end
  end

  defp positive_horizon(value) when is_integer(value) and value > 0, do: {:ok, value}
  defp positive_horizon(_value), do: {:error, :missing_holding_period_days}

  defp reflection_memory_label(%{promoted_to_allbert_memory: true}), do: "Allbert memory synced"

  defp reflection_memory_label(%{metadata: %{"pending_allbert_confirmation_id" => id}})
       when is_binary(id) and id != "",
       do: "Allbert sync pending"

  defp reflection_memory_label(_entry), do: "StockSage local"

  defp sync_button_label(%{promoted_to_allbert_memory: true}), do: "Synced"

  defp sync_button_label(%{metadata: %{"pending_allbert_confirmation_id" => id}})
       when is_binary(id) and id != "",
       do: "Sync pending"

  defp sync_button_label(_entry), do: "Sync lesson"

  defp sync_pending?(%{metadata: %{"pending_allbert_confirmation_id" => id}})
       when is_binary(id) and id != "",
       do: true

  defp sync_pending?(_entry), do: false

  defp analysis_recommendation(%{recommendation: recommendation})
       when is_binary(recommendation) do
    case String.trim(recommendation) do
      "" -> "unrated"
      rating -> rating
    end
  end

  defp analysis_recommendation(_analysis), do: "unrated"

  defp analysis_field(nil, _field), do: nil
  defp analysis_field(analysis, field), do: Map.get(analysis, field)

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
