defmodule AllbertAssist.Objectives.Runs.Worker.Adapter do
  @moduledoc """
  Adapter contract for one ephemeral Objective worker execution.

  Adapters do not own durable Objective state and must execute the validated
  registered action through `AllbertAssist.Actions.Runner`.
  """

  @callback run(module(), map(), map(), keyword()) :: {:ok, map()} | {:error, term()}
end
