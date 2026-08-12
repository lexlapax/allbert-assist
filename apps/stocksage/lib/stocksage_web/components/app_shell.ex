defmodule StockSageWeb.Components.AppShell do
  @moduledoc """
  Shared StockSage state panels for the retained analysis detail surface.
  """

  use AllbertAssistWeb, :html

  attr(:id, :string, required: true)
  attr(:title, :string, required: true)
  attr(:body, :string, default: nil)
  attr(:tone, :atom, default: :neutral)
  attr(:rest, :global)

  def state_panel(assigns) do
    ~H"""
    <section id={@id} class={["rounded border p-5", panel_class(@tone)]} {@rest}>
      <h2 class="text-lg font-semibold">{@title}</h2>
      <p :if={present?(@body)} class="mt-2 max-w-3xl text-sm text-zinc-300">{@body}</p>
    </section>
    """
  end

  attr(:id, :string, default: "stocksage-disabled")

  def disabled_state(assigns) do
    ~H"""
    <.state_panel
      id={@id}
      title="StockSage web surfaces are disabled"
      body="Enable stocksage.web.enabled in Settings Central to use this app surface."
      tone={:muted}
      role="status"
    />
    """
  end

  defp panel_class(:error), do: "border-red-500/40 bg-red-500/10"
  defp panel_class(:success), do: "border-emerald-500/40 bg-emerald-500/10"
  defp panel_class(:warning), do: "border-amber-500/40 bg-amber-500/10"
  defp panel_class(:muted), do: "border-zinc-800 bg-zinc-900"
  defp panel_class(_tone), do: "border-zinc-800 bg-zinc-900"

  defp present?(value) when value in [nil, ""], do: false
  defp present?(_value), do: true
end
