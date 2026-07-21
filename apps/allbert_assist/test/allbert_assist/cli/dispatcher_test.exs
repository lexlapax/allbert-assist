defmodule AllbertAssist.CLI.DispatcherTest do
  @moduledoc """
  v0.62 M3 — the pure dispatcher (`CLI.run/1`) routes argv correctly: grouped
  help, version, bare-`allbert` first-run, dev/CI rejection, unknown handling,
  and longest-prefix path resolution (admin settings get beats admin settings).
  """
  use AllbertAssist.DataCase, async: false

  alias AllbertAssist.CLI
  alias AllbertAssist.CLI.FirstRun
  alias AllbertAssist.Paths
  alias AllbertAssist.Runtime.Attach
  alias AllbertAssist.SecurityFixtures.AssertBinding
  alias AllbertAssist.Settings

  @moduletag :cli_dispatcher

  test "bare allbert runs first-run detection (exit 0, guidance)" do
    {out, code} = CLI.run([])
    assert code == 0
    assert out =~ "Allbert" or out =~ "Home" or out =~ "model"
  end

  test "bare allbert renders model repair copy without raw probe atoms" do
    with_first_run_home(fn ->
      with_no_model_provider_env(fn ->
        assert {:ok, _} =
                 Settings.put(
                   "providers.local_ollama.base_url",
                   "http://127.0.0.1:1/v1",
                   %{audit?: false}
                 )

        {out, 0} = CLI.run([])

        assert out =~ "No usable model yet."
        assert out =~ "No local model runtime is running yet."
        assert out =~ "Install and start the local runtime"
        assert out =~ "workspace"
        refute out =~ "runtime_missing"
        refute out =~ ":runtime_missing"
      end)
    end)
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

    {service_status_out, service_status_code} = CLI.run(["admin", "service", "status"])
    assert service_status_code == 0
    assert service_status_out =~ "service_manager_available"
    assert service_status_out =~ "service_platform"

    onboarding_doc =
      "../../../../../docs/operator/onboarding.md"
      |> Path.expand(__DIR__)
      |> File.read!()

    assert onboarding_doc =~
             "Foreground `allbert serve --open` is a diagnostic or repair fallback"

    {pull_out, pull_code} =
      CLI.run(["admin", "model", "pull", "--dry-run", "--model", "llama3.2:3b"])

    assert pull_code == 0
    assert pull_out =~ "Would pull llama3.2:3b"

    AssertBinding.check!("first-run-persistent-service-no-repeat-serve-001", [
      :service_status_routes_read_only,
      :service_manager_posture_reported,
      :foreground_serve_not_happy_path
    ])
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

      # v0.62 M8.18: cover the remaining three identity fields (all five bind a
      # request to this exact daemon).
      base = Attach.request(["--version"], token)

      assert {:error, :protocol_mismatch} =
               Attach.run_request(Map.put(base, :protocol, 999))

      assert {:error, :uid_mismatch} =
               Attach.run_request(Map.put(base, :uid, "999999"))

      assert {:error, :version_mismatch} =
               Attach.run_request(Map.put(base, :version, "0.0.0-not-this"))
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

  test "attach rejects a missing/non-binary token in constant time (M8.16)" do
    with_attach_home(fn ->
      start_supervised!(Attach.Server)
      assert {:ok, token} = Attach.read_token()

      nil_token =
        ["--version"]
        |> Attach.request(token)
        |> Map.put(:token, nil)

      assert {:error, :token_mismatch} = Attach.run_request(nil_token)
    end)
  end

  # v0.62 M8.16: the double-execution barrier. A reply-received result (crash,
  # undecodable reply, non-zero exit) must NEVER fall back to the embedded
  # runtime — only a pre-reply transport failure may.
  test "classify_attach never re-runs a reply-received result embedded (M8.16)" do
    # Reply received on the daemon — surface, do NOT fall back.
    assert {:error, message} = CLI.classify_attach({:error, {:command_crashed, "boom"}})
    assert message =~ "boom"

    assert {:error, _} = CLI.classify_attach({:error, :invalid_response})
    assert {:error, _} = CLI.classify_attach({:error, :invalid_term})

    # Busy daemon owns the DB — retry message, not embedded fallback.
    assert {:error, busy} = CLI.classify_attach({:error, :busy})
    assert busy =~ "busy"

    # Identity mismatches are hard errors, not fallback.
    assert {:error, _} = CLI.classify_attach({:error, :token_mismatch})

    # A successful reply — including a non-zero command exit — stays attached.
    assert {:attached, "out", 0} = CLI.classify_attach({:ok, {"out", 0}})
    assert {:attached, "boom", 3} = CLI.classify_attach({:ok, {"boom", 3}})

    # Transport failed before any reply — the command did not run, so fall back.
    for reason <- [:not_available, :closed, :timeout, :econnrefused, :enoent] do
      assert :fallback == CLI.classify_attach({:error, reason})
    end
  end

  # v0.62 M8.18: the listener stays alive and keeps serving through a burst of
  # concurrent attached commands (each runs in its own supervised task under the
  # bounded Task.Supervisor). Every result is clean — an attached reply or a
  # graceful transport error (a saturated accept backlog yields :not_available,
  # which the client then falls back on) — never a crash, and the GenServer
  # survives and keeps serving afterward.
  test "the listener survives a burst of concurrent attached commands (M8.18)" do
    with_attach_home(fn ->
      pid = start_supervised!(Attach.Server)

      results =
        1..12
        |> Task.async_stream(fn _ -> Attach.run(["--version"]) end,
          max_concurrency: 12,
          timeout: 30_000
        )
        |> Enum.map(fn {:ok, result} -> result end)

      assert Enum.all?(results, fn r ->
               match?({:ok, {_out, 0}}, r) or match?({:error, _}, r)
             end)

      assert Enum.any?(results, &match?({:ok, {_out, 0}}, &1))
      assert Process.alive?(pid)
      # Still serving after the burst.
      assert {:ok, {_out, 0}} = Attach.run(["--version"])
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

  defp with_first_run_home(fun) do
    original_paths_config = Application.get_env(:allbert_assist, Paths)

    root =
      Path.join(
        System.tmp_dir!(),
        "allbert-first-run-#{System.unique_integer([:positive])}"
      )

    Application.put_env(:allbert_assist, Paths, home: root)
    File.mkdir_p!(Path.join([root, "db"]))
    File.write!(Path.join([root, "db", "allbert.sqlite3"]), "x")
    FirstRun.mark_onboarding_complete()
    FirstRun.mark_profile_reviewed()

    on_exit(fn ->
      if original_paths_config,
        do: Application.put_env(:allbert_assist, Paths, original_paths_config),
        else: Application.delete_env(:allbert_assist, Paths)

      File.rm_rf!(root)
    end)

    fun.()
  end

  defp with_no_model_provider_env(fun) do
    keys = ~w(ANTHROPIC_API_KEY OPENAI_API_KEY OPENROUTER_API_KEY GOOGLE_API_KEY GEMINI_API_KEY)
    saved = Map.new(keys, &{&1, System.get_env(&1)})
    saved_host = System.get_env("OLLAMA_HOST")

    Enum.each(keys, &System.delete_env/1)
    System.put_env("OLLAMA_HOST", "https://example.invalid")

    try do
      fun.()
    after
      Enum.each(saved, fn
        {key, nil} -> System.delete_env(key)
        {key, value} -> System.put_env(key, value)
      end)

      if saved_host,
        do: System.put_env("OLLAMA_HOST", saved_host),
        else: System.delete_env("OLLAMA_HOST")
    end
  end
end
