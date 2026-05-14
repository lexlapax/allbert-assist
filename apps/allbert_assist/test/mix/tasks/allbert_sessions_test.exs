defmodule Mix.Tasks.Allbert.SessionsTest do
  use ExUnit.Case, async: false

  import ExUnit.CaptureIO

  alias AllbertAssist.Session
  alias Mix.Tasks.Allbert.Sessions, as: SessionsTask

  setup do
    user = "cli-session-#{System.unique_integer([:positive])}"

    on_exit(fn ->
      Session.clear(user, "sess-1")
      Session.clear(user, "shared")
      Mix.Task.reenable("allbert.sessions")
    end)

    {:ok, user: user}
  end

  test "sets, shows, lists, clears active app, and clears a session", %{user: user} do
    set_output =
      capture_io(fn ->
        assert :ok =
                 SessionsTask.run([
                   "set-active-app",
                   "--user",
                   user,
                   "--session",
                   "sess-1",
                   "stocksage"
                 ])
      end)

    assert set_output =~ "User: #{user}"
    assert set_output =~ "Session: sess-1"
    assert set_output =~ "Active app: stocksage"

    show_output =
      capture_io(fn ->
        assert :ok = SessionsTask.run(["show", "--user", user, "--session", "sess-1"])
      end)

    assert show_output =~ "Working memory key count: 0"
    refute show_output =~ "working_memory:"

    list_output =
      capture_io(fn ->
        assert :ok = SessionsTask.run(["list", "--user", user])
      end)

    assert list_output =~ "sess-1 active_app=stocksage"

    clear_active_output =
      capture_io(fn ->
        assert :ok =
                 SessionsTask.run(["clear-active-app", "--user", user, "--session", "sess-1"])
      end)

    assert clear_active_output =~ "Active app: none"

    clear_output =
      capture_io(fn ->
        assert :ok = SessionsTask.run(["clear", "--user", user, "--session", "sess-1"])
      end)

    assert clear_output =~ "removed=true"
  end

  test "preserves operator aliasing and alice/bob isolation", %{user: user} do
    output =
      capture_io(fn ->
        assert :ok =
                 SessionsTask.run([
                   "set-active-app",
                   "--operator",
                   user,
                   "--session",
                   "shared",
                   "stocksage"
                 ])
      end)

    assert output =~ "Active app: stocksage"

    assert_raise Mix.Error, ~r/not_found/, fn ->
      capture_io(fn ->
        SessionsTask.run(["show", "--user", "#{user}-bob", "--session", "shared"])
      end)
    end

    assert_raise Mix.Error, ~r/--user and --operator must match/, fn ->
      SessionsTask.run([
        "set-active-app",
        "--user",
        user,
        "--operator",
        "other",
        "--session",
        "shared",
        "stocksage"
      ])
    end
  end

  test "list shows an empty-state message when no sessions exist", %{user: user} do
    output =
      capture_io(fn ->
        assert :ok = SessionsTask.run(["list", "--user", user])
      end)

    assert output =~ "No sessions."
  end

  test "rejects invalid app ids and invalid session flags before mutation", %{user: user} do
    assert_raise Mix.Error, ~r/unknown_app/, fn ->
      capture_io(fn ->
        SessionsTask.run([
          "set-active-app",
          "--user",
          user,
          "--session",
          "sess-1",
          "unknown"
        ])
      end)
    end

    assert {:error, :not_found} = Session.get(user, "sess-1")

    assert_raise Mix.Error, ~r/invalid_session_id/, fn ->
      SessionsTask.run(["set-active-app", "--user", user, "--session", "", "stocksage"])
    end

    too_long = String.duplicate("s", Session.max_session_id_length() + 1)

    assert_raise Mix.Error, ~r/session_id_too_long/, fn ->
      SessionsTask.run(["set-active-app", "--user", user, "--session", too_long, "stocksage"])
    end
  end

  test "sweeps without dumping entry values" do
    output =
      capture_io(fn ->
        assert :ok = SessionsTask.run(["sweep"])
      end)

    assert output =~ "Expired sessions removed="
  end
end
