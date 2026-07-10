# credo:disable-for-this-file Credo.Check.Readability.ModuleDoc
# Component docs are injected by AllbertAssistWeb.Workspace.Components.Base.

# v0.65 M4: the `:memory_review_card` component now renders the interactive
# `workspace:memory` review panel (AllbertAssistWeb.Workspace.Components.MemoryPanel),
# so the earlier unwired placeholder card module was retired here.

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
