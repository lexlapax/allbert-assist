defmodule AllbertAssist.Intent.EvalFixtures do
  @moduledoc """
  Deterministic fixtures for intent engine tests and evals.

  These helpers avoid model calls and external services. They only build
  request and candidate maps for focused tests.
  """

  alias AllbertAssist.Intent.Candidate

  def request(opts \\ []) do
    %{
      text: Keyword.get(opts, :text, "what can you do?"),
      channel: Keyword.get(opts, :channel, :test),
      user_id: Keyword.get(opts, :user_id, "local"),
      operator_id: Keyword.get(opts, :operator_id, Keyword.get(opts, :user_id, "local")),
      thread_id: Keyword.get(opts, :thread_id, "thr_eval"),
      session_id: Keyword.get(opts, :session_id),
      active_app: Keyword.get(opts, :active_app, :allbert),
      thread_context: Keyword.get(opts, :thread_context, %{messages: [], limit: 12}),
      metadata: Keyword.get(opts, :metadata, %{}),
      input_signal_id: Keyword.get(opts, :input_signal_id, "sig_eval")
    }
  end

  def candidate(opts \\ []) do
    defaults = %{
      kind: Keyword.get(opts, :kind, :direct_answer),
      id: Keyword.get(opts, :id, "direct_answer"),
      source: Keyword.get(opts, :source, :deterministic),
      score: Keyword.get(opts, :score, 1.0),
      status: Keyword.get(opts, :status, :selected),
      selected?: Keyword.get(opts, :selected?, true),
      reason: Keyword.get(opts, :reason, "Fixture candidate.")
    }

    defaults
    |> Map.merge(Map.new(opts))
    |> Candidate.new!()
  end
end
