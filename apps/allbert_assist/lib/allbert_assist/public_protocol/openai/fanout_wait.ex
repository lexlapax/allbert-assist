defmodule AllbertAssist.PublicProtocol.OpenAI.FanoutWait do
  @moduledoc false

  alias AllbertAssist.Runtime

  @spec await(String.t(), String.t(), non_neg_integer()) :: term()
  @spec notify(map(), reference()) :: :ok

  if Mix.env() == :test do
    def await(parent_id, user_id, timeout_ms) do
      case Application.get_env(:allbert_assist_web, :openai_fanout_awaiter) do
        awaiter when is_function(awaiter, 3) -> awaiter.(parent_id, user_id, timeout_ms)
        _default -> Runtime.await_fanout(parent_id, user_id, timeout_ms)
      end
    end

    def notify(epoch, barrier_ref) do
      case Application.get_env(:allbert_assist_web, :openai_fanout_wait_observer) do
        observer when is_pid(observer) ->
          send(observer, {:openai_fanout_waiting, self(), epoch, barrier_ref})

        _none ->
          :ok
      end
    end
  else
    def await(parent_id, user_id, timeout_ms),
      do: Runtime.await_fanout(parent_id, user_id, timeout_ms)

    def notify(_epoch, _barrier_ref), do: :ok
  end
end
