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
    [fetch_variant!(@button_variants, variant, "button variant"), extra_class]
  end

  @doc "Returns the canonical compact button class for dense operator panels."
  def compact_button_class!(variant), do: button_class!(variant, "workspace-button-compact")

  @doc "Returns the canonical status-badge class for a declared tone."
  def status_badge_class!(tone, extra_class \\ nil) do
    ["workspace-status-pill", fetch_variant!(@status_tones, tone, "status tone"), extra_class]
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
    <div
      id={@overlay_id}
      class={["workspace-approval-overlay", @overlay_class]}
      data-workspace-pattern="modal"
      data-state="open"
      aria-hidden="false"
    >
      <section
        id={@id}
        class={["workspace-approval-modal", @class]}
        role="dialog"
        aria-modal="true"
        aria-labelledby={@labelledby}
        aria-describedby={@describedby}
        tabindex="-1"
        phx-hook="FocusTrap"
        phx-click-away={@click_away_event}
        phx-window-keydown={@dismiss_event}
        phx-key={@dismiss_key}
        phx-value-surface-id={@surface_id}
      >
        {render_slot(@inner_block)}
      </section>
    </div>
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

  defp click_away_event(%{click_away: true, dismiss_event: event}), do: event
  defp click_away_event(_assigns), do: nil

  defp dismiss_key(%{dismiss_event: event, dismiss_key: key}) when is_binary(event), do: key
  defp dismiss_key(_assigns), do: nil
end
