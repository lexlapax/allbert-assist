defmodule AllbertAssist.Runtime.Trace do
  @moduledoc """
  Runtime-facing trace facade.

  v0.31 preserves the existing markdown trace format and writer while giving
  actions, objectives, apps, plugins, and future sandbox-trial code one trace
  entrypoint.
  """

  alias AllbertAssist.Trace

  @type result :: Trace.result()

  @doc "Return true when runtime trace recording is enabled."
  @spec enabled?() :: boolean()
  @spec enabled?(map()) :: boolean()
  def enabled?(turn \\ %{}), do: Trace.enabled?(turn)

  @doc "Record one runtime turn as markdown when tracing is enabled."
  @spec record_turn(map()) :: result()
  defdelegate record_turn(turn), to: Trace

  @doc "Render one runtime turn as inspectable markdown trace text."
  @spec text(map()) :: String.t()
  defdelegate text(turn), to: Trace
end
