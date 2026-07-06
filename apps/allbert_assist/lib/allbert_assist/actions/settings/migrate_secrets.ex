defmodule AllbertAssist.Actions.Settings.MigrateSecrets do
  @moduledoc """
  Migrate encrypted-store credentials into the OS vault (v0.62 M7, Locked
  Decision 12). Effectful (moves secret values), so `:settings_write` with
  `confirmation: :required`; named internal action in the
  `packaging-no-authority-change-001` allowance. Reads each tier-2
  (`secrets.yml.enc`) secret value and writes it to the resolved tier-1 OS
  vault, then reports per-ref status. No raw secret is logged, rendered, or
  placed in release evidence — only reference names and statuses. `dry_run`
  previews the reference set without moving anything.
  """

  use AllbertAssist.Action,
    permission: :settings_write,
    exposure: :internal,
    execution_mode: :settings_write,
    skill_backed?: false,
    confirmation: :required,
    resumable?: true,
    name: "migrate_secrets",
    description: "Migrate encrypted-store credentials into the OS vault (confirmation-gated).",
    category: "settings",
    tags: ["settings", "secrets", "vault", "confirmation"],
    schema: [
      dry_run: [type: :boolean, required: false],
      user_id: [type: :string, required: false]
    ],
    output_schema: [
      message: [type: :string, required: true],
      status: [type: :atom, required: true],
      permission_decision: [type: :map, required: true],
      migration: [type: :map, required: true],
      actions: [type: {:list, :map}, required: true]
    ]

  alias AllbertAssist.Security.PermissionGate
  alias AllbertAssist.Settings.Secrets
  alias AllbertAssist.Settings.Vault
  alias AllbertAssist.Settings.Vault.EncryptedFile

  @impl true
  def run(params, context) do
    permission_decision = PermissionGate.authorize(:settings_write, context)
    resolution = Vault.resolve()

    cond do
      Map.get(params, :dry_run, false) ->
        refs = migratable_refs()

        {:ok,
         result(:completed, permission_decision, %{
           target_tier: resolution.tier,
           target_notice: resolution.notice,
           refs: refs,
           executed: false
         })}

      not PermissionGate.allowed?(permission_decision) ->
        {:ok,
         %{
           message: permission_decision.reason,
           status: PermissionGate.response_status(permission_decision),
           permission_decision: permission_decision,
           migration: %{executed: false},
           actions: [action(:denied, permission_decision, %{executed: false})]
         }}

      resolution.tier != :os ->
        {:ok,
         result(:error, permission_decision, %{
           target_tier: resolution.tier,
           target_notice: resolution.notice,
           reason: "no OS vault reachable — migration target is not tier-1",
           executed: false
         })}

      true ->
        migrate(permission_decision, resolution, context)
    end
  end

  defp migrate(permission_decision, resolution, context) do
    results =
      Enum.map(migratable_refs(), fn ref ->
        with {:ok, value} <- EncryptedFile.get(ref, context),
             {:ok, _} <- Vault.put(ref, value, context) do
          %{ref: ref, status: :migrated}
        else
          _error -> %{ref: ref, status: :failed}
        end
      end)

    failed? = Enum.any?(results, &(&1.status == :failed))
    status = if failed?, do: :error, else: :completed

    {:ok,
     result(status, permission_decision, %{
       target_tier: resolution.tier,
       results: results,
       executed: true
     })}
  end

  # Reference names only — never values.
  defp migratable_refs do
    {:ok, statuses} = Secrets.list_secret_status()

    statuses
    |> Enum.filter(&(&1.status == :configured))
    |> Enum.map(& &1.secret_ref)
  end

  defp result(status, permission_decision, migration) do
    %{
      message: "Secret migration #{status} (target: #{migration[:target_tier]}).",
      status: status,
      permission_decision: permission_decision,
      migration: migration,
      actions: [action(status, permission_decision, migration)]
    }
  end

  defp action(status, permission_decision, metadata) do
    Map.merge(
      %{
        name: name(),
        status: status,
        permission: :settings_write,
        permission_decision: permission_decision
      },
      metadata
    )
  end
end
