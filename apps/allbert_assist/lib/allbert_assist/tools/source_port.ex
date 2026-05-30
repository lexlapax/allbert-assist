defmodule AllbertAssist.Tools.SourcePort do
  @moduledoc """
  Behaviour for tool-discovery source adapters.

  Adapters search one source family, normalize every result to
  `AllbertAssist.Tools.ToolCandidate`, and leave authorization to the actions
  that orchestrate them.
  """

  alias AllbertAssist.Tools.ToolCandidate

  @type query :: String.t()
  @type opts :: map()

  @callback source_id() :: atom()
  @callback search(query(), opts()) :: {:ok, [ToolCandidate.t()]} | {:error, term()}
end
