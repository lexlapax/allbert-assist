defmodule AllbertAssist.Actions.Settings.VaultStatus do
  @moduledoc """
  Report the resolved vault tier + posture (v0.62 M7). Read-only: names the
  active tier and why it was chosen (explicit, never silent), whether an OS
  vault is reachable, and which provider keys are env-provided (tier 3) — names
  only, never secret values.
  """

  use AllbertAssist.Action,
    permission: :read_only,
    exposure: :internal,
    execution_mode: :settings_read,
    skill_backed?: false,
    confirmation: :not_required,
    name: "vault_status",
    description: "Report the resolved secret-vault tier and posture.",
    category: "settings",
    tags: ["settings", "secrets", "vault", "read_only", "operator"],
    schema: [surface: [type: :string, required: false]],
    output_schema: [
      message: [type: :string, required: true],
      status: [type: :atom, required: true],
      permission_decision: [type: :map, required: true],
      vault: [type: :map, required: true],
      actions: [type: {:list, :map}, required: true]
    ]

  alias AllbertAssist.Actions.Operator.Support
  alias AllbertAssist.Settings.Vault
  alias AllbertAssist.Settings.Vault.Env

  @impl true
  def run(_params, context) do
    Support.read_only(name(), context, fn permission_decision ->
      resolution = Vault.resolve()

      report = %{
        tier: resolution.tier,
        notice: resolution.notice,
        os_vault_available: Vault.os_vault_available?(),
        env_provided_keys: Env.env_provided()
      }

      {:ok,
       %{
         message: "Vault tier: #{resolution.tier} — #{resolution.notice}.",
         surface_payload: "Vault tier: #{resolution.tier}.",
         status: :completed,
         permission_decision: permission_decision,
         vault: report,
         actions: [Support.action(name(), :completed, permission_decision, report)]
       }}
    end)
  end
end
