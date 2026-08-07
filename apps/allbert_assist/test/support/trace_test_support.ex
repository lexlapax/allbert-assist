defmodule AllbertAssist.TraceTestSupport do
  @moduledoc false

  alias AllbertAssist.TestSupport.ReadyEffectContext

  def enable_trace_default!, do: enable_trace_default!(ReadyEffectContext.context())

  def enable_trace_default!(context) when is_map(context) do
    context = Map.merge(%{actor: "test", channel: :test, audit?: false}, context)

    case AllbertAssist.Settings.put("runtime.trace_default", "enabled", context) do
      {:ok, _resolved} ->
        :ok

      {:error, reason} ->
        raise "failed to enable runtime.trace_default in test: #{inspect(reason)}"
    end
  end
end
