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

  @doc """
  Sets up the sandbox based on the test tags.
  """
  def setup_sandbox(tags) do
    pid = Sandbox.start_owner!(Repo, shared: not tags[:async])
    on_exit(fn -> Sandbox.stop_owner(pid) end)
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
