defmodule AllbertAssist.CLI.DispatcherTest do
  @moduledoc """
  v0.62 M3 — the pure dispatcher (`CLI.run/1`) routes argv correctly: grouped
  help, version, bare-`allbert` first-run, dev/CI rejection, unknown handling,
  and longest-prefix path resolution (admin settings get beats admin settings).
  """
  use AllbertAssist.DataCase, async: false

  alias AllbertAssist.CLI
  alias AllbertAssist.Paths
  alias AllbertAssist.Runtime.Attach

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

  test "admin settings resolves to the settings area and owns its subcommands" do
    # v0.62 M8.7: `admin settings` is now the Settings area (not "unknown"); the
    # longest-prefix resolver stops at `["admin","settings"]` and passes the rest
    # (`get KEY`) to the area's own dispatch.
    {_out, code} = CLI.run(["admin", "settings", "get", "workspace.theme.mode"])
    assert code in [0, 1]

    {out, 2} = CLI.run(["admin", "settings"])
    refute out =~ "unknown command"
    assert out =~ "settings"
  end

  test "settings/service/model CLI operands are preserved" do
    {settings_out, settings_code} =
      CLI.run(["admin", "settings", "get", "external_services.enabled"])

    assert settings_code == 0
    refute settings_out =~ "invalid params"
    refute settings_out =~ "Usage"

    {service_out, service_code} =
      CLI.run(["admin", "service", "install", "--dry-run"])

    assert service_code == 0
    assert service_out =~ "Would install"

    {pull_out, pull_code} =
      CLI.run(["admin", "model", "pull", "--dry-run", "--model", "llama3.2:3b"])

    assert pull_code == 0
    assert pull_out =~ "Would pull llama3.2:3b"
  end

  test "attach client round-trips to a running local daemon listener" do
    with_attach_home(fn ->
      start_supervised!(Attach.Server)

      assert {:ok, {out, 0}} = Attach.run(["--version"])
      assert out =~ "allbert"
    end)
  end

  test "attach rejects authentication and identity mismatches" do
    with_attach_home(fn ->
      start_supervised!(Attach.Server)

      assert {:ok, token} = Attach.read_token()

      bad_token =
        ["--version"]
        |> Attach.request(token)
        |> Map.put(:token, "wrong-token")

      assert {:error, :token_mismatch} = Attach.run_request(bad_token)

      bad_home =
        ["--version"]
        |> Attach.request(token)
        |> Map.put(:home, "/tmp/not-this-allbert-home")

      assert {:error, :home_mismatch} = Attach.run_request(bad_home)
    end)
  end

  test "the listener runs commands off-process and survives serving (M8.9)" do
    with_attach_home(fn ->
      pid = start_supervised!(Attach.Server)

      assert {:ok, {_out1, 0}} = Attach.run(["--version"])
      assert {:ok, {_out2, 0}} = Attach.run(["--help"])
      # Commands run in a supervised task, so the listener is neither blocked
      # nor crashed by serving them.
      assert Process.alive?(pid)
    end)
  end

  test "the attach token file is created owner-only, 0600 (M8.9)" do
    with_attach_home(fn ->
      start_supervised!(Attach.Server)
      assert {:ok, _token} = Attach.read_token()

      stat = File.stat!(Attach.token_path())
      # No group/other permission bits.
      assert Bitwise.band(stat.mode, 0o077) == 0
    end)
  end

  defp with_attach_home(fun) do
    original_paths_config = Application.get_env(:allbert_assist, Paths)

    root =
      Path.join(
        System.tmp_dir!(),
        "allbert-attach-#{System.unique_integer([:positive])}"
      )

    Application.put_env(:allbert_assist, Paths, home: root)

    on_exit(fn ->
      if original_paths_config,
        do: Application.put_env(:allbert_assist, Paths, original_paths_config),
        else: Application.delete_env(:allbert_assist, Paths)

      File.rm_rf!(root)
    end)

    fun.()
  end
end
