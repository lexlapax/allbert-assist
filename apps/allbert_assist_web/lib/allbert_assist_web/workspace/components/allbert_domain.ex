# credo:disable-for-this-file Credo.Check.Readability.ModuleDoc
# Component docs are injected by AllbertAssistWeb.Workspace.Components.Base.

defmodule AllbertAssistWeb.Workspace.Components.TraceLink do
  use AllbertAssistWeb.Workspace.Components.Base,
    component: :trace_link,
    description: "Trace link"
end

defmodule AllbertAssistWeb.Workspace.Components.TraceViewer do
  use AllbertAssistWeb.Workspace.Components.Base,
    component: :trace_viewer,
    description: "Trace viewer"
end

defmodule AllbertAssistWeb.Workspace.Components.Icon do
  use AllbertAssistWeb.Workspace.Components.Base,
    component: :icon,
    description: "Icon"
end

defmodule AllbertAssistWeb.Workspace.Components.Link do
  use AllbertAssistWeb.Workspace.Components.Base,
    component: :link,
    description: "Link"
end

defmodule AllbertAssistWeb.Workspace.Components.Divider do
  use AllbertAssistWeb.Workspace.Components.Base,
    component: :divider,
    description: "Divider"
end

defmodule AllbertAssistWeb.Workspace.Components.Table do
  use AllbertAssistWeb.Workspace.Components.Base,
    component: :table,
    description: "Table"
end

defmodule AllbertAssistWeb.Workspace.Components.Row do
  use AllbertAssistWeb.Workspace.Components.Base,
    component: :row,
    description: "Table row"
end

defmodule AllbertAssistWeb.Workspace.Components.Column do
  use AllbertAssistWeb.Workspace.Components.Base,
    component: :column,
    description: "Table column"
end

defmodule AllbertAssistWeb.Workspace.Components.ObjectiveCard do
  use AllbertAssistWeb.Workspace.Components.Base,
    component: :objective_card,
    description: "Objective summary card"
end

defmodule AllbertAssistWeb.Workspace.Components.ConfirmationCard do
  use AllbertAssistWeb.Workspace.Components.Base,
    component: :confirmation_card,
    description: "Confirmation summary card"
end

defmodule AllbertAssistWeb.Workspace.Components.ApprovalCard do
  use AllbertAssistWeb.Workspace.Components.Base,
    component: :approval_card,
    description: "Approval summary card"
end

defmodule AllbertAssistWeb.Workspace.Components.ApprovalInspector do
  use AllbertAssistWeb.Workspace.Components.Base,
    component: :approval_inspector,
    description: "Approval details inspector"
end
