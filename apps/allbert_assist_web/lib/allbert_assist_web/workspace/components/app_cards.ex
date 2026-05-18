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
  use AllbertAssistWeb.Workspace.Components.Base,
    component: :analysis_card,
    description: "StockSage analysis card reserved for v0.27",
    stub?: true
end

defmodule AllbertAssistWeb.Workspace.Components.AgentReportCard do
  use AllbertAssistWeb.Workspace.Components.Base,
    component: :agent_report_card,
    description: "StockSage agent report card reserved for v0.27",
    stub?: true
end

defmodule AllbertAssistWeb.Workspace.Components.ParityCard do
  use AllbertAssistWeb.Workspace.Components.Base,
    component: :parity_card,
    description: "StockSage parity card reserved for v0.27",
    stub?: true
end

defmodule AllbertAssistWeb.Workspace.Components.DebateRoundCard do
  use AllbertAssistWeb.Workspace.Components.Base,
    component: :debate_round_card,
    description: "StockSage debate round card reserved for v0.27",
    stub?: true
end
