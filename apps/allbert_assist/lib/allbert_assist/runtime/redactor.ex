defmodule AllbertAssist.Runtime.Redactor do
  @moduledoc """
  Runtime-facing redaction facade.

  New runtime, app, plugin, workspace, CLI, LiveView, and future sandbox-trial
  code should use this module rather than depending directly on a subsystem
  redactor. v0.31 preserves the existing `AllbertAssist.Security.Redactor`
  policy exactly.
  """

  alias AllbertAssist.Security.Redactor, as: SecurityRedactor

  @type surface ::
          :signals
          | :traces
          | :audits
          | :cli
          | :live_view
          | :logs
          | :tests
          | :resource_access
          | :stocksage
          | :sandbox_trial

  @doc "Recursively redact sensitive keys, secret refs, structs, maps, and lists."
  @spec redact(term()) :: term()
  defdelegate redact(value), to: SecurityRedactor

  @doc """
  Redact a value for a named runtime surface.

  v0.31 keeps one policy for all surfaces. The surface argument exists so
  downstream code can document where a redaction boundary is applied without
  introducing local redaction forks.
  """
  @spec redact(term(), surface()) :: term()
  def redact(value, _surface), do: redact(value)

  @doc "Return true if a key name should cause value redaction."
  @spec sensitive_key?(term()) :: boolean()
  defdelegate sensitive_key?(key), to: SecurityRedactor

  @doc "Return a short posture summary suitable for operator status."
  @spec posture() :: SecurityRedactor.posture()
  defdelegate posture(), to: SecurityRedactor
end
