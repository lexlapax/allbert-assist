defmodule AllbertResearch.Plugin do
  @moduledoc """
  Shipped v0.46 research delegate plugin.

  The plugin contributes Settings Central schema and starts the supervised
  `research.specialist` delegate agent. It registers no new actions and grants
  no browser authority; the agent's commands orchestrate existing actions
  through `AllbertAssist.Actions.Runner.run/3`.
  """

  use AllbertAssist.Plugin

  @impl true
  def plugin_id, do: "allbert.research"

  @impl true
  def display_name, do: "Allbert Research"

  @impl true
  def version, do: "0.46.0"

  @impl true
  def validate(_opts), do: :ok

  @impl true
  def apps, do: [AllbertResearch.App]

  @impl true
  def child_spec(_opts), do: AllbertResearch.Supervisor.child_spec([])

  @impl true
  def settings_schema, do: AllbertResearch.Settings.Fragment.schema()
end
