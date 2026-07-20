defmodule AllbertAssist.DataCase do
  @moduledoc """
  This module defines the setup for tests requiring
  access to the application's data layer.

  You may define functions here to be used as helpers in
  your tests.

  Finally, if the test case interacts with the database,
  we enable the SQL sandbox, so changes done to the database
  are reverted at the end of every test.

  Ownership modes (ADR 0086 contract 1, v1.0.3 M1):

    * `use AllbertAssist.DataCase, async: false` (the default) keeps the
      pre-phase-2 shared-owner mode: every process in the VM can reach the
      test's sandbox connection, which is exactly why these files sit in
      the serial `db_serial` lane.
    * `use AllbertAssist.DataCase, async: true, lane: :db_partition_safe`
      is the converted mode: each test starts a NON-shared sandbox owner,
      and collaborator processes that fall outside the automatic
      `$callers` chain (long-lived agents/GenServers and the Tasks they
      spawn) must be granted access explicitly via `allow_sandbox/2`.
      Repo-backed tests never become `pure_async` (SQLite single-writer
      reality); converted files land in the `db_partition_safe` lane and
      keep OS-process partition isolation.
  """

  use ExUnit.CaseTemplate

  alias AllbertAssist.Repo
  alias Ecto.Adapters.SQL.Sandbox

  using opts do
    lane = Keyword.get(opts, :lane, :db_serial)

    quote do
      @moduletag unquote(lane)

      alias AllbertAssist.Repo

      import Ecto
      import Ecto.Changeset
      import Ecto.Query
      import AllbertAssist.DataCase
    end
  end

  setup tags do
    AllbertAssist.DataCase.setup_sandbox(tags)
    :ok
  end

  # DBConnection's ownership lease (`:ownership_timeout`,
  # `DBConnection.Ownership.Proxy`) defaults to 120_000 ms and is completely
  # independent of ExUnit's per-test `:timeout` budget. When a test declares a
  # budget LONGER than the lease, the lease is the binding deadline: the proxy
  # disconnects the connection, the shared owner goes down, the pool mode
  # reverts to `:manual`, and every subsequent Repo call — including the ones a
  # freshly mounted LiveView makes — raises
  # `DBConnection.OwnershipError: cannot find ownership process … using mode
  # :manual`. That is the v1.0.3 M2 monolith class (ADR 0086 monolith-class
  # corollary).
  @dbconnection_default_ownership_timeout 120_000

  # The lease must outlive the budget so ExUnit's timeout, never the sandbox,
  # is the deadline that fires. The headroom covers the setup work that runs
  # before checkout and the `on_exit` cleanup that runs after the body.
  @ownership_headroom 30_000

  @doc """
  Sets up the sandbox based on the test tags. Returns the owner pid.
  """
  def setup_sandbox(tags) do
    pid =
      Sandbox.start_owner!(Repo,
        shared: not tags[:async],
        ownership_timeout: sandbox_ownership_timeout(tags)
      )

    # Tolerant of an owner the test retired itself (the M2 lease regression
    # replaces the case-provided owner); `stop_owner/1` on a dead pid exits.
    on_exit(fn -> if Process.alive?(pid), do: Sandbox.stop_owner(pid) end)
    pid
  end

  @doc """
  The sandbox ownership lease for a test, derived from its declared ExUnit
  budget (ADR 0086 contract 1, v1.0.3 M2).

  The invariant: the lease STRICTLY exceeds the test's own `:timeout` tag, so a
  test can never outlive its sandbox connection. A test that declares no
  integer budget (or `:infinity`) keeps the DBConnection default / an infinite
  lease respectively.
  """
  def sandbox_ownership_timeout(tags) do
    case tags[:timeout] do
      :infinity ->
        :infinity

      budget when is_integer(budget) and budget > 0 ->
        budget + @ownership_headroom

      _other ->
        @dbconnection_default_ownership_timeout
    end
  end

  @doc """
  Grant a collaborator process access to the test's sandbox connection
  (ADR 0086 contract 1 allowance helper, v1.0.3 M1).

  Under `async: true` the sandbox owner is NOT shared: spawned processes are
  found through the `$callers` chain, but that chain breaks at any
  long-lived process (the Objectives Engine agent, named runtimes,
  registries) — their delegate Tasks carry the singleton, not the test, in
  `$callers` and raise `DBConnection.OwnershipError`
  (the recorded v1.0.3 M1 red trace). Tests allow those collaborators
  explicitly:

      allow_sandbox(AllbertAssist.Objectives.Engine.Agent)

  Accepts a pid or a registered name; returns the resolved pid. The
  allowance is dropped automatically when the test's owner stops.
  """
  def allow_sandbox(server, owner \\ self()) do
    pid = resolve_collaborator!(server)
    Sandbox.allow(Repo, owner, pid)
    pid
  end

  defp resolve_collaborator!(pid) when is_pid(pid), do: pid

  defp resolve_collaborator!(name) when is_atom(name) do
    Process.whereis(name) ||
      raise ArgumentError,
            "cannot allow sandbox access for #{inspect(name)}: no such registered process"
  end

  @doc """
  A helper that transforms changeset errors into a map of messages.

      assert {:error, changeset} = Accounts.create_user(%{password: "short"})
      assert "password is too short" in errors_on(changeset).password
      assert %{password: ["password is too short"]} = errors_on(changeset)

  """
  def errors_on(changeset) do
    Ecto.Changeset.traverse_errors(changeset, fn {message, opts} ->
      Regex.replace(~r"%{(\w+)}", message, fn _, key ->
        opts |> Keyword.get(String.to_existing_atom(key), key) |> to_string()
      end)
    end)
  end
end
