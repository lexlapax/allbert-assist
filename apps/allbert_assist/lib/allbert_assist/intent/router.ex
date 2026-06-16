defmodule AllbertAssist.Intent.Router do
  @moduledoc """
  Intent router seam (ADR 0060). Maps a request + the ranked candidate set to a
  `AllbertAssist.Intent.Router.Outcome`.

  v0.54 M0 establishes the contract; the two-stage local implementation
  (embedding prefilter → constrained LLM disambiguation → confidence gate) is
  built across M1-M3 and wired into the engine in M5. Until then
  `intent.router_strategy` defaults to `:deterministic` and `route/3` defers to
  the deterministic engine decision.

  The router selects *which* action within the already-collected,
  registry-validated candidate set. It grants no authority: an `:execute`
  outcome still runs through the runner + permission + confirmation gates
  (ADR 0060 approval-gate separation).
  """
  alias AllbertAssist.Intent.Router.Outcome
  alias AllbertAssist.Settings

  defmodule Behaviour do
    @moduledoc "Behaviour for intent routers (ADR 0060)."

    @callback route(request :: map(), candidates :: [map()], context :: map()) ::
                {:ok, AllbertAssist.Intent.Router.Outcome.t()} | {:error, term()}
  end

  @default_router AllbertAssist.Intent.Router.DefaultRouter

  @spec strategy() :: :two_stage_local | :deterministic
  def strategy do
    # An app-env override (set in config/test.exs to :deterministic) takes
    # precedence so the test suite never reaches the live embedding/LLM path;
    # production reads the Settings Central default (`:two_stage_local`).
    case Application.get_env(:allbert_assist, :intent_router_strategy_override) do
      nil -> strategy_from_settings()
      override when is_atom(override) -> override
    end
  end

  defp strategy_from_settings do
    case Settings.get("intent.router_strategy") do
      {:ok, value} -> normalize_strategy(value)
      _other -> :deterministic
    end
  end

  @doc """
  Route a request over the collected candidate set.

  Returns `{:ok, Outcome.t()}`. An `Outcome` of kind `:defer` means the router
  declined and the caller should use the deterministic engine decision.
  """
  @spec route(map(), [map()], map()) :: {:ok, Outcome.t()} | {:error, term()}
  def route(request, candidates, context \\ %{}) when is_map(request) and is_list(candidates) do
    case strategy() do
      :two_stage_local -> router_impl().route(request, candidates, context)
      :deterministic -> {:ok, Outcome.defer(:strategy_deterministic)}
    end
  end

  defp router_impl, do: Application.get_env(:allbert_assist, :intent_router, @default_router)

  defp normalize_strategy("two_stage_local"), do: :two_stage_local
  defp normalize_strategy(:two_stage_local), do: :two_stage_local
  defp normalize_strategy(_other), do: :deterministic
end
