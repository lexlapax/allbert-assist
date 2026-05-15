defmodule AllbertAssist.Intent.Classifier.FakeClassifier do
  @moduledoc """
  Process-local fake classifier for tests.

  Configure the next result with `put_result/1`. No network or model calls are
  performed.
  """

  @behaviour AllbertAssist.Intent.Classifier.Behaviour

  @key {__MODULE__, :result}

  @spec put_result({:ok, map()} | {:error, term()}) :: :ok
  def put_result(result) do
    Process.put(@key, result)
    :ok
  end

  @impl true
  def classify(_candidate_summary, _context) do
    Process.get(@key, {:error, :not_configured})
  end
end
