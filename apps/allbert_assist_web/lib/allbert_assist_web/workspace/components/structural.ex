# credo:disable-for-this-file Credo.Check.Readability.ModuleDoc
# Component docs are injected by AllbertAssistWeb.Workspace.Components.Base.

defmodule AllbertAssistWeb.Workspace.Components.Workspace do
  use AllbertAssistWeb.Workspace.Components.Base,
    component: :workspace,
    description: "Workspace shell"
end

defmodule AllbertAssistWeb.Workspace.Components.Canvas do
  use AllbertAssistWeb.Workspace.Components.Base,
    component: :canvas,
    description: "Persistent per-thread canvas"
end

defmodule AllbertAssistWeb.Workspace.Components.Tile do
  use AllbertAssistWeb.Workspace.Components.Base,
    component: :tile,
    description: "Canvas tile"
end

defmodule AllbertAssistWeb.Workspace.Components.EphemeralSurface do
  use AllbertAssistWeb.Workspace.Components.Base,
    component: :ephemeral_surface,
    description: "Shared ephemeral surface"
end

defmodule AllbertAssistWeb.Workspace.Components.Header do
  use AllbertAssistWeb.Workspace.Components.Base,
    component: :header,
    description: "Workspace header"
end

defmodule AllbertAssistWeb.Workspace.Components.BadgeStrip do
  use AllbertAssistWeb.Workspace.Components.Base,
    component: :badge_strip,
    description: "Status and objective badges"
end

defmodule AllbertAssistWeb.Workspace.Components.Tabs do
  use AllbertAssistWeb.Workspace.Components.Base,
    component: :tabs,
    description: "Workspace tabs"
end

defmodule AllbertAssistWeb.Workspace.Components.Tab do
  use AllbertAssistWeb.Workspace.Components.Base,
    component: :tab,
    description: "Workspace tab"
end

defmodule AllbertAssistWeb.Workspace.Components.TabPanel do
  use AllbertAssistWeb.Workspace.Components.Base,
    component: :tab_panel,
    description: "Workspace tab panel"
end

defmodule AllbertAssistWeb.Workspace.Components.Diff do
  use AllbertAssistWeb.Workspace.Components.Base,
    component: :diff,
    description: "Diff viewer"
end
