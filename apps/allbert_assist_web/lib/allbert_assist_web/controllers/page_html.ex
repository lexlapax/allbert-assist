defmodule AllbertAssistWeb.PageHTML do
  @moduledoc """
  This module contains pages rendered by PageController.

  See the `page_html` directory for all templates available.
  """
  use AllbertAssistWeb, :html

  alias AllbertAssistWeb.Workspace.Components.Patterns

  embed_templates "page_html/*"
end
