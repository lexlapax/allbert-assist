defmodule AllbertAssistWeb.V103.SidebarOwnershipTest do
  @moduledoc """
  v1.0.3 M2 permanent minimal-composition regression (ADR 0086 contract 1 +
  monolith-class corollary; `release.v103` step `v103_sidebar_ownership`).

  The retired campaign class — `SidebarConsolidationTest` "every destination in
  the enumerated inventory is reachable and deep-linkable", 20/20 full-monolith
  seeds, never in the gate lanes — is a sandbox OWNERSHIP-LEASE expiry, not a
  missing allowance:

    * `DBConnection.Ownership.Proxy` grants the sandbox owner a lease
      (`:ownership_timeout`) that defaults to 120_000 ms and is independent of
      ExUnit's per-test `:timeout` budget.
    * The sidebar sweep is the only test in the umbrella whose declared ExUnit
      budget (240 s) exceeds that lease. It measures 82.8 s solo (`--slowest`,
      recorded in the plan's M2 entry); under full-monolith load it crosses
      120 s, so the class is deterministic there and absent from the lighter
      gate lanes.
    * When the lease fires, the proxy disconnects, the shared owner goes down,
      the pool mode reverts to `:manual`, and the NEXT LiveView mount raises
      `DBConnection.OwnershipError: cannot find ownership process for
      #PID<…> ({Phoenix.LiveView, AllbertAssistWeb.WorkspaceLive, …})
      (AllbertAssist.Repo) using mode :manual` out of
      `WorkspaceLive.mount/3 → Conversations.recent_general_thread/1`.

  The fix is at the ownership root, never the symptom: `DataCase.setup_sandbox/1`
  now derives the lease from the test's declared budget
  (`sandbox_ownership_timeout/1`), so ExUnit's timeout — not the sandbox — is
  always the deadline that fires, for every DataCase and ConnCase test in the
  umbrella and therefore for every LiveView mount and spawned child that reaches
  the connection through the case-provided owner.
  """
  use AllbertAssistWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  alias AllbertAssist.DataCase
  alias AllbertAssist.Repo
  alias AllbertAssist.Theme.Layout
  alias AllbertAssist.Workspace.Catalog, as: WorkspaceCatalog
  alias Ecto.Adapters.SQL.Sandbox

  @moduletag :sidebar_ownership

  # `DBConnection.Ownership.Proxy`'s built-in lease, i.e. the pre-fix constant
  # this file regresses against. Kept literal on purpose: the regression must
  # cross the boundary the OLD code granted, not a value the new code computes.
  @pre_fix_lease_ms 120_000

  # A lease deliberately shorter than the work it has to cover, used to
  # reproduce the class deterministically without waiting for the real boundary.
  @expired_lease_ms 1_000

  describe "the campaign signature" do
    test "an expired sandbox lease strips the workspace LiveView of ownership at mount", %{
      conn: conn,
      sandbox_owner: sandbox_owner
    } do
      # Retire the case-provided (correctly sized) lease and re-checkout with a
      # lease shorter than a single workspace mount. This is the monolith
      # condition in miniature: the test is still legitimately running, but its
      # connection is gone.
      Sandbox.stop_owner(sandbox_owner)
      short_owner = Sandbox.start_owner!(Repo, shared: true, ownership_timeout: @expired_lease_ms)
      on_exit(fn -> if Process.alive?(short_owner), do: Sandbox.stop_owner(short_owner) end)

      # Real, on-path work that outlasts the lease: mount the workspace shell
      # until the lease has fired. No retry and no sleep — every iteration is
      # the exact production call chain the campaign failed in.
      error = mount_until_ownership_error(conn, deadline_after(@expired_lease_ms * 8))

      assert %DBConnection.OwnershipError{} = error
      assert Exception.message(error) =~ "cannot find ownership process"
      assert Exception.message(error) =~ "using mode :manual"
    end
  end

  describe "the ownership-lease contract" do
    test "the lease strictly outlives every declared ExUnit budget" do
      assert DataCase.sandbox_ownership_timeout(%{timeout: 240_000}) > 240_000
      assert DataCase.sandbox_ownership_timeout(%{timeout: 180_000}) > 180_000
      assert DataCase.sandbox_ownership_timeout(%{timeout: 60_000}) > 60_000
      assert DataCase.sandbox_ownership_timeout(%{timeout: :infinity}) == :infinity
    end

    # The declared budget of the retired class. The body drives real workspace
    # mounts until the wall clock passes the lease the PRE-FIX code granted
    # (120 s), then proves the sidebar neighborhood still resolves. Before the
    # fix this is RED with the campaign signature; after it, the lease is
    # 240 s + headroom and ExUnit's own budget is the only deadline.
    @tag timeout: 240_000
    test "the sidebar destination sweep survives past the pre-fix lease boundary", %{conn: conn} do
      deadline = deadline_after(@pre_fix_lease_ms + 5_000)

      mounts = mount_workspace_until(conn, deadline)
      assert mounts > 0

      destinations =
        Layout.current(%{})
        |> Layout.launcher_destinations(
          WorkspaceCatalog.known_destinations(%{registered_apps: []})
        )

      assert length(destinations) >= 19

      {:ok, view, _html} = live(conn, ~p"/workspace")

      for destination <- Enum.take(destinations, 3) do
        view
        |> element("#workspace-dest-#{destination.dom_id}")
        |> render_click()

        assert has_element_until?(
                 view,
                 "#workspace-shell[data-canvas-destination='#{destination.id}']"
               ),
               "selecting #{destination.id} did not resolve after the pre-fix lease boundary"
      end

      IO.puts(
        "v103-sidebar-ownership-001 status=pass lease_boundary_ms=#{@pre_fix_lease_ms} " <>
          "mounts=#{mounts} sweep=resolved"
      )
    end
  end

  # The canvas swap renders asynchronously, so a bare has_element?/2 straight
  # after render_click/1 races it — the v1.0.2 M8.6 destinations class, hit
  # again here during M2 verification (the boundary test failed once on the
  # third destination while the fix was in place). Poll on the same
  # 50ms x 20 budget as WorkspaceLiveCase.render_until/3.
  defp has_element_until?(view, selector, attempts \\ 20)

  defp has_element_until?(view, selector, 0), do: has_element?(view, selector)

  defp has_element_until?(view, selector, attempts) do
    if has_element?(view, selector) do
      true
    else
      Process.sleep(50)
      has_element_until?(view, selector, attempts - 1)
    end
  end

  defp deadline_after(ms), do: System.monotonic_time(:millisecond) + ms

  defp expired?(deadline), do: System.monotonic_time(:millisecond) >= deadline

  defp mount_workspace_until(conn, deadline, mounts \\ 0) do
    {:ok, view, _html} = live(conn, ~p"/workspace")
    assert has_element?(view, "#workspace-shell")

    if expired?(deadline) do
      mounts + 1
    else
      mount_workspace_until(conn, deadline, mounts + 1)
    end
  end

  defp mount_until_ownership_error(conn, deadline) do
    try do
      {:ok, _view, _html} = live(conn, ~p"/workspace")
      :ok
    rescue
      error in DBConnection.OwnershipError -> error
    catch
      :exit, {{%DBConnection.OwnershipError{} = error, _stack}, _call} -> error
    end
    |> case do
      %DBConnection.OwnershipError{} = error ->
        error

      :ok ->
        refute expired?(deadline),
               "the sandbox lease never expired: the workspace LiveView kept its ownership " <>
                 "for longer than the #{@expired_lease_ms}ms lease it was granted"

        mount_until_ownership_error(conn, deadline)
    end
  end
end
