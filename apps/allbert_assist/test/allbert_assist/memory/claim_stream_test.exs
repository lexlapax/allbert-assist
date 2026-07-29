defmodule AllbertAssist.Memory.ClaimStreamTest do
  use ExUnit.Case, async: false

  @moduletag :home_fs_serial
  @moduletag :global_process_serial

  alias AllbertAssist.Memory
  alias AllbertAssist.Memory.Claims
  alias AllbertAssist.Memory.Claims.Format
  alias AllbertAssist.Paths
  alias AllbertAssist.Settings
  alias AllbertAssist.Settings.KeyCustody

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

    on_exit(fn ->
      KeyCustody.invalidate(:all)
      File.rm_rf!(home)
      restore_env(original_env)
      restore_app_env(Paths, original_paths)
      restore_app_env(Settings, original_settings)
    end)

    {:ok, home: home}
  end

  test "native appends are authenticated, temporal, and exactly idempotent" do
    claim_id = Ecto.UUID.generate()
    first = transition(recorded_at: "2026-07-29T12:00:00Z", valid_from: "2026-01-01T00:00:00Z")

    assert {:ok, appended} = Claims.append(claim_id, nil, first)
    assert appended.outcome == :appended
    assert appended.sequence == 1
    assert {:ok, stream} = Claims.read(claim_id)
    assert stream.tail_digest == appended.tail_digest
    assert stream.status == :valid
    assert {:ok, current} = Claims.current(claim_id)
    assert current["payload"]["value"] == "The operator prefers tea ``` with breakfast."

    assert {:ok, retried} = Claims.append(claim_id, nil, first)
    assert retried.outcome == :already_committed
    assert retried.tail_digest == appended.tail_digest
    assert {:ok, %{records: [_one]}} = Claims.read(claim_id)

    assert {:error, :transition_id_conflict} =
             Claims.append(claim_id, nil, Map.put(first, :value, "conflicting retry"))

    second =
      transition(
        state: "archived",
        recorded_at: "2026-07-30T12:00:00Z",
        valid_from: "2026-06-01T00:00:00Z"
      )

    assert {:error, :stale_tail} = Claims.append(claim_id, nil, second)
    assert {:ok, second_append} = Claims.append(claim_id, appended.tail_digest, second)
    assert second_append.sequence == 2

    assert {:ok, as_known_before_archive} =
             Claims.as_of(claim_id, ~U[2026-02-01 00:00:00Z], ~U[2026-07-29 13:00:00Z])

    assert as_known_before_archive["revision_id"] == first.revision_id

    assert {:error, :not_effective} =
             Claims.as_of(claim_id, ~U[2026-07-01 00:00:00Z], ~U[2026-07-30 13:00:00Z])
  end

  test "same-tail concurrent writers linearize to one append" do
    claim_id = Ecto.UUID.generate()
    first = transition()
    assert {:ok, initial} = Claims.append(claim_id, nil, first)

    results =
      1..2
      |> Task.async_stream(
        fn index ->
          Claims.append(
            claim_id,
            initial.tail_digest,
            transition(value: "writer #{index}")
          )
        end,
        ordered: false,
        timeout: 5_000
      )
      |> Enum.map(fn {:ok, result} -> result end)

    assert Enum.count(results, &match?({:ok, %{outcome: :appended}}, &1)) == 1
    assert Enum.count(results, &(&1 == {:error, :stale_tail})) == 1
    assert {:ok, %{records: records}} = Claims.read(claim_id)
    assert length(records) == 2
  end

  test "payload tampering and forged digest-valid transitions quarantine" do
    claim_id = Ecto.UUID.generate()
    assert {:ok, appended} = Claims.append(claim_id, nil, transition())
    path = appended.path
    assert {:ok, stream} = Claims.read(claim_id)
    [record] = stream.records

    payload_tamper = put_in(record, ["payload", "value"], "tampered")
    File.write!(appended.path, Format.render(nil, [payload_tamper]))

    assert {:error, {:quarantined, :payload_digest_mismatch, ^path}} =
             Claims.read(claim_id)

    forged_payload = Map.put(record["payload"], "value", "forged")
    forged = Map.put(record, "payload", forged_payload)
    forged = Map.put(forged, "payload_digest", digest(Format.canonical_json(forged_payload)))
    forged = Map.put(forged, "revision_digest", revision_digest(forged))
    File.write!(appended.path, Format.render(nil, [forged]))

    assert {:error, {:quarantined, :invalid_integrity_tag, ^path}} =
             Claims.read(claim_id)
  end

  test "legacy identity is content-independent until exact lazy adoption" do
    notes = Path.join(Memory.root(), "notes")
    preferences = Path.join(Memory.root(), "preferences")
    File.mkdir_p!(notes)
    File.mkdir_p!(preferences)
    original_path = Path.join(notes, "breakfast.md")
    moved_path = Path.join(preferences, "breakfast.md")
    legacy = "# Breakfast\n\nTea, including ``` literal fences.\n"
    File.write!(original_path, legacy)

    assert {:ok, original_identity} = Claims.legacy_identity(original_path)
    File.write!(original_path, legacy <> "more text")
    assert {:ok, same_identity} = Claims.legacy_identity(original_path)
    assert same_identity.claim_id == original_identity.claim_id

    File.rename!(original_path, moved_path)
    assert {:ok, moved_identity} = Claims.legacy_identity(moved_path)
    refute moved_identity.claim_id == original_identity.claim_id

    assert {:ok, adopted} =
             Claims.append(
               moved_identity.claim_id,
               moved_identity.digest,
               transition(legacy_path: moved_path, legacy_digest: moved_identity.digest)
             )

    assert File.read!(moved_path) |> String.starts_with?(legacy <> "more text")
    assert {:ok, adopted_stream} = Claims.read(moved_identity.claim_id)
    assert adopted_stream.legacy?

    assert get_in(hd(adopted_stream.records), ["payload", "legacy_adopted"]) == %{
             "claim_id" => moved_identity.claim_id,
             "legacy_digest" => moved_identity.digest
           }

    adopted_move = Path.join(notes, "adopted-move.md")
    File.rename!(moved_path, adopted_move)
    assert {:ok, after_move} = Claims.read(moved_identity.claim_id)
    assert after_move.path == adopted_move

    next = transition(state: "archived")

    assert {:ok, %{sequence: 2}} =
             Claims.append(moved_identity.claim_id, adopted.tail_digest, next)
  end

  test "duplicate embedded ids fail closed and hidden temporary files are ignored" do
    claim_id = Ecto.UUID.generate()
    assert {:ok, appended} = Claims.append(claim_id, nil, transition())

    duplicate_dir = Path.join(Memory.root(), "notes")
    File.mkdir_p!(duplicate_dir)
    File.cp!(appended.path, Path.join(duplicate_dir, "duplicate.md"))
    assert {:error, :duplicate_claim_id} = Claims.read(claim_id)

    File.write!(Path.join(Paths.memory_claims_root(), ".ignored.md.tmp"), "not a stream")
    refute Enum.any?(Claims.claim_paths(), &(Path.basename(&1) == ".ignored.md.tmp"))
  end

  test "tombstones deny new appends and replacement modes remain private" do
    claim_id = Ecto.UUID.generate()
    tombstone = Path.join(Paths.memory_tombstones_root(), claim_id <> ".md")
    File.mkdir_p!(Path.dirname(tombstone))
    File.write!(tombstone, "content-free pending tombstone")
    assert {:error, :forgotten} = Claims.append(claim_id, nil, transition())

    File.rm!(tombstone)
    assert {:ok, first} = Claims.append(claim_id, nil, transition())
    assert {:ok, stat} = File.stat(first.path)
    assert Bitwise.band(stat.mode, 0o777) == 0o600

    File.chmod!(first.path, 0o640)

    assert {:ok, _second} =
             Claims.append(claim_id, first.tail_digest, transition(state: "archived"))

    assert {:ok, stat} = File.stat(first.path)
    assert Bitwise.band(stat.mode, 0o777) == 0o640
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
      value: "The operator prefers tea ``` with breakfast."
    }

    Enum.into(overrides, defaults)
  end

  defp revision_digest(record) do
    record
    |> Map.drop(~w[revision_digest integrity_tag])
    |> Format.canonical_json()
    |> digest()
  end

  defp digest(value) do
    "sha256:" <> (:crypto.hash(:sha256, value) |> Base.encode16(case: :lower))
  end

  defp temp_path(suffix) do
    Path.join(
      System.tmp_dir!(),
      "allbert-claim-stream-#{suffix}-#{System.unique_integer([:positive])}"
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
