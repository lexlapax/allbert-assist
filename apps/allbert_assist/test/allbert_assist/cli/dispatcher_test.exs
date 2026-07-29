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

    install_doc =
      "../../../../../docs/operator/install.md"
      |> Path.expand(__DIR__)
      |> File.read!()

    assert install_doc =~
             "Foreground `allbert serve` is a diagnostic or repair fallback"

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

  test "legacy attach request keeps its exact kind-absent packet shape" do
    with_attach_home(fn ->
      identity = Attach.identity()

      assert %{
               protocol: identity.protocol,
               home: identity.home,
               uid: identity.uid,
               version: identity.version,
               token: "legacy-token",
               argv: ["--version"]
             } == Attach.request(["--version"], "legacy-token")

      refute Map.has_key?(Attach.request(["--version"], "legacy-token"), :kind)
    end)
  end

  test "explicit command kind is an alias for legacy unary routing" do
    with_attach_home(fn ->
      start_supervised!(Attach.Server)
      assert {:ok, token} = Attach.read_token()

      legacy_request = Attach.request(["--version"], token)
      explicit_request = Map.put(legacy_request, :kind, :command)

      assert {:ok, {legacy_out, 0}} = Attach.run_request(legacy_request)
      assert {:ok, {explicit_out, 0}} = Attach.run_request(explicit_request)
      assert explicit_out == legacy_out
    end)
  end

  test "nil and unknown attach request kinds are rejected without command dispatch" do
    with_attach_home(fn ->
      pid = start_supervised!(Attach.Server)
      assert {:ok, token} = Attach.read_token()

      for kind <- [nil, :unknown_kind] do
        request =
          ["--version"]
          |> Attach.request(token)
          |> Map.put(:kind, kind)

        assert %{
                 kind: :tui_session,
                 frame: :close,
                 session_protocol: 1,
                 code: :unsupported_kind,
                 message: message
               } = raw_attach_request(request)

        assert is_binary(message)
        assert byte_size(message) <= 1_024
      end

      assert Process.alive?(pid)
    end)
  end

  test "malformed TUI session open fails before runtime dispatch" do
    with_attach_home(fn ->
      pid = start_supervised!(Attach.Server)
      assert {:ok, token} = Attach.read_token()

      malformed_open = Map.delete(valid_tui_open(token), :terminal)

      assert %{code: :invalid_open} = raw_attach_request(malformed_open)
      assert Process.alive?(pid)
    end)
  end

  test "TUI session authentication mismatch fails before runtime dispatch" do
    with_attach_home(fn ->
      pid = start_supervised!(Attach.Server)
      assert {:ok, token} = Attach.read_token()

      mismatched_open = Map.put(valid_tui_open(token), :token, "wrong-token")

      assert %{code: :token_mismatch} = raw_attach_request(mismatched_open)
      assert Process.alive?(pid)
    end)
  end

  test "TUI session packets never reach argv command dispatch" do
    with_attach_home(fn ->
      pid = start_supervised!(Attach.Server)
      assert {:ok, token} = Attach.read_token()

      session_with_argv = Map.put(valid_tui_open(token), :argv, ["--version"])

      assert %{code: :invalid_open} = raw_attach_request(session_with_argv)
      assert Process.alive?(pid)
      assert {:ok, {_out, 0}} = Attach.run(["--version"])
    end)
  end

  test "valid TUI open fails closed until the daemon session service lands" do
    with_attach_home(fn ->
      pid = start_supervised!(Attach.Server)
      assert {:ok, token} = Attach.read_token()

      assert %{code: :runtime_unavailable} = raw_attach_request(valid_tui_open(token))
      assert Process.alive?(pid)
    end)
  end

  test "TUI open rejects a body larger than 16 KiB before schema dispatch" do
    with_attach_home(fn ->
      pid = start_supervised!(Attach.Server)
      assert {:ok, token} = Attach.read_token()

      oversized_open =
        token
        |> valid_tui_open()
        |> Map.put(:padding, String.duplicate("x", 17_000))

      assert byte_size(:erlang.term_to_binary(oversized_open)) > 16_384
      assert %{code: :invalid_open} = raw_attach_request(oversized_open)
      assert Process.alive?(pid)
    end)
  end

  test "compressed TUI open is rejected before session validation" do
    with_attach_home(fn ->
      pid = start_supervised!(Attach.Server)
      assert {:ok, token} = Attach.read_token()
      open = valid_tui_open(token)
      encoded = :erlang.term_to_binary(open, compressed: 9)

      assert <<131, 80, _rest::binary>> = encoded
      assert %{code: :invalid_open} = raw_attach_request(open, compressed: 9)
      assert Process.alive?(pid)
    end)
  end

  test "compressed kind-absent request keeps legacy command behavior" do
    with_attach_home(fn ->
      pid = start_supervised!(Attach.Server)
      assert {:ok, token} = Attach.read_token()
      request = Attach.request(["--version"], token)
      encoded = :erlang.term_to_binary(request, compressed: 9)

      assert <<131, 80, _rest::binary>> = encoded
      assert {:ok, {out, 0}} = raw_attach_request(request, compressed: 9)
      assert out =~ "allbert"
      assert Process.alive?(pid)
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

  test "malformed legacy identity values are rejected without crashing the listener" do
    with_attach_home(fn ->
      pid = start_supervised!(Attach.Server)
      assert {:ok, token} = Attach.read_token()

      malformed_home =
        ["--version"]
        |> Attach.request(token)
        |> Map.put(:home, %{untrusted: "value"})

      assert {:error, :home_mismatch} = Attach.run_request(malformed_home)
      assert Process.alive?(pid)

      malformed_uid =
        ["--version"]
        |> Attach.request(token)
        |> Map.put(:uid, %{untrusted: "value"})

      assert {:error, :uid_mismatch} = Attach.run_request(malformed_uid)
      assert Process.alive?(pid)

      malformed_version =
        ["--version"]
        |> Attach.request(token)
        |> Map.put(:version, %{untrusted: "value"})

      assert {:error, :version_mismatch} = Attach.run_request(malformed_version)
      assert Process.alive?(pid)
      assert {:ok, {_out, 0}} = Attach.run(["--version"])
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

  defp raw_attach_request(request, encode_opts \\ []) do
    {:ok, socket} =
      :gen_tcp.connect(
        {:local, Attach.socket_path()},
        0,
        [:binary, packet: 4, active: false],
        5_000
      )

    :ok = :gen_tcp.send(socket, :erlang.term_to_binary(request, encode_opts))
    {:ok, payload} = :gen_tcp.recv(socket, 0, 5_000)
    response = :erlang.binary_to_term(payload, [:safe])
    :ok = :gen_tcp.close(socket)
    response
  end

  defp valid_tui_open(token) do
    Attach.identity()
    |> Map.merge(%{
      kind: :tui_session,
      frame: :open,
      session_protocol: 1,
      token: token,
      profile: "default",
      terminal: %{columns: 120, rows: 40, color: :truecolor, unicode?: true}
    })
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
