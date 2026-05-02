defmodule AllbertAssist.Security do
  @moduledoc """
  Security Central facade for policy evaluation and operator security status.

  v0.05 keeps execution outside this module. Security Central evaluates context
  and policy, then returns structured decisions for actions, traces, audits,
  and operator surfaces.
  """

  alias AllbertAssist.Security.Context
  alias AllbertAssist.Security.Decision
  alias AllbertAssist.Security.Policy
  alias AllbertAssist.Security.Risk
  alias AllbertAssist.Security.Status

  @doc "Return a structured Security Central decision for a permission class."
  @spec authorize(atom(), map()) :: map()
  def authorize(permission, context \\ %{}) when is_map(context) do
    security_context = Context.normalize(permission, context)
    policy = Policy.resolve(permission, security_context)
    risk = Risk.classify(permission, security_context)

    Decision.build(%{
      permission: permission,
      decision: policy.effective,
      reason: policy.reason,
      source: __MODULE__,
      risk: risk,
      policy: policy,
      context: security_context
    })
  end

  @doc "Return redacted, read-only operator security status."
  @spec status(map()) :: map()
  def status(context \\ %{}) when is_map(context), do: Status.summary(context)
end
