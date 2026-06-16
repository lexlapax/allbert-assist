defmodule AllbertAssist.Intent.PendingClarification do
  @moduledoc """
  Short-lived "awaiting clarification" turn state (ADR 0034 / ADR 0060 clarify).

  v0.54 M0 contract; the TTL store + resolution are built in M5. The next turn
  resolves a reply against `options` (still registry-validated and
  proposal-only). State is thread/user-keyed and TTL-bounded for cross-user
  isolation (`intent.pending_clarification_ttl_ms`).
  """
  @enforce_keys [:thread_id, :options, :expires_at]
  defstruct thread_id: nil,
            user_id: nil,
            session_id: nil,
            prompt: nil,
            question: nil,
            options: [],
            created_at: nil,
            expires_at: nil

  @type option :: %{
          required(:kind) => atom() | String.t(),
          required(:id) => String.t(),
          optional(atom()) => any()
        }
  @type t :: %__MODULE__{
          thread_id: String.t() | nil,
          user_id: String.t() | nil,
          session_id: String.t() | nil,
          prompt: String.t() | nil,
          question: String.t() | nil,
          options: [option()],
          created_at: DateTime.t() | nil,
          expires_at: DateTime.t() | nil
        }

  @doc "True when `now` is at or past `expires_at`."
  @spec expired?(t(), DateTime.t()) :: boolean()
  def expired?(%__MODULE__{expires_at: nil}, _now), do: true

  def expired?(%__MODULE__{expires_at: expires_at}, %DateTime{} = now),
    do: DateTime.compare(now, expires_at) != :lt
end
