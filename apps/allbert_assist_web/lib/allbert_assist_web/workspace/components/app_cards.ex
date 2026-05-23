# credo:disable-for-this-file Credo.Check.Readability.ModuleDoc
# Component docs are injected by AllbertAssistWeb.Workspace.Components.Base.

defmodule AllbertAssistWeb.Workspace.Components.MemoryReviewCard do
  use AllbertAssistWeb.Workspace.Components.Base,
    component: :memory_review_card,
    description: "Memory review card"
end

defmodule AllbertAssistWeb.Workspace.Components.JobCard do
  use AllbertAssistWeb.Workspace.Components.Base,
    component: :job_card,
    description: "Scheduled job card"
end

defmodule AllbertAssistWeb.Workspace.Components.ChannelCard do
  use AllbertAssistWeb.Workspace.Components.Base,
    component: :channel_card,
    description: "Channel status card"
end

defmodule AllbertAssistWeb.Workspace.Components.SettingsCard do
  use AllbertAssistWeb.Workspace.Components.Base,
    component: :settings_card,
    description: "Settings card"
end

defmodule AllbertAssistWeb.Workspace.Components.AnalysisCard do
  @moduledoc """
  Workspace adapter for the StockSage `:analysis_card` renderer.

  v0.31 marks this as a compatibility shim. M7 retires it when StockSage card
  renderers register through the shared Surface catalog.
  """

  use AllbertAssistWeb, :live_component

  @impl true
  def update(assigns, socket), do: {:ok, assign_stocksage_defaults(socket, assigns)}

  @impl true
  def render(assigns) do
    ~H"""
    <div data-workspace-stocksage-adapter="analysis_card">
      <StockSageWeb.Components.Cards.analysis_card node={@node} />
    </div>
    """
  end

  defp assign_stocksage_defaults(socket, assigns) do
    socket
    |> assign(assigns)
    |> assign_new(:renderer_context, fn -> %{} end)
    |> assign_new(:workspace_state, fn -> %{} end)
  end
end

defmodule AllbertAssistWeb.Workspace.Components.AgentReportCard do
  @moduledoc """
  Workspace adapter for the StockSage `:agent_report_card` renderer.

  v0.31 marks this as a compatibility shim. M7 retires it when StockSage card
  renderers register through the shared Surface catalog.
  """

  use AllbertAssistWeb, :live_component

  @impl true
  def update(assigns, socket), do: {:ok, assign_stocksage_defaults(socket, assigns)}

  @impl true
  def render(assigns) do
    ~H"""
    <div data-workspace-stocksage-adapter="agent_report_card">
      <StockSageWeb.Components.Cards.agent_report_card node={@node} />
    </div>
    """
  end

  defp assign_stocksage_defaults(socket, assigns) do
    socket
    |> assign(assigns)
    |> assign_new(:renderer_context, fn -> %{} end)
    |> assign_new(:workspace_state, fn -> %{} end)
  end
end

defmodule AllbertAssistWeb.Workspace.Components.ParityCard do
  @moduledoc """
  Workspace adapter for the StockSage `:parity_card` renderer.

  v0.31 marks this as a compatibility shim. M7 retires it when StockSage card
  renderers register through the shared Surface catalog.
  """

  use AllbertAssistWeb, :live_component

  @impl true
  def update(assigns, socket), do: {:ok, assign_stocksage_defaults(socket, assigns)}

  @impl true
  def render(assigns) do
    ~H"""
    <div data-workspace-stocksage-adapter="parity_card">
      <StockSageWeb.Components.Cards.parity_card node={@node} />
    </div>
    """
  end

  defp assign_stocksage_defaults(socket, assigns) do
    socket
    |> assign(assigns)
    |> assign_new(:renderer_context, fn -> %{} end)
    |> assign_new(:workspace_state, fn -> %{} end)
  end
end

defmodule AllbertAssistWeb.Workspace.Components.DebateRoundCard do
  @moduledoc """
  Workspace adapter for the StockSage `:debate_round_card` renderer.

  v0.31 marks this as a compatibility shim. M7 retires it when StockSage card
  renderers register through the shared Surface catalog.
  """

  use AllbertAssistWeb, :live_component

  @impl true
  def update(assigns, socket), do: {:ok, assign_stocksage_defaults(socket, assigns)}

  @impl true
  def render(assigns) do
    ~H"""
    <div data-workspace-stocksage-adapter="debate_round_card">
      <StockSageWeb.Components.Cards.debate_round_card node={@node} />
    </div>
    """
  end

  defp assign_stocksage_defaults(socket, assigns) do
    socket
    |> assign(assigns)
    |> assign_new(:renderer_context, fn -> %{} end)
    |> assign_new(:workspace_state, fn -> %{} end)
  end
end
