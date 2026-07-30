defmodule AllbertAssist.Search.DeletePurgeReconcileTest do
  use AllbertAssist.DataCase, async: false
  @moduletag :home_fs_serial

  alias AllbertAssist.Actions.Confirmations.ApproveConfirmation
  alias AllbertAssist.Actions.Runner
  alias AllbertAssist.Conversations
  alias AllbertAssist.Conversations.Corpus
  alias AllbertAssist.Repo
  alias AllbertAssist.Search
  alias AllbertAssist.Search.Control
  alias AllbertAssist.Search.Projection
  alias AllbertAssist.Search.Purge
  alias AllbertAssist.Search.Query
  alias AllbertAssist.Settings
  alias AllbertAssist.Settings.KeyCustody

  setup do
    original_settings = Application.get_env(:allbert_assist, Settings)

    root =
      Path.join(System.tmp_dir!(), "allbert-search-purge-#{System.unique_integer([:positive])}")

    projection_root = Path.join(root, "projection")
    Application.put_env(:allbert_assist, Settings, root: Path.join(root, "settings"))
    KeyCustody.invalidate(:all)
    start_supervised!({Projection, root: projection_root, name: Projection})

    on_exit(fn ->
      KeyCustody.invalidate(:all)
      restore_env(Settings, original_settings)
      File.rm_rf!(root)
    end)

    %{projection_root: projection_root}
  end

  test "confirmed purge denies eligible content then replaces every historical generation", %{
    projection_root: root
  } do
    fixture = "v13purgefixture#{System.unique_integer([:positive])}"
    assert {:ok, thread} = Conversations.create_general_thread("alice", "Purge")
    assert {:ok, target} = local_message(thread, "#{fixture} historical text")
    assert {:ok, survivor} = local_message(thread, "surviving searchable text")
    assert {:ok, _first} = Projection.rebuild("alice")
    assert {:ok, _second} = Projection.rebuild("alice")

    context = operator_context()

    assert {:ok, denied} =
             Runner.run(
               "purge_search_projection",
               %{target_kind: :source_ids, target_ids: [target.id]},
               context
             )

    assert denied.status == :failed
    assert denied.error == :purge_target_still_eligible

    seed_historical_generation_files(root, fixture)
    Repo.delete!(target)

    assert {:ok, pending} =
             Runner.run(
               "purge_search_projection",
               %{target_kind: :source_ids, target_ids: [target.id]},
               context
             )

    assert pending.status == :needs_confirmation
    assert pending.preview.target_kind == "source_ids"
    refute inspect(pending.confirmation) =~ fixture
    refute Map.has_key?(pending.confirmation["resume_params_ref"], "operator_id")

    assert {:ok, approved} =
             ApproveConfirmation.run(
               %{id: pending.confirmation_id, reason: "purge deleted fixture"},
               context
             )

    assert approved.status == :completed
    assert approved.confirmation["operator_resolution"]["target_status"] == "completed"
    assert Control.load(root) |> then(fn {:ok, manifest} -> manifest["phase"] end) == "complete"

    assert Enum.sort(Path.wildcard(Path.join(root, "*.sqlite3")) |> Enum.map(&Path.basename/1)) ==
             ["current.sqlite3"]

    refute Enum.any?(Path.wildcard(Path.join(root, "*.sqlite3*")), fn path ->
             File.read!(path) =~ fixture
           end)

    assert {:ok, target_query} = Query.parse(%{query: fixture})
    assert {:ok, %{candidates: []}} = Projection.candidates(target_query)
    assert {:ok, survivor_query} = Query.parse(%{query: "surviving"})
    assert {:ok, %{candidates: [%{source_id: id}]}} = Projection.candidates(survivor_query)
    assert id == survivor.id
  end

  test "startup keeps an interrupted purge fail closed and resumes the exact attempt", %{
    projection_root: root
  } do
    assert {:ok, thread} = Conversations.create_general_thread("alice", "Restart")
    assert {:ok, _message} = local_message(thread, "prepurge searchable fixture")
    assert {:ok, _build} = Projection.rebuild("alice")
    assert {:ok, _setting} = Settings.put("search.enabled", false)

    assert {:ok, preview} = Purge.preview(%{target_kind: :all}, "alice")

    params =
      Map.take(preview, [
        :target_kind,
        :target_ids,
        :source_classes,
        :expected_eligibility_epoch,
        :preview_binding,
        :key_ref,
        :key_version
      ])

    assert {:ok, scope} = Projection.purge_scope(%{"target_kind" => "all"})
    assert {:ok, %{"phase" => "pending"}} = Control.begin(root, params, scope, "conf_restart")
    assert {:ok, _setting} = Settings.put("search.enabled", true)

    stop_supervised!(Projection)
    start_supervised!({Projection, root: root, name: Projection})

    assert_eventually(fn -> Projection.status().diagnostics != [] end)
    assert {:ok, query} = Query.parse(%{query: "prepurge"})
    assert {:error, :search_purge_in_progress} = Projection.candidates(query)
    assert {:error, :search_purge_in_progress} = Projection.rebuild("alice")

    assert {:error, :search_purge_in_progress} =
             Search.query(%{query: "prepurge"}, %{
               operator_id: "alice",
               user_id: "alice",
               channel: "tui"
             })

    assert {:ok, managed} =
             Runner.run("rebuild_search_index", %{}, %{
               operator_id: "alice",
               user_id: "alice",
               channel: :job
             })

    assert managed.status == :error
    assert managed.error == :search_purge_in_progress

    assert {:ok, _setting} = Settings.put("search.enabled", false)

    assert {:ok, %{phase: :complete, ready?: false}} =
             Projection.purge(params, "alice", "conf_restart")

    assert {:error, :search_not_ready} = Projection.candidates(query)
    assert {:ok, %{"phase" => "complete"}} = Control.load(root)
    assert Path.wildcard(Path.join(root, "*.sqlite3*")) == []
  end

  test "startup idempotently completes every persisted post-pending purge phase", %{
    projection_root: root
  } do
    stop_supervised!(Projection)
    assert {:ok, _setting} = Settings.put("search.enabled", false)

    for {phase, index} <- Enum.with_index(~w[connections_closed files_replaced verified], 1) do
      phase_root = Path.join(root, phase)
      File.mkdir_p!(phase_root)
      target = %{"target_kind" => "all", "target_ids" => [], "source_classes" => []}

      scope = %{
        eligibility_epoch: Corpus.eligibility_epoch(:search),
        policy_epoch: 0,
        managed_files: [],
        generation_ids: []
      }

      assert {:ok, preview} = Control.bind_preview(target, scope)
      params = Map.drop(preview, [:managed_files, :generation_ids])
      confirmation_id = "conf_phase_#{index}"
      assert {:ok, manifest} = Control.begin(phase_root, params, scope, confirmation_id)
      assert {:ok, _advanced_manifest} = advance_to_phase(phase_root, manifest, phase)

      if phase == "connections_closed" do
        File.write!(Path.join(phase_root, "retired-fixture.sqlite3-wal"), "stale")
      end

      child_id = {:purge_phase, index}
      pid = start_supervised!({Projection, root: phase_root, name: nil}, id: child_id)

      assert_eventually(fn ->
        match?({:ok, %{"phase" => "complete"}}, Control.load(phase_root))
      end)

      assert %{purge_phase: "complete", ready?: false} = Projection.status(pid)
      stop_supervised!(child_id)
      assert Path.wildcard(Path.join(phase_root, "*.sqlite3*")) == []
    end
  end

  defp seed_historical_generation_files(root, fixture) do
    previous = Path.join(root, "previous.sqlite3")

    for name <- [
          "build-00000000-0000-7000-8000-000000000001.sqlite3",
          "failed-00000000-0000-7000-8000-000000000002.sqlite3",
          "retired-00000000-0000-7000-8000-000000000003.sqlite3",
          "pending-prune-00000000-0000-7000-8000-000000000004.sqlite3"
        ] do
      File.cp!(previous, Path.join(root, name))
      File.write!(Path.join(root, name <> "-wal"), fixture)
      File.write!(Path.join(root, name <> "-shm"), fixture)
    end
  end

  defp local_message(thread, content) do
    Conversations.append_user_message(thread, content, metadata: %{"channel" => "tui"})
  end

  defp operator_context do
    %{operator_id: "alice", user_id: "alice", actor: "alice", channel: :tui}
  end

  defp advance_to_phase(root, manifest, "connections_closed") do
    Control.transition(root, manifest, "pending", "connections_closed")
  end

  defp advance_to_phase(root, manifest, "files_replaced") do
    with {:ok, manifest} <- Control.transition(root, manifest, "pending", "connections_closed") do
      Control.transition(root, manifest, "connections_closed", "files_replaced")
    end
  end

  defp advance_to_phase(root, manifest, "verified") do
    with {:ok, manifest} <- Control.transition(root, manifest, "pending", "connections_closed"),
         {:ok, manifest} <-
           Control.transition(root, manifest, "connections_closed", "files_replaced") do
      Control.transition(root, manifest, "files_replaced", "verified")
    end
  end

  defp assert_eventually(fun, attempts \\ 50)
  defp assert_eventually(fun, 0), do: assert(fun.())

  defp assert_eventually(fun, attempts) do
    if fun.() do
      :ok
    else
      Process.sleep(10)
      assert_eventually(fun, attempts - 1)
    end
  end

  defp restore_env(module, nil), do: Application.delete_env(:allbert_assist, module)
  defp restore_env(module, value), do: Application.put_env(:allbert_assist, module, value)
end
