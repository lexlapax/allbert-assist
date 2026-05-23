defmodule AllbertAssist.Security.Decision do
  @moduledoc """
  Canonical Security Central decision construction.
  """

  alias AllbertAssist.Runtime.Audit
  alias AllbertAssist.Runtime.Redactor

  @doc "Build a canonical decision map with compatibility fields."
  @spec build(map()) :: map()
  def build(attrs) when is_map(attrs) do
    permission = Map.fetch!(attrs, :permission)
    decision = Map.fetch!(attrs, :decision)
    context = Map.get(attrs, :context, %{})
    risk = Map.get(attrs, :risk, %{tier: :critical, reasons: ["missing risk classification"]})
    policy = Map.get(attrs, :policy, %{})

    base = %{
      permission: permission,
      decision: decision,
      reason: Map.fetch!(attrs, :reason),
      requires_confirmation: decision == :needs_confirmation,
      source: Map.get(attrs, :source, __MODULE__),
      risk: risk,
      redaction: redaction(),
      trace: trace(permission, decision, risk, policy, context),
      context: context,
      trust_boundary: trust_boundary(context),
      policy: policy
    }

    base
    |> Map.put(:audit, Audit.security_event(base))
    |> Redactor.redact()
  end

  @doc "Convert any decision-like map to the compatibility field subset."
  @spec compatibility(map(), keyword()) :: map()
  def compatibility(decision, opts \\ []) when is_map(decision) do
    decision
    |> Map.take([:permission, :decision, :reason, :requires_confirmation, :source])
    |> maybe_put_source(Keyword.get(opts, :source))
  end

  defp maybe_put_source(decision, nil), do: decision
  defp maybe_put_source(decision, source), do: Map.put(decision, :source, source)

  defp redaction do
    %{
      obligations: [:redact_secrets, :redact_credentials],
      surfaces: [:signals, :traces, :audits, :cli, :live_view, :logs, :tests]
    }
  end

  defp trace(permission, decision, risk, policy, context) do
    %{
      permission: permission,
      decision: decision,
      risk_tier: Map.get(risk, :tier),
      requires_confirmation: decision == :needs_confirmation,
      policy_source: Map.get(policy, :source),
      trust_boundary: trust_boundary_name(context)
    }
  end

  defp trust_boundary(context) do
    %{
      channel: get_in(context, [:channel, :trust]),
      skill_trust: get_in(context, [:skill, :trust_status]),
      action_registered?: get_in(context, [:action, :registered?]),
      secret_status: get_in(context, [:secret_status]),
      external_content?: get_in(context, [:external_content, :present?])
    }
  end

  defp trust_boundary_name(context) do
    channel = get_in(context, [:channel, :trust]) || :unknown

    action =
      if get_in(context, [:action, :registered?]), do: :registered_action, else: :unknown_action

    "#{channel}_to_#{action}"
  end
end
