defmodule AllbertAssist.Intent.Router.Outcome do
  @moduledoc """
  The result of an `AllbertAssist.Intent.Router` decision (ADR 0060).

  `kind`:
    * `:execute`  — run `action_name` with `slots`. Still routed through the
      runner + permission + confirmation gates; the router grants no authority
      (ADR 0060 approval-gate separation).
    * `:clarify`  — ask one targeted question scoped to `shortlist`.
    * `:answer`   — answer directly (no tool).
    * `:none`     — out of scope; decline gracefully.
    * `:defer`    — the router declined; fall back to the deterministic engine
      decision (strategy `:deterministic`, model unavailable, or timeout).
  """
  @enforce_keys [:kind]
  defstruct kind: :defer,
            action_name: nil,
            slots: %{},
            confidence: nil,
            shortlist: [],
            question: nil,
            reason: nil,
            diagnostics: %{}

  @type kind :: :execute | :clarify | :answer | :none | :defer
  @type t :: %__MODULE__{
          kind: kind(),
          action_name: String.t() | nil,
          slots: map(),
          confidence: float() | nil,
          shortlist: [map()],
          question: String.t() | nil,
          reason: term(),
          diagnostics: map()
        }

  @spec execute(String.t(), map(), float() | nil, map()) :: t()
  def execute(action_name, slots \\ %{}, confidence \\ nil, diagnostics \\ %{}) do
    %__MODULE__{
      kind: :execute,
      action_name: action_name,
      slots: slots,
      confidence: confidence,
      diagnostics: diagnostics
    }
  end

  @spec clarify([map()], String.t(), map()) :: t()
  def clarify(shortlist, question, diagnostics \\ %{}) do
    %__MODULE__{kind: :clarify, shortlist: shortlist, question: question, diagnostics: diagnostics}
  end

  @spec answer(map()) :: t()
  def answer(diagnostics \\ %{}), do: %__MODULE__{kind: :answer, diagnostics: diagnostics}

  @spec none(map()) :: t()
  def none(diagnostics \\ %{}), do: %__MODULE__{kind: :none, diagnostics: diagnostics}

  @spec defer(term(), map()) :: t()
  def defer(reason \\ :unspecified, diagnostics \\ %{}),
    do: %__MODULE__{kind: :defer, reason: reason, diagnostics: diagnostics}
end
