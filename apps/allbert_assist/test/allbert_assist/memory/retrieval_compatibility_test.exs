defmodule AllbertAssist.Memory.RetrievalCompatibilityTest do
  use ExUnit.Case, async: false

  @moduletag :db_serial

  alias AllbertAssist.Actions.Memory.SearchMemory
  alias AllbertAssist.Memory.ActiveMemory
  alias AllbertAssist.Memory.Claims
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

    home = temp_path()
    System.put_env("ALLBERT_HOME", home)
    KeyCustody.invalidate(:all)
    {:ok, projection} = Projection.start_link(root: Paths.memory_projection_root(), name: nil)

    on_exit(fn ->
      if Process.alive?(projection), do: GenServer.stop(projection)
      KeyCustody.invalidate(:all)
      File.rm_rf!(home)
      restore_env(original_env)
      restore_app_env(Paths, original_paths)
      restore_app_env(Settings, original_settings)
    end)

    {:ok, projection: projection}
  end

  test "an old kept claim remains retrievable through the projection", %{projection: projection} do
    claim_id = Ecto.UUID.generate()

    assert {:ok, _append} =
             Claims.append(
               claim_id,
               nil,
               transition(
                 recorded_at: "2020-01-01T00:00:00Z",
                 value: "The operator prefers durable metric measurements."
               )
             )

    assert {:ok, _build} = Projection.rebuild(projection)

    assert {:ok, result} =
             ActiveMemory.retrieve("durable metric measurements",
               user_id: "local",
               now: "2026-07-29T12:00:00Z",
               projection: projection
             )

    assert [%{claim_id: ^claim_id, body: body}] = result.chunks
    assert body == "The operator prefers durable metric measurements."
    assert is_binary(result.generation_id)
  end

  test "canonical archive after projection read is omitted and queues repair", %{
    projection: projection
  } do
    claim_id = Ecto.UUID.generate()
    assert {:ok, kept} = Claims.append(claim_id, nil, transition(value: "Stale prompt sentinel"))
    assert {:ok, _build} = Projection.rebuild(projection)

    assert {:ok, _archived} =
             Claims.append(
               claim_id,
               kept.tail_digest,
               transition(state: "archived", value: "Stale prompt sentinel")
             )

    assert {:ok, result} =
             ActiveMemory.retrieve("stale prompt sentinel",
               user_id: "local",
               now: "2026-07-29T12:00:00Z",
               projection: projection
             )

    assert result.chunks == []
    assert result.canonical_revalidation_failure_count == 1
    assert Projection.status(projection).control["dirty"]
  end

  test "known-at is explicit and retired history never enters the current prompt", %{
    projection: projection
  } do
    claim_id = Ecto.UUID.generate()

    assert {:ok, kept} =
             Claims.append(
               claim_id,
               nil,
               transition(recorded_at: "2026-01-01T00:00:00Z", value: "Temporal blue value")
             )

    assert {:ok, _archived} =
             Claims.append(
               claim_id,
               kept.tail_digest,
               transition(
                 state: "archived",
                 recorded_at: "2026-04-01T00:00:00Z",
                 value: "Temporal blue value"
               )
             )

    assert {:ok, _build} = Projection.rebuild(projection)

    assert {:ok, historical} =
             ActiveMemory.retrieve("temporal blue",
               user_id: "local",
               valid_at: "2026-03-01T00:00:00Z",
               known_at: "2026-03-01T00:00:00Z",
               now: "2026-07-29T12:00:00Z",
               projection: projection
             )

    assert [%{claim_id: ^claim_id}] = historical.chunks

    assert {:ok, current} =
             ActiveMemory.retrieve("temporal blue",
               user_id: "local",
               valid_at: "2026-07-29T12:00:00Z",
               known_at: "2026-07-29T12:00:00Z",
               now: "2026-07-29T12:00:00Z",
               projection: projection
             )

    assert current.chunks == []
  end

  test "Active Memory remains projection-backed when the legacy index flag is false", %{
    projection: projection
  } do
    claim_id = Ecto.UUID.generate()
    assert {:ok, _kept} = Claims.append(claim_id, nil, transition(value: "Flag independent fact"))
    assert {:ok, _build} = Projection.rebuild(projection)
    assert {:ok, _setting} = Settings.put("memory.index_enabled", false, %{audit?: false})

    assert {:ok, result} =
             ActiveMemory.retrieve("flag independent fact",
               user_id: "local",
               now: "2026-07-29T12:00:00Z",
               projection: projection
             )

    assert [%{claim_id: ^claim_id}] = result.chunks
  end

  test "search_memory uses bounded canonical Markdown when the legacy flag is false" do
    claim_id = Ecto.UUID.generate()

    assert {:ok, _kept} =
             Claims.append(claim_id, nil, transition(value: "Fallback canonical fact"))

    assert {:ok, _setting} = Settings.put("memory.index_enabled", false, %{audit?: false})

    assert {:ok, response} =
             SearchMemory.run(
               %{query: "fallback canonical", user_id: "local"},
               %{user_id: "local"}
             )

    assert response.status == :completed
    assert [%{path: path, match_reasons: reasons}] = response.entries
    assert {:ok, stream} = Claims.read(claim_id)
    assert path == stream.path
    assert "keyword:fallback" in reasons
    assert [%{source: :markdown}] = response.actions
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
      value: "projection retrieval value"
    }

    Enum.into(overrides, defaults)
  end

  defp temp_path do
    Path.join(
      System.tmp_dir!(),
      "allbert-v13-memory-retrieval-#{System.pid()}-#{System.unique_integer([:positive])}"
    )
  end

  defp restore_env(original) do
    Enum.each(original, fn
      {key, nil} -> System.delete_env(key)
      {key, value} -> System.put_env(key, value)
    end)
  end

  defp restore_app_env(module, nil), do: Application.delete_env(:allbert_assist, module)
  defp restore_app_env(module, value), do: Application.put_env(:allbert_assist, module, value)
end
