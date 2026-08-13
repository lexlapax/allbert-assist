defmodule AllbertAssist.Security.V13MemoryEvalTest do
  @moduledoc "M5 denial and compatibility proofs for projection-backed Memory retrieval."

  use ExUnit.Case, async: false
  alias AllbertAssist.TestSupport.ReadyEffectContext

  @moduletag :security_eval_serial

  alias AllbertAssist.Actions.Memory.SearchMemory
  alias AllbertAssist.Intent.Engine
  alias AllbertAssist.Memory
  alias AllbertAssist.Memory.ActiveMemory
  alias AllbertAssist.Memory.Claims
  alias AllbertAssist.Memory.Claims.Format
  alias AllbertAssist.Memory.Projection
  alias AllbertAssist.Paths
  alias AllbertAssist.Settings
  alias AllbertAssist.Settings.KeyCustody

  @now "2026-07-29T12:00:00Z"

  setup do
    original_home = System.get_env("ALLBERT_HOME")
    original_paths = Application.get_env(:allbert_assist, Paths)
    original_memory = Application.get_env(:allbert_assist, Memory)
    original_settings = Application.get_env(:allbert_assist, Settings)
    home = temp_path()

    System.put_env("ALLBERT_HOME", home)
    Application.delete_env(:allbert_assist, Paths)
    Application.delete_env(:allbert_assist, Memory)
    Application.delete_env(:allbert_assist, Settings)
    KeyCustody.invalidate(:all)
    {:ok, projection} = Projection.start_link(root: Paths.memory_projection_root(), name: nil)

    on_exit(fn ->
      if Process.alive?(projection), do: GenServer.stop(projection)
      KeyCustody.invalidate(:all)
      restore_home(original_home)
      restore_env(Paths, original_paths)
      restore_env(Memory, original_memory)
      restore_env(Settings, original_settings)
      File.rm_rf!(home)
    end)

    {:ok, projection: projection, home: home}
  end

  test "absent, unreviewed, archived, corrupt, out-of-time, and wrong-scope values abstain", %{
    projection: projection
  } do
    allowed_id = Ecto.UUID.generate()

    assert {:ok, _allowed} =
             Claims.append(allowed_id, nil, transition(value: "v13 sentinel allowed"))

    archived_id = Ecto.UUID.generate()

    assert {:ok, archived_kept} =
             Claims.append(archived_id, nil, transition(value: "v13 sentinel archived"))

    assert {:ok, _archived} =
             Claims.append(
               archived_id,
               archived_kept.tail_digest,
               transition(state: "archived", value: "v13 sentinel archived")
             )

    future_id = Ecto.UUID.generate()

    assert {:ok, _future} =
             Claims.append(
               future_id,
               nil,
               transition(value: "v13 sentinel future", valid_from: "2030-01-01T00:00:00Z")
             )

    wrong_operator_id = Ecto.UUID.generate()

    assert {:ok, _wrong_operator} =
             Claims.append(
               wrong_operator_id,
               nil,
               transition(
                 value: "v13 sentinel wrong operator",
                 actor: "operator:bob",
                 operator_id: "bob"
               )
             )

    wrong_app_id = Ecto.UUID.generate()

    assert {:ok, _wrong_app} =
             Claims.append(
               wrong_app_id,
               nil,
               transition(
                 value: "v13 sentinel wrong app",
                 app_id: "stocksage",
                 namespace: "stocksage"
               )
             )

    corrupt_id = Ecto.UUID.generate()

    assert {:ok, corrupt} =
             Claims.append(corrupt_id, nil, transition(value: "v13 sentinel corrupt"))

    assert {:ok, corrupt_stream} = Claims.read(corrupt_id)
    [record] = corrupt_stream.records

    File.write!(
      corrupt.path,
      Format.render(nil, [put_in(record, ["payload", "value"], "forged")])
    )

    assert {:ok, _unreviewed} =
             Memory.append(%{
               category: :notes,
               body: "v13 sentinel unreviewed",
               actor: "local",
               agent: "security-eval",
               channel: :test,
               source_signal_id: "unreviewed"
             })

    assert {:ok, _build} = Projection.rebuild(projection)

    assert {:ok, result} =
             ActiveMemory.retrieve("v13 sentinel",
               user_id: "local",
               now: @now,
               projection: projection
             )

    assert [%{claim_id: ^allowed_id}] = result.chunks
    assert result.canonical_revalidation_failure_count == 0
  end

  test "archive and Forget races are omitted before prompt insertion and mark repair", %{
    projection: projection,
    home: home
  } do
    archived_id = Ecto.UUID.generate()
    forgotten_id = Ecto.UUID.generate()
    symlink_id = Ecto.UUID.generate()

    assert {:ok, archived_kept} =
             Claims.append(archived_id, nil, transition(value: "race sentinel"))

    assert {:ok, _forgotten_kept} =
             Claims.append(forgotten_id, nil, transition(value: "race sentinel"))

    assert {:ok, symlinked} =
             Claims.append(symlink_id, nil, transition(value: "race sentinel"))

    assert {:ok, _build} = Projection.rebuild(projection)

    assert {:ok, _archived} =
             Claims.append(
               archived_id,
               archived_kept.tail_digest,
               transition(state: "archived", value: "race sentinel")
             )

    File.mkdir_p!(Paths.memory_tombstones_root())
    File.write!(Path.join(Paths.memory_tombstones_root(), forgotten_id <> ".md"), "forgotten\n")

    outside_path = Path.join(home, "outside-memory-claim.md")
    File.rename!(symlinked.path, outside_path)
    File.ln_s!(outside_path, symlinked.path)

    assert {:ok, result} =
             ActiveMemory.retrieve("race sentinel",
               user_id: "local",
               now: @now,
               projection: projection
             )

    assert result.chunks == []
    assert result.canonical_revalidation_failure_count == 3
    assert Projection.status(projection).control["dirty"]
  end

  test "the poison legacy artifact is ignored and the frozen flag matrix remains asymmetric", %{
    projection: projection
  } do
    claim_id = Ecto.UUID.generate()

    assert {:ok, stream} =
             Claims.append(claim_id, nil, transition(value: "poison index sentinel"))

    assert {:ok, _build} = Projection.rebuild(projection)
    File.write!(Path.join(Memory.root(), ".index.json"), "not-json LEGACY_INDEX_SECRET")

    request = %{
      text: "recall poison index sentinel",
      user_id: "local",
      operator_id: "local",
      memory_projection: projection
    }

    assert indexed_memory_candidate?(Engine.collect_candidates(request))

    assert {:ok, projected} =
             SearchMemory.run(
               %{query: "poison index sentinel", user_id: "local"},
               %{user_id: "local", memory_projection: projection}
             )

    assert [%{path: path}] = projected.entries
    assert path == stream.path
    assert [%{source: :projection}] = projected.actions

    assert {:ok, _setting} =
             Settings.put(
               "memory.index_enabled",
               false,
               ReadyEffectContext.attach(%{audit?: false})
             )

    refute indexed_memory_candidate?(Engine.collect_candidates(request))

    assert {:ok, fallback} =
             SearchMemory.run(
               %{query: "poison index sentinel", user_id: "local"},
               %{user_id: "local", memory_projection: projection}
             )

    assert [%{path: ^path}] = fallback.entries
    assert [%{source: :markdown}] = fallback.actions
  end

  defp indexed_memory_candidate?(candidates) do
    Enum.any?(candidates, fn candidate ->
      candidate.kind == :memory and String.starts_with?(candidate.id, "markdown_memory:/")
    end)
  end

  defp transition(overrides) do
    defaults = %{
      revision_id: Ecto.UUID.generate(),
      transition_id: Ecto.UUID.generate(),
      state: "kept",
      recorded_at: "2026-07-29T10:00:00Z",
      valid_from: nil,
      valid_to: nil,
      actor: "operator:local",
      action: "proposal_kept",
      category: "preferences",
      operator_id: "local",
      namespace: "default",
      subject: "operator",
      predicate: "preference",
      value: "v13 memory value"
    }

    Enum.into(overrides, defaults)
  end

  defp temp_path do
    Path.join(
      System.tmp_dir!(),
      "allbert-v13-memory-eval-#{System.pid()}-#{System.unique_integer([:positive])}"
    )
  end

  defp restore_home(nil), do: System.delete_env("ALLBERT_HOME")
  defp restore_home(value), do: System.put_env("ALLBERT_HOME", value)

  defp restore_env(module, nil), do: Application.delete_env(:allbert_assist, module)
  defp restore_env(module, config), do: Application.put_env(:allbert_assist, module, config)
end
