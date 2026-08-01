defmodule AllbertAssist.Objectives.Runs.Worker.ActionAdapter do
  @moduledoc """
  Ordinary one-shot Adapter for validated non-conversational Objective actions.

  The Adapter is deliberately stateless: the surrounding Lifecycle owns
  checkpoints and transitions, while the registered Runner remains the only
  action execution path.
  """

  @behaviour AllbertAssist.Objectives.Runs.Worker.Adapter

  alias AllbertAssist.Actions.Runner
  alias AllbertAssist.Settings.Store

  @impl true
  def run(action_module, params, context, _opts) do
    Store.with_resolved_settings(fn -> Runner.run(action_module, params, context) end)
  end
end
