defmodule AllbertAssist.Intent.Classifier.DefaultClassifier do
  @moduledoc """
  Placeholder model boundary for v0.19 intent classification.

  v0.19 wires the settings, redacted candidate summary, proposal validation,
  and trace diagnostics. The default boundary stays inert until a later
  milestone adds a concrete model invocation action.
  """

  @behaviour AllbertAssist.Intent.Classifier.Behaviour

  @impl true
  def classify(_candidate_summary, _context), do: {:error, :model_boundary_unavailable}
end
