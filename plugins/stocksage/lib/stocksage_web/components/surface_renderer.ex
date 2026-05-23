defmodule StockSageWeb.Components.SurfaceRenderer do
  @moduledoc """
  StockSage app-surface dispatcher for validated Surface nodes.

  v0.31 marks this as a compatibility shim. M7 retires it when StockSage app
  surfaces dispatch through the shared Surface catalog renderer path.
  """

  use Phoenix.Component

  alias AllbertAssist.Surface.Node
  alias StockSageWeb.Components.Cards

  attr(:node, :any, required: true)

  def node(%{node: %Node{component: :analysis_card}} = assigns) do
    ~H"""
    <Cards.analysis_card node={@node} />
    """
  end

  def node(%{node: %Node{component: :agent_report_card}} = assigns) do
    ~H"""
    <Cards.agent_report_card node={@node} />
    """
  end

  def node(%{node: %Node{component: :parity_card}} = assigns) do
    ~H"""
    <Cards.parity_card node={@node} />
    """
  end

  def node(%{node: %Node{component: :debate_round_card}} = assigns) do
    ~H"""
    <Cards.debate_round_card node={@node} />
    """
  end

  def node(assigns) do
    ~H"""
    <article
      id={"stocksage-card-unsupported-#{node_id(@node)}"}
      class="rounded border border-zinc-800 bg-zinc-900 p-4 text-sm text-zinc-300"
      data-stocksage-component="unsupported"
      role="status"
    >
      Unsupported StockSage component: <code>{node_component(@node)}</code>
    </article>
    """
  end

  defp node_id(%Node{id: id}), do: id
  defp node_id(%{id: id}), do: id
  defp node_id(_node), do: "unknown"

  defp node_component(%Node{component: component}), do: component
  defp node_component(%{component: component}), do: component
  defp node_component(_node), do: "unknown"
end
