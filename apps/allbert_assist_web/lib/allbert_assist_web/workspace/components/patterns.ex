defmodule AllbertAssistWeb.Workspace.Components.Patterns do
  @moduledoc """
  Shared workspace design-system variants and accessible UI patterns.
  """

  use Phoenix.Component

  @button_variants %{
    "primary" => "workspace-button workspace-button-primary",
    "secondary" => "workspace-button workspace-button-secondary",
    "danger" => "workspace-button workspace-button-danger"
  }

  @status_tones %{
    "info" => "workspace-status-info",
    "neutral" => "workspace-status-neutral",
    "warning" => "workspace-status-warn",
    "warn" => "workspace-status-warn",
    "danger" => "workspace-status-danger",
    "error" => "workspace-status-danger",
    "success" => "workspace-status-success",
    "ok" => "workspace-status-success"
  }

  @doc "Returns the canonical button class for a declared variant."
  def button_class!(variant, extra_class \\ nil) do
    [fetch_variant!(@button_variants, variant || "primary", "button variant"), extra_class]
  end

  @doc "Returns the canonical compact button class for dense operator panels."
  def compact_button_class!(variant), do: button_class!(variant, "workspace-button-compact")

  @doc "Returns the canonical status-badge class for a declared tone."
  def status_badge_class!(tone, extra_class \\ nil) do
    ["workspace-status-pill", fetch_variant!(@status_tones, tone, "status tone"), extra_class]
  end

  attr :id, :string, required: true
  attr :message, :any, default: nil
  attr :title, :string, default: nil
  attr :tone, :string, default: "info"
  attr :class, :any, default: nil
  attr :live, :string, default: "polite"
  attr :rest, :global

  slot :inner_block
  slot :action

  def status_callout(assigns) do
    assigns = assign(assigns, :tone, normalize_variant(assigns.tone))

    ~H"""
    <section
      :if={present?(@message) or @inner_block != []}
      id={@id}
      class={["workspace-status-callout", @class]}
      data-workspace-pattern="status-callout"
      data-tone={@tone}
      role="status"
      aria-live={@live}
      {@rest}
    >
      <p :if={present?(@title)} class="workspace-callout-title">{@title}</p>
      <p :if={present?(@message)} class="workspace-callout-body">{@message}</p>
      {render_slot(@inner_block)}
      <div :if={@action != []} class="workspace-callout-actions">
        {render_slot(@action)}
      </div>
    </section>
    """
  end

  attr :id, :string, required: true
  attr :message, :any, default: nil
  attr :title, :string, default: nil
  attr :class, :any, default: nil
  attr :rest, :global

  slot :inner_block
  slot :action

  def error_callout(assigns) do
    ~H"""
    <section
      :if={present?(@message) or @inner_block != []}
      id={@id}
      class={["workspace-error-callout", @class]}
      data-workspace-pattern="error-callout"
      role="alert"
      {@rest}
    >
      <p :if={present?(@title)} class="workspace-callout-title">{@title}</p>
      <p :if={present?(@message)} class="workspace-callout-body">{@message}</p>
      {render_slot(@inner_block)}
      <div :if={@action != []} class="workspace-callout-actions">
        {render_slot(@action)}
      </div>
    </section>
    """
  end

  attr :id, :string, required: true
  attr :label, :string, required: true
  attr :detail, :string, default: nil
  attr :class, :any, default: nil
  attr :rest, :global

  slot :inner_block

  def loading_state(assigns) do
    ~H"""
    <section
      id={@id}
      class={["workspace-status-callout workspace-loading-state", @class]}
      data-workspace-pattern="loading-state"
      role="status"
      aria-live="polite"
      aria-busy="true"
      {@rest}
    >
      <p class="workspace-callout-title">{@label}</p>
      <p :if={present?(@detail)} class="workspace-callout-body">{@detail}</p>
      {render_slot(@inner_block)}
    </section>
    """
  end

  @doc "Returns the canonical class list for the shared table/list shell contract."
  def table_list_class(extra_class \\ nil), do: ["workspace-table-shell", extra_class]

  @doc "Returns root-safe attrs for stateful or stateless table/list renderers."
  def table_list_attrs(opts) do
    [
      {"data-workspace-pattern", "table-list"},
      {"data-row-count", Keyword.get(opts, :row_count)},
      {"data-max-rows", Keyword.get(opts, :max_rows)},
      {"aria-labelledby", Keyword.fetch!(opts, :title_id)}
    ]
    |> compact_attrs()
  end

  @doc "Returns the canonical class list for the shared table row contract."
  def table_row_class(extra_class \\ nil), do: ["workspace-table-row", extra_class]

  @doc "Returns root-safe attrs for stateful or stateless table row renderers."
  def table_row_attrs, do: [{"data-workspace-pattern", "table-row"}]

  @doc "Returns the canonical class list for the shared table column contract."
  def table_column_class(extra_class \\ nil), do: ["workspace-table-column", extra_class]

  @doc "Returns root-safe attrs for stateful or stateless table column renderers."
  def table_column_attrs, do: [{"data-workspace-pattern", "table-column"}]

  @doc "Returns the canonical class list for the shared modal overlay contract."
  def modal_overlay_class(extra_class \\ nil), do: ["workspace-approval-overlay", extra_class]

  @doc "Returns root-safe attrs for the shared modal overlay element."
  def modal_overlay_attrs do
    [
      {"data-workspace-pattern", "modal"},
      {"data-state", "open"},
      {"aria-hidden", "false"}
    ]
  end

  @doc "Returns the canonical class list for the shared modal dialog contract."
  def modal_section_class(extra_class \\ nil), do: ["workspace-approval-modal", extra_class]

  @doc "Returns root-safe attrs for stateful or stateless modal dialog renderers."
  def modal_section_attrs(opts) do
    [
      {"role", "dialog"},
      {"aria-modal", "true"},
      {"aria-labelledby", Keyword.fetch!(opts, :labelledby)},
      {"aria-describedby", Keyword.get(opts, :describedby)},
      {"tabindex", "-1"},
      {"phx-hook", "FocusTrap"},
      {"phx-click-away", Keyword.get(opts, :click_away_event)},
      {"phx-window-keydown", Keyword.get(opts, :dismiss_event)},
      {"phx-key", Keyword.get(opts, :dismiss_key, "escape")},
      {"phx-value-surface-id", Keyword.get(opts, :surface_id)}
    ]
    |> compact_attrs()
  end

  attr :id, :string, required: true
  attr :title, :string, required: true
  attr :summary, :string, default: nil
  attr :empty_message, :string, default: "Rows appear here."
  attr :row_count, :integer, default: nil
  attr :max_rows, :integer, default: nil
  attr :title_id, :string, default: nil
  attr :class, :any, default: nil
  attr :rest, :global

  slot :inner_block

  def table_list(assigns) do
    assigns = assign(assigns, :title_id, assigns.title_id || "#{assigns.id}-title")

    ~H"""
    <section
      id={@id}
      class={table_list_class(@class)}
      {table_list_attrs(title_id: @title_id, row_count: @row_count, max_rows: @max_rows)}
      {@rest}
    >
      <h2 id={@title_id} class="workspace-card-title">{@title}</h2>
      <p :if={present?(@summary)} class="workspace-table-summary">{@summary}</p>
      <div :if={@inner_block == []} class="workspace-table-empty">{@empty_message}</div>
      {render_slot(@inner_block)}
    </section>
    """
  end

  attr :id, :string, required: true
  attr :body, :any, required: true
  attr :class, :any, default: nil
  attr :rest, :global

  slot :inner_block

  def table_row(assigns) do
    ~H"""
    <div id={@id} class={table_row_class(@class)} {table_row_attrs()} {@rest}>
      <span :if={present?(@body)}>{@body}</span>
      {render_slot(@inner_block)}
    </div>
    """
  end

  attr :id, :string, required: true
  attr :body, :any, required: true
  attr :class, :any, default: nil
  attr :rest, :global

  slot :inner_block

  def table_column(assigns) do
    ~H"""
    <span
      id={@id}
      class={table_column_class(@class)}
      {table_column_attrs()}
      {@rest}
    >
      <span :if={present?(@body)}>{@body}</span>
      {render_slot(@inner_block)}
    </span>
    """
  end

  attr :id, :string, required: true
  attr :overlay_id, :string, default: nil
  attr :overlay_class, :any, default: nil
  attr :class, :any, default: nil
  attr :labelledby, :string, required: true
  attr :describedby, :string, default: nil
  attr :dismiss_event, :string, default: nil
  attr :dismiss_key, :string, default: "escape"
  attr :click_away, :boolean, default: false
  attr :surface_id, :string, default: nil

  slot :inner_block, required: true

  def workspace_modal(assigns) do
    assigns =
      assigns
      |> assign(:overlay_id, assigns.overlay_id || "#{assigns.id}-overlay")
      |> assign(:click_away_event, click_away_event(assigns))
      |> assign(:dismiss_key, dismiss_key(assigns))

    ~H"""
    <div id={@overlay_id} class={modal_overlay_class(@overlay_class)} {modal_overlay_attrs()}>
      <section
        id={@id}
        class={modal_section_class(@class)}
        {modal_section_attrs(
          labelledby: @labelledby,
          describedby: @describedby,
          click_away_event: @click_away_event,
          dismiss_event: @dismiss_event,
          dismiss_key: @dismiss_key,
          surface_id: @surface_id
        )}
      >
        {render_slot(@inner_block)}
      </section>
    </div>
    """
  end

  # ── Direction C (Soft Modern Depth) first-class variants (v0.61 M3; M10.2) ──────
  # The Direction C visual-language selection (ADR 0079) is realized as two reusable
  # registry components consuming the promoted :root tokens — `elevated_card` (panels,
  # jobs/objectives/landing) and `nav_pill` (grouped IA navigation) — plus two pattern
  # markers carried on the richer native surfaces: `chat-primary-hero` on the workspace
  # chat pane and `trust-soft-card` on the surface-policy panel. The native structures
  # are richer than a 2-zone/posture component, so a marker + the promoted-token CSS is
  # the honest wiring (M10.2 removed the never-rendered chat_primary_hero/trust_card
  # components and their orphan CSS rather than ship dead code).

  @doc "Direction C elevated/floating card variant class (soft elevation + large radius)."
  def elevated_card_class(extra_class \\ nil), do: ["allbert-elevated-card", extra_class]

  @doc "Direction C soft nav-pill variant class for the grouped IA navigation."
  def nav_pill_class(active? \\ false, extra_class \\ nil),
    do: ["allbert-nav-pill", active? && "allbert-nav-pill-active", extra_class]

  attr :id, :string, required: true
  attr :title, :string, default: nil
  attr :class, :any, default: nil
  attr :rest, :global
  slot :inner_block, required: true

  @doc "Direction C elevated/floating card — panels, chat surface, evidence & choice cards."
  def elevated_card(assigns) do
    ~H"""
    <section
      id={@id}
      class={elevated_card_class(@class)}
      data-workspace-pattern="elevated-card"
      data-workspace-variant="direction-c"
      {@rest}
    >
      <h2 :if={present?(@title)} class="workspace-card-title">{@title}</h2>
      {render_slot(@inner_block)}
    </section>
    """
  end

  attr :id, :string, required: true
  attr :label, :string, required: true
  attr :navigate, :string, required: true
  attr :active?, :boolean, default: false
  attr :class, :any, default: nil
  attr :rest, :global
  slot :icon

  @doc "Direction C soft nav-pill — one entry in the grouped IA navigation."
  def nav_pill(assigns) do
    ~H"""
    <.link
      id={@id}
      navigate={@navigate}
      class={nav_pill_class(@active?, @class)}
      data-workspace-pattern="nav-pill"
      data-workspace-variant="direction-c"
      aria-current={@active? && "page"}
      {@rest}
    >
      <span :if={@icon != []} class="allbert-nav-pill-icon" aria-hidden="true">
        {render_slot(@icon)}
      </span>
      <span class="allbert-nav-pill-label">{@label}</span>
    </.link>
    """
  end

  defp fetch_variant!(registry, value, label) do
    normalized = normalize_variant(value)

    case Map.fetch(registry, normalized) do
      {:ok, css_class} ->
        css_class

      :error ->
        known = registry |> Map.keys() |> Enum.sort() |> Enum.join(", ")

        raise ArgumentError,
              "unknown workspace #{label} #{inspect(value)}; expected one of #{known}"
    end
  end

  defp normalize_variant(value) when is_atom(value),
    do: value |> Atom.to_string() |> normalize_variant()

  defp normalize_variant(value) when is_binary(value),
    do: value |> String.trim() |> String.downcase()

  defp normalize_variant(value), do: to_string(value)

  defp present?(value) when is_binary(value), do: String.trim(value) != ""
  defp present?(nil), do: false
  defp present?(_value), do: true

  defp compact_attrs(attrs) do
    Enum.reject(attrs, fn {_key, value} -> is_nil(value) end)
  end

  defp click_away_event(%{click_away: true, dismiss_event: event}), do: event
  defp click_away_event(_assigns), do: nil

  defp dismiss_key(%{dismiss_event: event, dismiss_key: key}) when is_binary(event), do: key
  defp dismiss_key(_assigns), do: nil
end
