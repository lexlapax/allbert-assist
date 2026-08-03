defmodule AllbertAssist.Memory.ProjectionBootstrapTest do
  @moduledoc """
  v1.3 M9.b.10.c — the path the rest of the Memory suite masks.

  Attended SV found that on a fresh Home nothing ever builds the first Memory
  projection generation, so a kept claim could never be retrieved. Every existing
  test hid it two ways: they call `Projection.rebuild/1` by hand before retrieving,
  and they start the owner with `name: nil`, so `Process.whereis(Projection)` is nil
  and a keep never even reaches `refresh_claim/1`. Production does neither.

  These rows exercise the unassisted path: a fresh root with no generation, an owner
  registered under its real name, and no manual rebuild anywhere.
  """

  use AllbertAssist.DataCase, async: false

  alias AllbertAssist.Jobs.Managed
  alias AllbertAssist.Memory.Projection
  alias AllbertAssist.Paths
  alias AllbertAssist.Settings
  alias AllbertAssist.Settings.KeyCustody

  setup do
    original_settings = Application.get_env(:allbert_assist, Settings)
    original_paths = Application.get_env(:allbert_assist, Paths)
    original_memory = Application.get_env(:allbert_assist, AllbertAssist.Memory)
    original_home = System.get_env("ALLBERT_HOME")

    root =
      Path.join(
        System.tmp_dir!(),
        "allbert-projection-bootstrap-#{System.unique_integer([:positive])}"
      )

    Application.delete_env(:allbert_assist, Paths)
    Application.delete_env(:allbert_assist, AllbertAssist.Memory)
    Application.put_env(:allbert_assist, Settings, root: Path.join(root, "settings"))
    System.put_env("ALLBERT_HOME", root)
    KeyCustody.invalidate(:all)

    on_exit(fn ->
      restore_env(Settings, original_settings)
      restore_env(Paths, original_paths)
      restore_env(AllbertAssist.Memory, original_memory)
      restore_system_env("ALLBERT_HOME", original_home)
      KeyCustody.invalidate(:all)
      File.rm_rf!(root)
    end)

    {:ok, root: root}
  end

  test "a fresh Home starts with no serving generation" do
    {:ok, projection} = start_owner(bootstrap_jobs?: false)

    status = Projection.status(projection)

    refute status.ready?,
           "a fresh root must not report ready; that would make the rest of this file vacuous"

    assert status.control["current_generation_id"] == nil
    assert status.control["state"] == "not_ready"
  end

  test "the owner kicks the managed rebuild when it boots without a generation" do
    assert {:ok, _results} = Managed.reconcile("local")
    before = managed_due_at("memory-index-rebuild")

    {:ok, projection} = start_owner(bootstrap_jobs?: true)
    # handle_continue runs before any call is served, so a served call means the
    # bootstrap already ran.
    _status = Projection.status(projection)

    assert managed_kicked?("memory-index-rebuild", before),
           "booting a not-ready projection with bootstrap_jobs?: true must kick " <>
             "memory-index-rebuild; before M9.b.10.a nothing ever created the first generation"
  end

  test "the owner does not kick when bootstrap is not requested" do
    assert {:ok, _results} = Managed.reconcile("local")
    before = managed_due_at("memory-index-rebuild")

    {:ok, projection} = start_owner(bootstrap_jobs?: false)
    _status = Projection.status(projection)

    refute managed_kicked?("memory-index-rebuild", before),
           "the bootstrap must stay opt-in so non-owner nodes never kick a rebuild"
  end

  test "a ready projection is not rebuilt again on boot" do
    {:ok, first} = start_owner(bootstrap_jobs?: false)
    assert {:ok, _build} = Projection.rebuild(first)
    assert Projection.status(first).ready?
    GenServer.stop(first)

    assert {:ok, _results} = Managed.reconcile("local")
    before = managed_due_at("memory-index-rebuild")

    {:ok, second} = start_owner(bootstrap_jobs?: true)
    assert Projection.status(second).ready?

    refute managed_kicked?("memory-index-rebuild", before),
           "an existing ready generation must be served as-is, not rebuilt on every boot"
  end

  # v1.3 M9.b.11.c. The guard here used to be `WriterLockHolder.enabled?()`, which
  # reads ALLBERT_HOLD_WRITER_LOCK. Mix.Tasks.Allbert.with_source_daemon_env/1 sets
  # that variable around startup and restores it in an `after` block, so in a live
  # daemon it described how the process was launched rather than whether this VM
  # owns the writer now. An attended run on 2026-08-03 watched a queued repair mark
  # the projection dirty while memory-index-rebuild was never kicked, leaving the
  # projection degraded with no path back. Ownership is now read from the holder
  # process, which is a fact about this VM.
  test "a queued repair kicks the managed rebuild when this VM owns the writer" do
    assert {:ok, _results} = Managed.reconcile("local")
    {:ok, projection} = start_owner(bootstrap_jobs?: false)
    assert {:ok, _build} = Projection.rebuild(projection)

    {:ok, holder} =
      Agent.start_link(fn -> :owner end, name: AllbertAssist.Runtime.WriterLock.Holder)

    on_exit(fn -> if Process.alive?(holder), do: Agent.stop(holder) end)

    before = managed_dirty_seq("memory-index-rebuild")
    Projection.queue_repair([:canonical_revalidation_failed], projection)
    _settled = Projection.status(projection)
    Process.sleep(200)

    assert managed_dirty_seq("memory-index-rebuild") > before,
           "queue_repair must reach Managed.kick when the writer-lock holder runs here"
  end

  test "a queued repair does not kick when this VM does not own the writer" do
    assert {:ok, _results} = Managed.reconcile("local")
    {:ok, projection} = start_owner(bootstrap_jobs?: false)
    assert {:ok, _build} = Projection.rebuild(projection)
    refute Process.whereis(AllbertAssist.Runtime.WriterLock.Holder)

    before = managed_dirty_seq("memory-index-rebuild")
    Projection.queue_repair([:canonical_revalidation_failed], projection)
    _settled = Projection.status(projection)
    Process.sleep(200)

    assert managed_dirty_seq("memory-index-rebuild") == before,
           "a non-owner must never kick a rebuild"
  end

  defp managed_dirty_seq(identity) do
    case managed_job(identity) do
      nil -> 0
      job -> job.metadata |> Kernel.||(%{}) |> Map.get("dirty_seq", 0)
    end
  end

  defp start_owner(opts) do
    # Registered under the real module name on purpose: ProposalReview and the
    # repair path both resolve the owner with Process.whereis(Projection), so an
    # unnamed owner silently skips the very code these rows cover.
    opts = Keyword.merge([root: Paths.memory_projection_root(), name: Projection], opts)
    {:ok, pid} = Projection.start_link(opts)
    on_exit(fn -> if Process.alive?(pid), do: GenServer.stop(pid) end)
    {:ok, pid}
  end

  defp managed_due_at(identity) do
    case managed_job(identity) do
      nil -> :absent
      job -> {job.id, job.next_due_at}
    end
  end

  defp managed_kicked?(identity, before) do
    case {before, managed_due_at(identity)} do
      {_before, :absent} -> false
      {:absent, _after} -> true
      {same, same} -> false
      {_before, _after} -> true
    end
  end

  defp managed_job(identity) do
    "local"
    |> AllbertAssist.Jobs.list_jobs(limit: 100)
    |> Enum.find(fn job -> job.name == identity end)
  end

  defp restore_env(module, nil), do: Application.delete_env(:allbert_assist, module)
  defp restore_env(module, config), do: Application.put_env(:allbert_assist, module, config)

  defp restore_system_env(name, nil), do: System.delete_env(name)
  defp restore_system_env(name, value), do: System.put_env(name, value)
end
