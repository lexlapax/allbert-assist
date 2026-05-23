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
