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

  alias AllbertAssist.Confirmations
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

      # M8.14: an approved confirmation resumes the migration.
      approval_resume?(context) ->
        migrate_or_error(permission_decision, resolution, context)

      # M8.14: the settings_write floor is needs_confirmation for migrate_secrets
      # — create a durable confirmation the operator can approve.
      PermissionGate.response_status(permission_decision) == :needs_confirmation ->
        request_confirmation(permission_decision, resolution, context)

      PermissionGate.response_status(permission_decision) == :denied ->
        {:ok,
         %{
           message: permission_decision.reason,
           status: :denied,
           permission_decision: permission_decision,
           migration: %{executed: false},
           actions: [action(:denied, permission_decision, %{executed: false})]
         }}

      # M8.14 floor self-guard: reaching :allowed means the needs_confirmation
      # floor did NOT apply — i.e. this ran off the Runner without the
      # migrate_secrets action identity in context. Fail closed rather than
      # migrate unconfirmed.
      true ->
        {:ok,
         result(:error, permission_decision, %{
           target_tier: resolution.tier,
           reason:
             "migrate_secrets must run confirmation-gated through the action Runner; refusing an unidentified call",
           executed: false
         })}
    end
  end

  defp migrate_or_error(permission_decision, resolution, context) do
    if resolution.tier == :os do
      migrate(permission_decision, resolution, context)
    else
      {:ok,
       result(:error, permission_decision, %{
         target_tier: resolution.tier,
         target_notice: resolution.notice,
         reason: "no OS vault reachable — migration target is not tier-1",
         executed: false
       })}
    end
  end

  defp request_confirmation(permission_decision, resolution, context) do
    if resolution.tier == :os do
      {:ok, confirmation} =
        Confirmations.create(%{
          origin: origin(context),
          target_action: %{name: name(), module: inspect(__MODULE__)},
          target_permission: :settings_write,
          target_execution_mode: :settings_write,
          security_decision: permission_decision,
          params_summary: %{target_tier: resolution.tier, refs: migratable_refs()},
          resume_params_ref: %{}
        })

      {:ok,
       %{
         message:
           "Secret migration is ready for approval. Confirmation request: #{confirmation["id"]}. Nothing was moved.",
         status: :needs_confirmation,
         permission_decision: permission_decision,
         confirmation: confirmation,
         confirmation_id: confirmation["id"],
         migration: %{executed: false, target_tier: resolution.tier},
         actions: [
           action(:needs_confirmation, permission_decision, %{
             executed: false,
             confirmation_id: confirmation["id"]
           })
         ]
       }}
    else
      migrate_or_error(permission_decision, resolution, context)
    end
  end

  defp origin(context) do
    %{
      channel: Map.get(context, :channel, :unknown),
      actor: Map.get(context, :actor) || get_in(context, [:request, :operator_id]) || "local",
      surface: Map.get(context, :surface, "action")
    }
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

  defp approval_resume?(context) do
    get_in(context, [:confirmation, :approved?]) == true ||
      get_in(context, ["confirmation", "approved?"]) == true
  end
end
