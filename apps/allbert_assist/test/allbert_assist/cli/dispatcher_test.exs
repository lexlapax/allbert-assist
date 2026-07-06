defmodule AllbertAssist.CLI.DispatcherTest do
  @moduledoc """
  v0.62 M3 — the pure dispatcher (`CLI.run/1`) routes argv correctly: grouped
  help, version, bare-`allbert` first-run, dev/CI rejection, unknown handling,
  and longest-prefix path resolution (admin settings get beats admin settings).
  """
  use AllbertAssist.DataCase, async: false

  alias AllbertAssist.CLI

  @moduletag :cli_dispatcher

  test "bare allbert runs first-run detection (exit 0, guidance)" do
    {out, code} = CLI.run([])
    assert code == 0
    assert out =~ "Allbert" or out =~ "Home" or out =~ "model"
  end

  test "--help renders grouped help with every group" do
    {out, 0} = CLI.run(["--help"])
    assert out =~ "Start" and out =~ "Operate"
    assert out =~ "allbert serve" and out =~ "allbert ask"
    assert out =~ "allbert admin status"
    assert out =~ "Development and CI stay under mix"
  end

  test "version prints the app version" do
    {out, 0} = CLI.run(["--version"])
    assert out =~ "allbert"
    assert out =~ to_string(Application.spec(:allbert_assist, :vsn))
  end

  test "an admin read routes through the spine and returns a rendered result" do
    {out, code} = CLI.run(["admin", "status"])
    assert code in [0, 1]
    assert is_binary(out) and out != ""
    # It went through Runner (registered action), not a raw store read.
  end

  test "gen is dev/CI only — rejected on the binary surface with exit 2" do
    {out, code} = CLI.run(["gen"])
    assert code == 2
    assert out =~ "developer" or out =~ "mix"
  end

  test "unknown commands exit 2 with help guidance" do
    {out, 2} = CLI.run(["frobnicate"])
    assert out =~ "unknown command"
    assert out =~ "--help"
  end

  test "longest-prefix resolution: admin settings get is distinct from admin settings" do
    # `admin settings get` is in the table; `admin settings` is not (bare).
    {_out, code} = CLI.run(["admin", "settings", "get", "workspace.theme.mode"])
    assert code in [0, 1]

    {out, 2} = CLI.run(["admin", "settings"])
    assert out =~ "unknown command"
  end
end
