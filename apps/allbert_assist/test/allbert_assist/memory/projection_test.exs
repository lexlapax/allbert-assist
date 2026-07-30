defmodule AllbertAssist.Memory.ProjectionTest do
  use ExUnit.Case, async: false

  @moduletag :home_fs_serial
  @moduletag :global_process_serial

  alias AllbertAssist.Memory
  alias AllbertAssist.Memory.Claims
  alias AllbertAssist.Memory.Claims.Format
  alias AllbertAssist.Memory.Projection
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

  test "complete rebuild promotes native and grandfathered claims with schema-1 control" do
    claim_id = Ecto.UUID.generate()
    assert {:ok, first} = Claims.append(claim_id, nil, transition(value: "native value"))

    assert {:ok, legacy_entry} =
             Memory.append(%{
               category: :notes,
               body: "kept before v1.3",
               summary: "Legacy value",
               actor: "local",
               agent: "test",
               channel: :test,
               source_signal_id: "legacy-signal"
             })

    legacy_path = legacy_entry.path
    assert {:ok, legacy_identity} = Claims.legacy_identity(legacy_path)

    assert {:ok, _reviewed} =
             Memory.review_entry(
               legacy_path,
               %{status: :kept, reviewed_by: "local", reviewed_at: "2026-07-29T12:00:00Z"},
               user_id: "local"
             )

    {:ok, projection} = Projection.start_link(root: Paths.memory_projection_root(), name: nil)
    assert %{ready?: false, control: %{"state" => "not_ready"}} = Projection.status(projection)

    assert {:ok, built} = Projection.rebuild(projection)
    assert built.claim_count == 2
    assert built.revision_count == 2
    assert built.excluded_count == 0
    assert built.projection_revision == 0
    assert built.generation_id =~ ~r/^[0-9a-f-]{36}$/

    assert {:ok, [native]} = Projection.history(claim_id, projection)
    assert native.value == "native value"
    assert native.revision_digest == first.tail_digest
    assert {:ok, [legacy]} = Projection.history(legacy_identity.claim_id, projection)
    assert legacy.sequence == 0
    assert legacy.value == "kept before v1.3"

    status = Projection.status(projection)
    assert status.ready?
    assert status.control["domain"] == "memory"
    assert status.control["schema_version"] == 1
    assert status.control["projection_revision"] == 0
    assert status.control["current_generation_id"] == built.generation_id
    assert status.control["builder_generation_id"] == nil
    assert status.control["state"] == "ready"
    assert status.control["dirty"] == false
    assert status.control["rebuild_phase"] == nil
    assert status.control["claim_stream_watermark"] == built.watermark

    control_path = Path.join(Paths.memory_projection_root(), "control.json")
    assert {:ok, persisted_control} = control_path |> File.read!() |> Jason.decode()
    assert persisted_control == status.control
    assert File.exists?(Path.join(Paths.memory_projection_root(), "current.sqlite3"))
    refute File.exists?(Path.join(Paths.memory_projection_root(), "previous.sqlite3"))

    GenServer.stop(projection)
  end

  test "incremental refresh advances revision once and rebuild changes only generation" do
    claim_id = Ecto.UUID.generate()
    assert {:ok, first} = Claims.append(claim_id, nil, transition(value: "first"))
    {:ok, projection} = Projection.start_link(root: Paths.memory_projection_root(), name: nil)
    assert {:ok, first_build} = Projection.rebuild(projection)

    archived = transition(state: "archived", value: "first")
    assert {:ok, second} = Claims.append(claim_id, first.tail_digest, archived)
    assert {:ok, refreshed} = Projection.refresh_claim(claim_id, projection)
    assert refreshed.projection_revision == 1
    assert refreshed.revision_count == 2
    assert {:ok, [kept, archived_row]} = Projection.history(claim_id, projection)
    assert kept.state == "kept"
    assert archived_row.state == "archived"
    assert archived_row.revision_digest == second.tail_digest
    assert Projection.status(projection).control["projection_revision"] == 1

    assert {:ok, second_build} = Projection.rebuild(projection)
    refute second_build.generation_id == first_build.generation_id
    assert second_build.projection_revision == 0
    assert Projection.status(projection).control["projection_revision"] == 0
    assert File.exists?(Path.join(Paths.memory_projection_root(), "previous.sqlite3"))

    GenServer.stop(projection)
    {:ok, restarted} = Projection.start_link(root: Paths.memory_projection_root(), name: nil)
    assert Projection.status(restarted).ready?
    assert {:ok, [_, restarted_archive]} = Projection.history(claim_id, restarted)
    assert restarted_archive.state == "archived"
    GenServer.stop(restarted)
  end

  test "bounded rebuild reports partial work and preserves the verified generation" do
    first_id = Ecto.UUID.generate()
    second_id = Ecto.UUID.generate()
    assert {:ok, _first} = Claims.append(first_id, nil, transition(value: "first bounded"))

    {:ok, projection} = Projection.start_link(root: Paths.memory_projection_root(), name: nil)
    assert {:ok, first_build} = Projection.rebuild(projection)
    assert {:ok, _second} = Claims.append(second_id, nil, transition(value: "second bounded"))

    assert {:error,
            {:memory_projection_rebuild_limit_exceeded,
             %{
               max_entries: 1,
               discovered_entries: 2,
               processed_entries: 0,
               partial?: true,
               degraded?: true
             }}} = Projection.rebuild_with_options([max_entries: 1], projection)

    status = Projection.status(projection)
    assert status.ready?
    assert status.control["current_generation_id"] == first_build.generation_id
    assert status.control["state"] == "degraded"
    assert status.control["dirty"]
    assert {:ok, [_row]} = Projection.history(first_id, projection)
    assert {:ok, []} = Projection.history(second_id, projection)
    GenServer.stop(projection)
  end

  test "corrupt, pending-manual, and duplicate claims are reported and excluded" do
    corrupt_id = Ecto.UUID.generate()
    assert {:ok, corrupt} = Claims.append(corrupt_id, nil, transition(value: "corrupt me"))
    assert {:ok, corrupt_stream} = Claims.read(corrupt_id)
    [record] = corrupt_stream.records
    tampered = put_in(record, ["payload", "value"], "forged")
    File.write!(corrupt.path, Format.render(nil, [tampered]))

    pending_id = Ecto.UUID.generate()
    assert {:ok, pending} = Claims.append(pending_id, nil, transition(value: "pending base"))
    assert {:ok, pending_stream} = Claims.read(pending_id)
    manual = manual_revision(pending_stream, "manual pending")
    File.write!(pending.path, Format.render(nil, pending_stream.records ++ [manual]))

    duplicate_id = Ecto.UUID.generate()
    assert {:ok, duplicate} = Claims.append(duplicate_id, nil, transition(value: "duplicate"))
    duplicate_path = Path.join([Memory.root(), "preferences", "duplicate.md"])
    File.mkdir_p!(Path.dirname(duplicate_path))
    File.cp!(duplicate.path, duplicate_path)

    {:ok, projection} = Projection.start_link(root: Paths.memory_projection_root(), name: nil)
    assert {:ok, built} = Projection.rebuild(projection)
    assert built.claim_count == 0
    assert built.revision_count == 0
    assert built.excluded_count == 4
    assert length(Projection.status(projection).diagnostics) == 4
    assert {:ok, []} = Projection.history(corrupt_id, projection)
    assert {:ok, []} = Projection.history(pending_id, projection)
    assert {:ok, []} = Projection.history(duplicate_id, projection)
    GenServer.stop(projection)
  end

  test "a corrupt current generation restarts not-ready instead of serving it" do
    claim_id = Ecto.UUID.generate()
    assert {:ok, _first} = Claims.append(claim_id, nil, transition())
    {:ok, projection} = Projection.start_link(root: Paths.memory_projection_root(), name: nil)
    assert {:ok, _built} = Projection.rebuild(projection)
    GenServer.stop(projection)

    current_path = Path.join(Paths.memory_projection_root(), "current.sqlite3")
    File.write!(current_path, "not sqlite")
    {:ok, restarted} = Projection.start_link(root: Paths.memory_projection_root(), name: nil)
    refute Projection.status(restarted).ready?
    assert {:error, :memory_projection_not_ready} = Projection.history(claim_id, restarted)
    GenServer.stop(restarted)
  end

  test "restart discards interrupted builders and keeps the verified current degraded" do
    claim_id = Ecto.UUID.generate()
    assert {:ok, _first} = Claims.append(claim_id, nil, transition())
    {:ok, projection} = Projection.start_link(root: Paths.memory_projection_root(), name: nil)
    assert {:ok, _built} = Projection.rebuild(projection)
    GenServer.stop(projection)

    root = Paths.memory_projection_root()
    control_path = Path.join(root, "control.json")
    control = control_path |> File.read!() |> Jason.decode!()
    interrupted_id = "018f3f4a-8b2c-7def-8abc-0123456789ab"

    interrupted =
      control
      |> Map.put("state", "rebuilding")
      |> Map.put("builder_generation_id", interrupted_id)
      |> Map.put("rebuild_phase", "paging")

    File.write!(control_path, Jason.encode!(interrupted))
    builder_path = Path.join(root, "build-#{interrupted_id}.sqlite3")
    File.write!(builder_path, "partial")
    File.write!(builder_path <> "-wal", "partial wal")

    {:ok, restarted} = Projection.start_link(root: root, name: nil)
    status = Projection.status(restarted)
    assert status.ready?
    assert status.control["state"] == "degraded"
    assert status.control["dirty"]
    assert status.control["builder_generation_id"] == nil
    assert status.control["rebuild_phase"] == nil
    assert status.control["last_error_code"] == "interrupted_rebuild"
    refute File.exists?(builder_path)
    refute File.exists?(builder_path <> "-wal")
    assert {:ok, [_row]} = Projection.history(claim_id, restarted)
    GenServer.stop(restarted)
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
      value: "projection value"
    }

    Enum.into(overrides, defaults)
  end

  defp manual_revision(stream, value) do
    payload =
      transition(value: value)
      |> Map.new(fn {key, item} -> {Atom.to_string(key), item} end)

    base = %{
      "schema_version" => 1,
      "claim_id" => stream.claim_id,
      "revision_id" => payload["revision_id"],
      "sequence" => length(stream.records) + 1,
      "previous_revision_digest" => stream.tail_digest,
      "payload" => payload,
      "payload_digest" => digest(Format.canonical_json(payload)),
      "transition_id" => payload["transition_id"],
      "state" => payload["state"],
      "recorded_at" => payload["recorded_at"],
      "valid_from" => payload["valid_from"],
      "valid_to" => payload["valid_to"],
      "actor" => payload["actor"],
      "action" => payload["action"],
      "normalizer_version" => 1,
      "authority_kind" => "manual_revision",
      "key_ref" => nil,
      "key_version" => nil,
      "integrity_tag" => nil
    }

    Map.put(base, "revision_digest", revision_digest(base))
  end

  defp revision_digest(record) do
    record
    |> Map.drop(~w[revision_digest integrity_tag])
    |> Format.canonical_json()
    |> digest()
  end

  defp digest(value),
    do: "sha256:" <> (:crypto.hash(:sha256, value) |> Base.encode16(case: :lower))

  defp temp_path(suffix) do
    Path.join(
      System.tmp_dir!(),
      "allbert-memory-projection-#{suffix}-#{System.unique_integer([:positive])}"
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
