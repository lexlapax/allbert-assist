defmodule AllbertAssist.Memory.ForgetTest do
  use AllbertAssist.DataCase, async: false

  alias AllbertAssist.Actions.Confirmations.ApproveConfirmation
  alias AllbertAssist.Actions.Memory.ForgetMemoryClaim
  alias AllbertAssist.Actions.Memory.RebuildMemoryProjection
  alias AllbertAssist.Confirmations
  alias AllbertAssist.Memory
  alias AllbertAssist.Memory.Claims
  alias AllbertAssist.Memory.Forget
  alias AllbertAssist.Memory.Projection
  alias AllbertAssist.Paths
  alias AllbertAssist.Settings
  alias AllbertAssist.Settings.KeyCustody
  alias AllbertAssist.TestSupport.ReadyEffectContext

  @env_vars [
    "ALLBERT_HOME",
    "ALLBERT_HOME_DIR",
    "ALLBERT_MEMORY_ROOT",
    "ALLBERT_SETTINGS_ROOT",
    "ALLBERT_SETTINGS_MASTER_KEY"
  ]

  setup do
    original_env = Map.new(@env_vars, &{&1, System.get_env(&1)})
    original_paths = Application.get_env(:allbert_assist, Paths)
    original_settings = Application.get_env(:allbert_assist, Settings)

    Enum.each(@env_vars, &System.delete_env/1)
    Application.delete_env(:allbert_assist, Paths)
    Application.delete_env(:allbert_assist, Settings)

    home = temp_path("home")
    System.put_env("ALLBERT_HOME", home)
    KeyCustody.invalidate(:all)
    stop_projection()

    on_exit(fn ->
      stop_projection()
      KeyCustody.invalidate(:all)
      File.rm_rf!(home)
      restore_env(original_env)
      restore_app_env(Paths, original_paths)
      restore_app_env(Settings, original_settings)
    end)

    {:ok, home: home}
  end

  test "confirmed Forget writes a content-free tombstone first and replaces every old generation" do
    claim_id = Ecto.UUID.generate()
    secret_value = "private exact value 42817"
    assert {:ok, claim} = Claims.append(claim_id, nil, transition(value: secret_value))
    {:ok, _projection} = Projection.start_link()
    assert {:ok, _built} = Projection.rebuild()

    assert {:ok, preview} = Forget.preview(claim_id)
    assert preview.expected_tail_digest == claim.tail_digest
    assert preview.disclosure =~ "originating conversation is retained"
    assert preview.disclosure =~ "remains searchable"
    assert preview.disclosure =~ "canonical conversation delete"
    assert preview.disclosure =~ "Backups"

    assert {:ok, %{status: :complete, tombstone: tombstone}} =
             Forget.forget(
               claim_id,
               preview.expected_tail_digest,
               "operator:local",
               "privacy"
             )

    assert tombstone["phase"] == "complete"
    assert tombstone["reason_code"] == "privacy"
    assert tombstone["normalizer_version"] == 1
    assert tombstone["key_ref"] == "secret://system/integrity_v1"
    assert tombstone["suppression_token"] =~ ~r/^hmac-sha256:[0-9a-f]{64}$/
    assert tombstone["integrity_tag"] =~ ~r/^hmac-sha256:[0-9a-f]{64}$/
    refute inspect(tombstone) =~ secret_value
    refute File.exists?(claim.path)
    assert {:error, :not_found} = Claims.read(claim_id)
    assert {:ok, []} = Projection.history(claim_id)
    refute File.exists?(Path.join(Paths.memory_projection_root(), "previous.sqlite3"))
    assert Projection.status().control["previous_generation_id"] == nil
    assert {:ok, true} = Forget.suppressed_value?(secret_value)
    assert {:ok, false} = Forget.suppressed_value?(secret_value <> " changed")
    assert {:error, :forgotten} = Claims.append(claim_id, nil, transition(value: secret_value))

    assert {:ok, %{status: :already_complete}} = Forget.resume(claim_id)
  end

  test "registered Forget discloses the boundary and persists no claim content in confirmation" do
    claim_id = Ecto.UUID.generate()
    exact_value = "forget action exact value 81273"
    assert {:ok, _claim} = Claims.append(claim_id, nil, transition(value: exact_value))
    {:ok, _projection} = Projection.start_link()
    assert {:ok, _built} = Projection.rebuild()

    context =
      ReadyEffectContext.attach(%{
        user_id: "operator:local",
        actor: "operator:local",
        channel: :test,
        surface: "test"
      })

    assert {:ok, pending} =
             ForgetMemoryClaim.run(
               %{claim_id: claim_id, user_id: "operator:local", reason_code: "privacy"},
               context
             )

    assert pending.status == :needs_confirmation
    assert pending.preview["payload"]["value"] == exact_value
    assert pending.disclosure =~ "originating conversation is retained"
    assert pending.disclosure =~ "remains searchable"
    assert pending.disclosure =~ "canonical conversation delete"
    assert pending.disclosure =~ "Backups"

    assert {:ok, durable} = Confirmations.read(pending.confirmation_id)
    refute inspect(durable) =~ exact_value
    assert get_in(durable, ["params_summary", "disclosure"]) =~ "remains searchable"
    assert get_in(durable, ["params_summary", "normalizer_version"]) == 1

    assert {:ok, approved} =
             ApproveConfirmation.run(
               %{id: pending.confirmation_id, reason: "destructive boundary reviewed"},
               context
             )

    assert approved.status == :completed
    assert approved.confirmation["status"] == "approved"
    assert {:error, :not_found} = Claims.read(claim_id)
    refute inspect(approved) =~ "hmac-sha256:"
    assert {:ok, %{phase: :complete}} = Forget.recovery_status(claim_id)
  end

  test "registered Forget records approval when cleanup is pending" do
    claim_id = Ecto.UUID.generate()
    assert {:ok, _claim} = Claims.append(claim_id, nil, transition(value: "pending cleanup"))

    context =
      ReadyEffectContext.attach(%{
        user_id: "operator:local",
        actor: "operator:local",
        channel: :test,
        surface: "test"
      })

    assert {:ok, pending} =
             ForgetMemoryClaim.run(%{claim_id: claim_id, user_id: "operator:local"}, context)

    assert {:ok, approved} =
             ApproveConfirmation.run(%{id: pending.confirmation_id}, context)

    assert approved.confirmation["status"] == "approved"
    assert get_in(approved, [:actions, Access.at(0), :confirmation_metadata, :target_resumed?])
    assert {:ok, %{phase: :pending}} = Forget.recovery_status(claim_id)
    assert {:error, :not_found} = Claims.read(claim_id)
  end

  test "pending Forget survives projection outage and retry completes idempotently" do
    claim_id = Ecto.UUID.generate()
    assert {:ok, claim} = Claims.append(claim_id, nil, transition(value: "recover me"))

    assert {:error, :memory_projection_unavailable} =
             Forget.forget(
               claim_id,
               claim.tail_digest,
               "operator:local",
               "operator_requested"
             )

    refute File.exists?(claim.path)
    tombstone_path = Path.join(Paths.memory_tombstones_root(), claim_id <> ".md")
    assert File.read!(tombstone_path) =~ ~s("phase":"pending")
    assert {:error, :forgotten} = Claims.append(claim_id, nil, transition())

    {:ok, _projection} = Projection.start_link()
    status = Projection.status()
    refute status.ready?
    assert status.tombstone_count == 1

    assert {:ok, %{status: :complete}} = Forget.resume(claim_id)
    assert Projection.status().ready?
    assert File.read!(tombstone_path) =~ ~s("phase":"complete")
    assert {:ok, %{status: :already_complete}} = Forget.resume(claim_id)
  end

  test "managed rebuild action batches pending Forget recovery into one replacement" do
    claims =
      for value <- ["batch pending one", "batch pending two"] do
        claim_id = Ecto.UUID.generate()
        assert {:ok, claim} = Claims.append(claim_id, nil, transition(value: value))

        assert {:error, :memory_projection_unavailable} =
                 Forget.forget(
                   claim_id,
                   claim.tail_digest,
                   "operator:local",
                   "operator_requested"
                 )

        claim_id
      end

    {:ok, _projection} = Projection.start_link()
    refute Projection.status().ready?

    assert {:ok, rebuilt} =
             RebuildMemoryProjection.run(%{}, %{
               user_id: "operator:local",
               actor: "operator:local",
               channel: :test
             })

    assert rebuilt.status == :completed
    assert rebuilt.result.recovery.pending_count == 2
    assert rebuilt.result.recovery.completed_count == 2
    assert rebuilt.result.recovery.projection_replaced?
    assert rebuilt.result.proposal_recovery.attempted_count == 0
    assert rebuilt.result.batch_recovery.attempted_count == 0
    assert rebuilt.result.projection.recovered_generation?
    assert Projection.status().ready?
    refute File.exists?(Path.join(Paths.memory_projection_root(), "previous.sqlite3"))

    for claim_id <- claims do
      assert {:ok, %{phase: :complete}} = Forget.recovery_status(claim_id)
    end
  end

  test "managed rebuild action fails closed without opening a one-shot projection owner" do
    stop_projection()

    assert {:ok, response} =
             RebuildMemoryProjection.run(%{}, %{
               user_id: "operator:local",
               actor: "operator:local",
               channel: :test
             })

    assert response.status == :error
    assert response.error == :memory_projection_owner_unavailable
    assert response.message =~ "Attach to the running Allbert daemon"
    refute File.exists?(Paths.memory_projection_root())
  end

  test "copied unadopted legacy value remains suppressed under a new path identity" do
    legacy = "# Exact legacy value\n\nNever re-propose this exact text.\n"
    original_path = Path.join([Memory.root(), "notes", "legacy.md"])
    File.mkdir_p!(Path.dirname(original_path))
    File.write!(original_path, legacy)
    assert {:ok, identity} = Claims.legacy_identity(original_path)

    assert {:ok, adopted} =
             Claims.append(
               identity.claim_id,
               identity.digest,
               transition(
                 value: legacy,
                 legacy_path: original_path,
                 legacy_digest: identity.digest
               )
             )

    {:ok, _projection} = Projection.start_link()
    assert {:ok, _built} = Projection.rebuild()

    assert {:ok, %{status: :complete}} =
             Forget.forget(
               identity.claim_id,
               adopted.tail_digest,
               "operator:local",
               "incorrect"
             )

    copied_path = Path.join([Memory.root(), "preferences", "copied.md"])
    File.mkdir_p!(Path.dirname(copied_path))
    File.write!(copied_path, legacy)
    assert {:ok, copied_identity} = Claims.legacy_identity(copied_path)
    refute copied_identity.claim_id == identity.claim_id

    assert {:ok, rebuilt} = Projection.rebuild()
    assert rebuilt.claim_count == 0
    assert rebuilt.excluded_count == 1
    assert {:ok, []} = Projection.history(copied_identity.claim_id)
    assert Enum.any?(Projection.status().diagnostics, &(&1.code == "forgotten_value_suppressed"))
  end

  test "missing tombstone key keeps startup and suppression fail-closed", %{home: home} do
    claim_id = Ecto.UUID.generate()
    assert {:ok, claim} = Claims.append(claim_id, nil, transition(value: "key-bound value"))

    assert {:error, :memory_projection_unavailable} =
             Forget.forget(claim_id, claim.tail_digest, "operator:local", "privacy")

    secrets_path = Path.join([home, "settings", "secrets.yml.enc"])
    assert :ok = File.rm(secrets_path)
    KeyCustody.invalidate(:all)

    assert {:error, :tombstone_key_unavailable} = Forget.load_tombstones()
    assert {:error, :tombstone_key_unavailable} = Forget.suppressed_value?("key-bound value")

    {:ok, _projection} = Projection.start_link()
    status = Projection.status()
    refute status.ready?
    assert status.control["state"] == "degraded"
    assert status.diagnostics != []
  end

  test "invalid reason and stale tail create no tombstone" do
    claim_id = Ecto.UUID.generate()
    assert {:ok, claim} = Claims.append(claim_id, nil, transition())

    assert {:error, :invalid_forget_reason_code} =
             Forget.forget(claim_id, claim.tail_digest, "operator:local", "free form reason")

    refute File.exists?(Path.join(Paths.memory_tombstones_root(), claim_id <> ".md"))

    assert {:error, :stale_tail} =
             Forget.forget(
               claim_id,
               "sha256:" <> String.duplicate("0", 64),
               "operator:local",
               "privacy"
             )

    refute File.exists?(Path.join(Paths.memory_tombstones_root(), claim_id <> ".md"))
    assert {:error, :invalid_claim_id} = Forget.resume("../outside")
  end

  defp transition(overrides \\ []) do
    defaults = %{
      revision_id: Ecto.UUID.generate(),
      transition_id: Ecto.UUID.generate(),
      state: "kept",
      recorded_at: "2026-07-29T12:00:00Z",
      valid_from: nil,
      valid_to: nil,
      actor: "operator:local",
      action: "remember",
      value: "forget value"
    }

    Enum.into(overrides, defaults)
  end

  defp stop_projection do
    case Process.whereis(Projection) do
      nil ->
        :ok

      pid ->
        if Process.alive?(pid) do
          try do
            GenServer.stop(pid)
          catch
            :exit, _reason -> :ok
          end
        end
    end
  end

  defp temp_path(suffix) do
    Path.join(
      System.tmp_dir!(),
      "allbert-forget-#{suffix}-#{System.unique_integer([:positive])}"
    )
  end

  defp restore_env(env) do
    Enum.each(env, fn
      {key, nil} -> System.delete_env(key)
      {key, value} -> System.put_env(key, value)
    end)
  end

  defp restore_app_env(module, nil), do: Application.delete_env(:allbert_assist, module)
  defp restore_app_env(module, value), do: Application.put_env(:allbert_assist, module, value)
end
