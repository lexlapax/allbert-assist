defmodule AllbertAssist.Intent.ConversationContext do
  @moduledoc """
  Bounded, redacted multi-turn intent context (ADR 0019 §2).

  v0.54 M0 contract; built from the runtime-supplied `thread_context` in M4. It
  carries only a **bounded, redacted** recent-turn `summary` plus
  follow-up/antecedent signals (prior selected action/app, prior clarification)
  — never raw thread history, and never traced raw. Size is bounded by
  `intent.context_window`; gated by `intent.multiturn_enabled`.
  """
  alias AllbertAssist.Maps
  alias AllbertAssist.Runtime.Redactor
  alias AllbertAssist.Settings

  @summary_limit 600
  @line_limit 160

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

  @doc """
  Build a bounded, redacted context from the runtime `thread_context`
  (`%{messages: [%{role, content, ...}], ...}`). Returns `empty/0` when
  multi-turn context is disabled. Only the last `intent.context_window` turns are
  kept; each message's content is redacted and length-bounded so no raw history
  reaches the prompt. `opts` may override `:multiturn_enabled`, `:context_window`,
  and supply `:prior_action`/`:prior_app`/`:prior_clarification` antecedent
  signals (wired from the session/decision state in M5).
  """
  @spec from_thread_context(map(), keyword()) :: t()
  def from_thread_context(thread_context, opts \\ [])

  def from_thread_context(thread_context, opts) when is_map(thread_context) do
    if multiturn_enabled?(opts) do
      window = context_window(opts)
      messages = thread_context |> field(:messages) |> List.wrap()
      recent = if window <= 0, do: [], else: Enum.take(messages, -window)

      %__MODULE__{
        summary: summarize(recent),
        turn_count: length(recent),
        prior_action: Keyword.get(opts, :prior_action),
        prior_app: Keyword.get(opts, :prior_app),
        prior_clarification: Keyword.get(opts, :prior_clarification)
      }
    else
      empty()
    end
  end

  def from_thread_context(_other, _opts), do: empty()

  defp summarize([]), do: ""

  defp summarize(messages) do
    messages
    |> Enum.map(fn message ->
      role = message |> field(:role) |> to_string()

      content =
        message |> field(:content) |> to_string() |> Redactor.redact() |> bounded(@line_limit)

      "#{role}: #{content}"
    end)
    |> Enum.join("\n")
    |> bounded(@summary_limit)
  end

  defp bounded(string, limit) when is_binary(string) do
    if String.length(string) > limit, do: String.slice(string, 0, limit) <> "…", else: string
  end

  defp bounded(value, _limit), do: to_string(value)

  defp field(map, key), do: Maps.field_truthy(map, key)

  defp multiturn_enabled?(opts) do
    case Keyword.fetch(opts, :multiturn_enabled) do
      {:ok, value} -> !!value
      :error -> setting_bool("intent.multiturn_enabled", false)
    end
  end

  defp context_window(opts) do
    Keyword.get(opts, :context_window) || setting_int("intent.context_window", 6)
  end

  defp setting_bool(key, default) do
    case Settings.get(key) do
      {:ok, value} when is_boolean(value) -> value
      _other -> default
    end
  end

  defp setting_int(key, default) do
    case Settings.get(key) do
      {:ok, value} when is_integer(value) -> value
      _other -> default
    end
  end
end
