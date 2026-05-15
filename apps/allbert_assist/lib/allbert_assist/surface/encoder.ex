defmodule AllbertAssist.Surface.Encoder do
  @moduledoc """
  Future adapter boundary from validated Allbert surfaces to AG-UI/A2UI events.

  v0.18 documents the translation point only. It does not add an AG-UI/A2UI
  package dependency, emit protocol events, or participate in LiveView
  rendering.
  """

  @spec to_a2ui(AllbertAssist.Surface.t()) :: {:error, :not_implemented}
  def to_a2ui(%AllbertAssist.Surface{}), do: {:error, :not_implemented}
end
