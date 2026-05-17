defmodule AllbertAssist.Objectives.Stage do
  @moduledoc "Objective engine stage vocabulary."

  @stages [
    :receive_input,
    :interpret_intent,
    :frame_objective,
    :propose_steps,
    :authorize_step,
    :execute_step,
    :observe_step,
    :advance_objective,
    :cancel_objective,
    :continue_objective,
    :prune_stale
  ]

  @doc "Return stage atoms."
  def stages, do: @stages

  @doc "Return stage names as strings for persistence."
  def names, do: Enum.map(@stages, &Atom.to_string/1)

  @doc "Normalize a stage atom or string to a persisted stage name."
  def normalize(stage) when is_atom(stage), do: stage |> Atom.to_string() |> normalize()

  def normalize(stage) when is_binary(stage) do
    if stage in names(), do: {:ok, stage}, else: {:error, {:unknown_stage, stage}}
  end

  def normalize(stage), do: {:error, {:unknown_stage, stage}}
end
