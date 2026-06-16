defmodule AllbertAssist.Intent.ConversationContext do
  @moduledoc """
  Bounded, redacted multi-turn intent context (ADR 0019 §2).

  v0.54 M0 contract; built from the runtime-supplied `thread_context` in M4. It
  carries only a **bounded, redacted** recent-turn `summary` plus
  follow-up/antecedent signals (prior selected action/app, prior clarification)
  — never raw thread history, and never traced raw. Size is bounded by
  `intent.context_window`.
  """
  defstruct summary: "",
            prior_action: nil,
            prior_app: nil,
            prior_clarification: nil,
            turn_count: 0

  @type t :: %__MODULE__{
          summary: String.t(),
          prior_action: String.t() | nil,
          prior_app: String.t() | nil,
          prior_clarification: map() | nil,
          turn_count: non_neg_integer()
        }

  @doc "An empty context (no prior-turn signal)."
  @spec empty() :: t()
  def empty, do: %__MODULE__{}
end
