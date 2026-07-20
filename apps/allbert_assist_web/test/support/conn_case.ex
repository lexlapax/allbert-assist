defmodule AllbertAssistWeb.ConnCase do
  @moduledoc """
  This module defines the test case to be used by
  tests that require setting up a connection.

  Such tests rely on `Phoenix.ConnTest` and also
  import other functionality to make it easier
  to build common data structures and query the data layer.

  Finally, if the test case interacts with the database,
  we enable the SQL sandbox, so changes done to the database
  are reverted at the end of every test. Allbert uses SQLite
  in test, so connection tests must stay synchronous; SQLite's
  single-writer model does not pair safely with async sandbox
  tests.
  """

  use ExUnit.CaseTemplate

  using opts do
    lane = Keyword.get(opts, :lane, :liveview_serial)

    quote do
      @moduletag unquote(lane)

      # The default endpoint for testing
      @endpoint AllbertAssistWeb.Endpoint

      use AllbertAssistWeb, :verified_routes

      # Import conveniences for testing with connections
      import Plug.Conn
      import Phoenix.ConnTest
      import AllbertAssistWeb.ConnCase
    end
  end

  setup tags do
    # v1.0.3 M2: the sandbox owner is exposed so the ownership-lease regression
    # can retire the case-provided lease and drive the LiveView boundary
    # explicitly. The lease itself is sized from the test's declared ExUnit
    # budget by `DataCase.setup_sandbox/1` — LiveView mounts and the processes
    # they spawn reach the connection through this owner, so a lease that
    # expires mid-test is exactly what strips their ownership.
    owner = AllbertAssist.DataCase.setup_sandbox(tags)
    {:ok, conn: Phoenix.ConnTest.build_conn(), sandbox_owner: owner}
  end
end
