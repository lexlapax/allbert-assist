defmodule StockSageWeb.Components.Cards do
  @moduledoc """
  StockSage-owned renderers for the app surface card component atoms.
  """

  use Phoenix.Component

  alias AllbertAssist.Surface.Node

  import AllbertAssistWeb.CoreComponents, only: [icon: 1]

  attr(:node, :any, required: true)

  def analysis_card(assigns) do
    assigns =
      assigns
      |> assign(:props, node_props(assigns.node))
      |> assign(:title, prop(assigns.node, :title, "StockSage analysis"))
      |> assign(:summary, prop(assigns.node, :summary, prop(assigns.node, :body, nil)))

    ~H"""
    <article
      id={"stocksage-card-#{@node.id}"}
      class="rounded border border-zinc-800 bg-zinc-900 p-4 text-zinc-100 shadow-sm"
      data-stocksage-component="analysis_card"
      aria-labelledby={title_id(@node)}
    >
      <header class="flex flex-col gap-3 md:flex-row md:items-start md:justify-between">
        <div class="min-w-0">
          <p class="flex items-center gap-2 text-sm font-semibold uppercase text-emerald-300">
            <.icon name="hero-chart-bar-micro" class="size-4" /> Analysis
          </p>
          <h2 id={title_id(@node)} class="mt-1 text-xl font-semibold tracking-normal">
            {@title}
          </h2>
          <p :if={present?(@summary)} class="mt-2 max-w-3xl text-sm text-zinc-300">
            {@summary}
          </p>
        </div>
        <.status_badge status={prop(@node, :status, nil)} />
      </header>

      <dl class="mt-4 grid gap-3 text-sm md:grid-cols-4">
        <.metric label="Ticker" value={prop(@node, :ticker, prop(@node, :symbol, "unknown"))} />
        <.metric label="Engine" value={prop(@node, :engine, "not set")} />
        <.metric label="Rating" value={prop(@node, :rating, prop(@node, :recommendation, "pending"))} />
        <.metric label="Confidence" value={confidence(prop(@node, :confidence, nil))} />
      </dl>

      <footer class="mt-4 flex flex-wrap gap-3 text-xs text-zinc-400">
        <span :if={present?(prop(@node, :analysis_id, nil))}>
          analysis_id: <code class="text-zinc-200">{prop(@node, :analysis_id, nil)}</code>
        </span>
        <span :if={present?(prop(@node, :objective_id, nil))}>
          objective_id: <code class="text-zinc-200">{prop(@node, :objective_id, nil)}</code>
        </span>
        <span :if={present?(prop(@node, :trace_id, nil))}>
          trace_id: <code class="text-zinc-200">{prop(@node, :trace_id, nil)}</code>
        </span>
      </footer>

      <.warnings warnings={prop(@node, :warnings, [])} />
    </article>
    """
  end

  attr(:node, :any, required: true)

  def agent_report_card(assigns) do
    assigns =
      assigns
      |> assign(:props, node_props(assigns.node))
      |> assign(:title, prop(assigns.node, :title, prop(assigns.node, :agent, "Agent report")))
      |> assign(:summary, prop(assigns.node, :summary, prop(assigns.node, :content, nil)))

    ~H"""
    <article
      id={"stocksage-card-#{@node.id}"}
      class="rounded border border-zinc-800 bg-zinc-900 p-4 text-zinc-100 shadow-sm"
      data-stocksage-component="agent_report_card"
      aria-labelledby={title_id(@node)}
    >
      <header class="flex flex-col gap-3 md:flex-row md:items-start md:justify-between">
        <div class="min-w-0">
          <p class="flex items-center gap-2 text-sm font-semibold uppercase text-sky-300">
            <.icon name="hero-document-chart-bar-micro" class="size-4" /> Specialist
          </p>
          <h2 id={title_id(@node)} class="mt-1 text-xl font-semibold tracking-normal">
            {@title}
          </h2>
          <p :if={present?(@summary)} class="mt-2 max-w-3xl text-sm text-zinc-300">
            {@summary}
          </p>
        </div>
        <.status_badge status={prop(@node, :status, nil)} />
      </header>

      <dl class="mt-4 grid gap-3 text-sm md:grid-cols-4">
        <.metric label="Role" value={prop(@node, :role, "specialist")} />
        <.metric label="Rating" value={prop(@node, :rating, "pending")} />
        <.metric label="Confidence" value={confidence(prop(@node, :confidence, nil))} />
        <.metric label="Mode" value={prop(@node, :generation_mode, "deterministic")} />
      </dl>

      <.key_points points={prop(@node, :key_points, prop(@node, :evidence, []))} />
      <.warnings warnings={prop(@node, :warnings, [])} />
    </article>
    """
  end

  attr(:node, :any, required: true)

  def parity_card(assigns) do
    assigns =
      assigns
      |> assign(:props, node_props(assigns.node))
      |> assign(:title, prop(assigns.node, :title, "Native/Python parity"))
      |> assign(:summary, prop(assigns.node, :summary, prop(assigns.node, :body, nil)))

    ~H"""
    <article
      id={"stocksage-card-#{@node.id}"}
      class="rounded border border-zinc-800 bg-zinc-900 p-4 text-zinc-100 shadow-sm"
      data-stocksage-component="parity_card"
      aria-labelledby={title_id(@node)}
    >
      <header class="flex flex-col gap-3 md:flex-row md:items-start md:justify-between">
        <div class="min-w-0">
          <p class="flex items-center gap-2 text-sm font-semibold uppercase text-violet-300">
            <.icon name="hero-scale-micro" class="size-4" /> Parity
          </p>
          <h2 id={title_id(@node)} class="mt-1 text-xl font-semibold tracking-normal">
            {@title}
          </h2>
          <p :if={present?(@summary)} class="mt-2 max-w-3xl text-sm text-zinc-300">
            {@summary}
          </p>
        </div>
        <.status_badge status={parity_status(@node)} />
      </header>

      <dl class="mt-4 grid gap-3 text-sm md:grid-cols-4">
        <.metric
          label="Native"
          value={prop(@node, :native_rating, prop(@node, :native_status, "pending"))}
        />
        <.metric
          label="Python"
          value={prop(@node, :python_rating, prop(@node, :python_status, "pending"))}
        />
        <.metric label="Agreement" value={prop(@node, :rating_agreement, "unknown")} />
        <.metric label="Confidence delta" value={prop(@node, :confidence_delta, "unknown")} />
      </dl>

      <.warnings warnings={[prop(@node, :native_error, nil), prop(@node, :python_error, nil)]} />
    </article>
    """
  end

  attr(:node, :any, required: true)

  def debate_round_card(assigns) do
    assigns =
      assigns
      |> assign(:props, node_props(assigns.node))
      |> assign(:title, prop(assigns.node, :title, "Debate round"))
      |> assign(:summary, prop(assigns.node, :summary, prop(assigns.node, :stance, nil)))

    ~H"""
    <article
      id={"stocksage-card-#{@node.id}"}
      class="rounded border border-zinc-800 bg-zinc-900 p-4 text-zinc-100 shadow-sm"
      data-stocksage-component="debate_round_card"
      aria-labelledby={title_id(@node)}
    >
      <header class="flex flex-col gap-3 md:flex-row md:items-start md:justify-between">
        <div class="min-w-0">
          <p class="flex items-center gap-2 text-sm font-semibold uppercase text-amber-300">
            <.icon name="hero-chat-bubble-left-right-micro" class="size-4" /> Debate
          </p>
          <h2 id={title_id(@node)} class="mt-1 text-xl font-semibold tracking-normal">
            {@title}
          </h2>
          <p :if={present?(@summary)} class="mt-2 max-w-3xl text-sm text-zinc-300">
            {@summary}
          </p>
        </div>
        <.status_badge status={prop(@node, :status, nil)} />
      </header>

      <dl class="mt-4 grid gap-3 text-sm md:grid-cols-4">
        <.metric label="Round" value={prop(@node, :round, prop(@node, :round_index, "1"))} />
        <.metric label="Side" value={prop(@node, :side, prop(@node, :role, "unknown"))} />
        <.metric label="Agent" value={prop(@node, :agent, "unknown")} />
        <.metric label="Rating" value={prop(@node, :rating, "pending")} />
      </dl>

      <.key_points points={prop(@node, :counterpoints, prop(@node, :key_points, []))} />
      <.warnings warnings={prop(@node, :warnings, [])} />
    </article>
    """
  end

  attr(:status, :any, default: nil)

  defp status_badge(assigns) do
    ~H"""
    <span
      :if={present?(@status)}
      class={["rounded px-2 py-1 text-xs font-semibold", status_class(@status)]}
    >
      {humanize(@status)}
    </span>
    """
  end

  attr(:label, :string, required: true)
  attr(:value, :any, required: true)

  defp metric(assigns) do
    ~H"""
    <div class="rounded border border-zinc-800 bg-zinc-950 p-3">
      <dt class="text-xs uppercase text-zinc-500">{@label}</dt>
      <dd class="mt-1 break-words font-medium text-zinc-100">{format_value(@value)}</dd>
    </div>
    """
  end

  attr(:warnings, :any, default: [])

  defp warnings(assigns) do
    assigns = assign(assigns, :warnings, visible_list(assigns.warnings))

    ~H"""
    <ul :if={@warnings != []} class="mt-4 space-y-2 text-sm text-amber-200" aria-label="Warnings">
      <li
        :for={warning <- @warnings}
        class="rounded border border-amber-500/30 bg-amber-500/10 px-3 py-2"
      >
        {format_value(warning)}
      </li>
    </ul>
    """
  end

  attr(:points, :any, default: [])

  defp key_points(assigns) do
    assigns = assign(assigns, :points, visible_list(assigns.points))

    ~H"""
    <ul
      :if={@points != []}
      class="mt-4 grid gap-2 text-sm text-zinc-300 md:grid-cols-2"
      aria-label="Key points"
    >
      <li :for={point <- @points} class="rounded border border-zinc-800 bg-zinc-950 px-3 py-2">
        {format_value(point)}
      </li>
    </ul>
    """
  end

  defp node_props(%Node{props: props}) when is_map(props), do: props
  defp node_props(%{props: props}) when is_map(props), do: props
  defp node_props(_node), do: %{}

  defp prop(node, key, fallback) do
    props = node_props(node)

    case Map.fetch(props, key) do
      {:ok, value} -> value
      :error -> Map.get(props, Atom.to_string(key), fallback)
    end
  end

  defp title_id(%{id: id}), do: "stocksage-card-title-#{id}"

  defp present?(value) when value in [nil, ""], do: false
  defp present?([]), do: false
  defp present?(_value), do: true

  defp visible_list(value) when is_list(value) do
    value
    |> Enum.reject(&(not present?(&1)))
    |> Enum.take(6)
  end

  defp visible_list(value) when is_map(value),
    do: value |> Enum.take(6) |> Enum.map(&format_value/1)

  defp visible_list(value), do: if(present?(value), do: [value], else: [])

  defp confidence(value) when is_float(value), do: "#{round(value * 100)}%"
  defp confidence(value) when is_integer(value) and value <= 1, do: "#{value * 100}%"
  defp confidence(value) when is_integer(value), do: "#{value}%"
  defp confidence(value) when is_binary(value), do: value
  defp confidence(_value), do: "pending"

  defp parity_status(node) do
    case prop(node, :parity_pass, nil) do
      true -> "passed"
      false -> "review"
      _other -> prop(node, :status, nil)
    end
  end

  defp status_class(status) when status in [true, "passed", :passed, "completed", :completed],
    do: "bg-emerald-500/15 text-emerald-200"

  defp status_class(status) when status in [false, "review", :review, "blocked", :blocked],
    do: "bg-amber-500/15 text-amber-200"

  defp status_class(status) when status in ["failed", :failed, "error", :error],
    do: "bg-red-500/15 text-red-200"

  defp status_class(_status), do: "bg-zinc-800 text-zinc-200"

  defp humanize(value) when is_boolean(value), do: if(value, do: "passed", else: "review")
  defp humanize(value) when is_atom(value), do: value |> Atom.to_string() |> humanize()

  defp humanize(value) when is_binary(value),
    do: value |> String.replace("_", " ") |> String.trim()

  defp humanize(value), do: format_value(value)

  defp format_value({key, value}), do: "#{key}: #{format_value(value)}"
  defp format_value(value) when is_binary(value), do: value
  defp format_value(nil), do: ""
  defp format_value(value) when is_boolean(value), do: to_string(value)
  defp format_value(value) when is_atom(value), do: Atom.to_string(value)
  defp format_value(value) when is_number(value), do: to_string(value)
  defp format_value(value), do: inspect(value)
end
