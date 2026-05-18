# credo:disable-for-this-file Credo.Check.Readability.ModuleDoc
# Component docs are injected by AllbertAssistWeb.Workspace.Components.Base.

defmodule AllbertAssistWeb.Workspace.Components.Route do
  use AllbertAssistWeb.Workspace.Components.Base,
    component: :route,
    description: "Registered navigation route"
end

defmodule AllbertAssistWeb.Workspace.Components.Timeline do
  use AllbertAssistWeb.Workspace.Components.Base,
    component: :timeline,
    description: "Runtime response timeline"
end

defmodule AllbertAssistWeb.Workspace.Components.Composer do
  use AllbertAssistWeb.Workspace.Components.Base,
    component: :composer,
    description: "Prompt composer"
end

defmodule AllbertAssistWeb.Workspace.Components.Panel do
  use AllbertAssistWeb.Workspace.Components.Base,
    component: :panel,
    description: "Workspace panel"
end

defmodule AllbertAssistWeb.Workspace.Components.Section do
  use AllbertAssistWeb.Workspace.Components.Base,
    component: :section,
    description: "Workspace section"
end

defmodule AllbertAssistWeb.Workspace.Components.Text do
  use AllbertAssistWeb.Workspace.Components.Base,
    component: :text,
    description: "Text block"
end

defmodule AllbertAssistWeb.Workspace.Components.List do
  use AllbertAssistWeb.Workspace.Components.Base,
    component: :list,
    description: "List"
end

defmodule AllbertAssistWeb.Workspace.Components.EmptyState do
  use AllbertAssistWeb.Workspace.Components.Base,
    component: :empty_state,
    description: "Empty state"
end

defmodule AllbertAssistWeb.Workspace.Components.Button do
  use AllbertAssistWeb.Workspace.Components.Base,
    component: :button,
    description: "Button"
end

defmodule AllbertAssistWeb.Workspace.Components.ActionButton do
  use AllbertAssistWeb.Workspace.Components.Base,
    component: :action_button,
    description: "Action button"
end

defmodule AllbertAssistWeb.Workspace.Components.StatusBadge do
  use AllbertAssistWeb.Workspace.Components.Base,
    component: :status_badge,
    description: "Status badge"
end
