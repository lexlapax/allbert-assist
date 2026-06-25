defmodule AllbertAssist.TraceTestSupport do
  @moduledoc false

  def enable_trace_default! do
    case AllbertAssist.Settings.put("runtime.trace_default", "enabled", %{
           actor: "test",
           channel: :test,
           audit?: false
         }) do
      {:ok, _resolved} ->
        :ok

      {:error, reason} ->
        raise "failed to enable runtime.trace_default in test: #{inspect(reason)}"
    end
  end
end
