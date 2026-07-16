defmodule AllbertAssist.Runtime.AttachSocketPathTest do
  use ExUnit.Case, async: false
  @moduletag :app_env_serial

  alias AllbertAssist.Paths
  alias AllbertAssist.Runtime.Attach

  @moduledoc """
  Operator-validation F3: a deep `ALLBERT_HOME` used to push the Home-local attach socket
  past the Unix-domain `sun_path` limit (104 bytes on macOS/BSD), failing `listen` with
  `:einval` and crashing the whole daemon. `socket_path/0` must stay within the limit by
  falling back to a short, per-Home-stable path when the Home-local one would not fit.
  """

  setup do
    saved = Application.get_env(:allbert_assist, Paths)
    saved_home_env = System.get_env("ALLBERT_HOME")
    System.delete_env("ALLBERT_HOME")

    on_exit(fn ->
      if saved,
        do: Application.put_env(:allbert_assist, Paths, saved),
        else: Application.delete_env(:allbert_assist, Paths)

      if saved_home_env, do: System.put_env("ALLBERT_HOME", saved_home_env)
    end)

    :ok
  end

  test "a short Home keeps the socket under the Home runtime dir" do
    Application.put_env(:allbert_assist, Paths, home: "/tmp/ab-short")
    path = Attach.socket_path()

    assert path == "/tmp/ab-short/runtime/attach.sock"
    assert byte_size(path) < 104
  end

  test "a deep Home falls back to a short socket path within the sun_path limit" do
    deep = "/private/tmp/" <> String.duplicate("nested-segment/", 8) <> "home"
    assert byte_size(Path.join([deep, "runtime", "attach.sock"])) > 104
    Application.put_env(:allbert_assist, Paths, home: deep)

    path = Attach.socket_path()
    assert byte_size(path) < 104, "socket path must fit sun_path; got #{byte_size(path)} bytes"
    assert String.ends_with?(path, ".sock")

    # Deterministic: the daemon (bind) and the CLI (connect) derive the same path.
    assert Attach.socket_path() == path

    # A different Home yields a different socket (no cross-Home collision).
    Application.put_env(:allbert_assist, Paths, home: deep <> "-other")
    refute Attach.socket_path() == path
  end
end
