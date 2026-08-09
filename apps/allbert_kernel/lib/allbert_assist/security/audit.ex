defmodule AllbertAssist.Security.Audit do
  @moduledoc """
  Security decision audit metadata helpers.

  v0.05 records audit-shaped metadata with decisions. Durable security audit
  persistence can build on this shape later.

  v0.31 kept this module as the compatibility implementation behind a
  runtime-facing facade. v1.4 M7.1 relocates it into the kernel with Security
  Central, so kernel callers use it directly and the facade forwards here.
  """

  alias AllbertAssist.Security.Redactor

  @doc "Build a redacted audit event map from a Security Central decision."
  @spec event(map()) :: map()
  def event(decision) when is_map(decision) do
    context = Map.get(decision, :context, %{})

    %{
      event: "security.decision",
      actor_id: get_in(context, [:actor, :id]),
      channel: get_in(context, [:channel, :name]),
      permission: Map.get(decision, :permission),
      action: get_in(context, [:action, :name]),
      skill: get_in(context, [:skill, :name]),
      decision: Map.get(decision, :decision),
      reason: Map.get(decision, :reason),
      policy_source: get_in(decision, [:policy, :source])
    }
    |> Redactor.redact()
  end
end
