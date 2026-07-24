defmodule AllbertAssist.OperatorValidationHarnessTest do
  use ExUnit.Case, async: false

  @moduletag :external_runtime_serial

  @repo_root Path.expand("../../../../", __DIR__)
  @harness Path.join(@repo_root, "scripts/validation/v11_operator.sh")
  @core_setup Path.join(@repo_root, "scripts/validation/v11_core_setup.exs")
  @channel_configure Path.join(@repo_root, "scripts/validation/v11_channel_configure.exs")
  @settings_transition Path.join(@repo_root, "scripts/validation/v11_settings_transition.exs")

  setup do
    root =
      Path.join(
        System.tmp_dir!(),
        "allbert v11 harness test-#{System.unique_integer([:positive])}"
      )

    File.rm_rf!(root)
    File.mkdir_p!(root)
    root = physical_dir(root)
    env_path = Path.join(root, "credentials.env")

    File.write!(
      env_path,
      """
      V11_DUMMY_CREDENTIAL=must-not-enter-state
      ALLBERT_HOME=/tmp/forbidden-home
      ALLBERT_HOME_DIR=/tmp/forbidden-home-dir
      ALLBERT_SETTINGS_ROOT=/tmp/forbidden-settings
      ALLBERT_MEMORY_ROOT=/tmp/forbidden-memory
      ALLBERT_ARTIFACTS_ROOT=/tmp/forbidden-artifacts
      ALLBERT_PLUGINS_ROOT=/tmp/forbidden-plugins
      ALLBERT_VAULT_BACKEND=os
      DATABASE_PATH=/tmp/forbidden.sqlite3
      V11_VALIDATION_ROOT=/tmp/forbidden-validation-root
      V11_EVIDENCE_ROOT=/tmp/forbidden-evidence-root
      HOME=/tmp/forbidden-caller-home
      TMPDIR=/tmp/forbidden-caller-tmp
      BASH_ENV=/tmp/forbidden-bash-env
      XDG_CONFIG_HOME=/tmp/forbidden-xdg
      """
    )

    state_path = Path.join(root, "v1.1-current.state")

    env = [
      {"HOME", root},
      {"TMPDIR", root},
      {"MIX_HOME", Path.join(System.user_home!(), ".mix")},
      {"HEX_HOME", Path.join(System.user_home!(), ".hex")},
      {"MIX_ENV", "test"},
      {"V11_HARNESS_TEST_MODE", "1"},
      {"V11_ENV_SOURCE_OVERRIDE", env_path},
      {"V11_STATE_FILE", state_path}
    ]

    on_exit(fn -> File.rm_rf!(root) end)

    {:ok, root: root, env: env, env_path: env_path, state_path: state_path}
  end

  test "is executable Bash with a complete short-command interface" do
    assert File.exists?(@harness)
    assert File.exists?(@core_setup)
    assert File.exists?(@channel_configure)
    assert File.exists?(@settings_transition)
    assert {_, 0} = System.cmd("bash", ["-n", @harness], stderr_to_stdout: true)

    assert {help, 0} = run_harness(["help"], [])

    for command <- [
          "prepare",
          "status",
          "core-setup",
          "tui",
          "daemon-start",
          "daemon-stop",
          "channel-configure",
          "channel-doctor",
          "notify-off",
          "notify-on",
          "confirmation-on",
          "confirmation-off",
          "audit-copy",
          "external-smoke",
          "ov12-source",
          "ov12-host",
          "cleanup"
        ] do
      assert help =~ command
    end

    body = File.read!(@harness)
    assert body =~ ~s(set -euo pipefail)
    assert body =~ ~s(main "$@")
    refute body =~ "eval "
    refute body =~ ~r/source\s+.*STATE/
  end

  test "prepare creates only a copied env in a confined fresh Home and redacted mode-600 state",
       %{env: env, root: root, state_path: state_path} do
    assert {output, 0} = run_harness(["prepare"], env)
    assert output =~ "OV-00 PASS"

    state = File.read!(state_path)
    assert file_mode(state_path) == 0o600
    refute state =~ "must-not-enter-state"
    refute state =~ "/tmp/forbidden"
    refute state =~ ~r/(token|password|secret|api[_-]?key)/i

    values = state_values(state)
    assert values["V11_STATUS"] == "ready"
    assert values["ALLBERT_HOME"] == Path.join(values["V11_VALIDATION_ROOT"], "home")
    assert values["V11_ENV_COPY"] == Path.join(values["ALLBERT_HOME"], ".env")
    assert String.starts_with?(values["V11_VALIDATION_ROOT"], root)
    assert File.ls!(values["ALLBERT_HOME"]) == [".env"]
    assert file_mode(values["V11_ENV_COPY"]) == 0o600

    assert {status, 0} = run_harness(["status"], env)
    assert status =~ "status=ready"
    assert status =~ "daemon=stopped"
    refute status =~ "must-not-enter-state"
  end

  test "a post-create failure retains a diagnosable Home and never falls through to ready",
       %{env: env, state_path: state_path} do
    env = [{"V11_FAIL_AFTER_CREATE_FOR_TESTS", "1"} | env]
    assert {output, rc} = run_harness(["prepare"], env)
    assert rc != 0
    assert output =~ "injected post-create failure"

    values = state_path |> File.read!() |> state_values()
    assert values["V11_STATUS"] == "preparing"
    assert File.dir?(values["ALLBERT_HOME"])
    refute File.exists?(Path.join(values["ALLBERT_HOME"], "db/allbert.sqlite3"))
  end

  test "core setup migrates the same fresh Home and persists verified fan-out and TUI identity",
       %{env: env, state_path: state_path} do
    assert {_, 0} = run_harness(["prepare"], env)
    assert {output, 0} = run_harness(["core-setup"], env)
    assert output =~ "OV-01 core setup PASS"

    values = state_path |> File.read!() |> state_values()
    assert values["V11_STATUS"] == "core_ready"
    assert File.exists?(Path.join(values["ALLBERT_HOME"], "db/allbert.sqlite3"))

    tui_evidence = Path.join(values["V11_EVIDENCE_ROOT"], "OV-01-tui.txt")
    assert File.read!(tui_evidence) =~ "Enabled: true"
    assert File.read!(tui_evidence) =~ "Identities: 1"
  end

  test "all external channel configurations use one bounded process and redact credentials",
       %{env: env, env_path: env_path, state_path: state_path} do
    secrets = [
      "telegram-secret-123",
      "imap-secret-123",
      "smtp-secret-123",
      "discord-secret-123",
      "slack-bot-secret-123",
      "slack-app-secret-123",
      "matrix-secret-123",
      "whatsapp-access-secret-123",
      "whatsapp-app-secret-123",
      "whatsapp-verify-secret-123"
    ]

    File.write!(
      env_path,
      """
      ALLBERT_TELEGRAM_BOT_TOKEN=#{Enum.at(secrets, 0)}
      ALLBERT_TELEGRAM_CHAT_ID=telegram-chat-1
      ALLBERT_TELEGRAM_USER_ID=telegram-user-1
      ALLBERT_EMAIL_IMAP_HOST=imap.example.test
      ALLBERT_EMAIL_IMAP_PORT=993
      ALLBERT_EMAIL_IMAP_USERNAME=imap-user
      ALLBERT_EMAIL_IMAP_PASSWORD=#{Enum.at(secrets, 1)}
      ALLBERT_EMAIL_SMTP_HOST=smtp.example.test
      ALLBERT_EMAIL_SMTP_PORT=465
      ALLBERT_EMAIL_SMTP_USERNAME=smtp-user
      ALLBERT_EMAIL_SMTP_PASSWORD=#{Enum.at(secrets, 2)}
      ALLBERT_EMAIL_FROM_ADDRESS=bot@example.test
      ALLBERT_EMAIL_MAPPED_SENDER=operator@example.test
      ALLBERT_DISCORD_BOT_TOKEN=#{Enum.at(secrets, 3)}
      ALLBERT_DISCORD_APPLICATION_ID=discord-app-1
      ALLBERT_DISCORD_GUILD_ID=discord-guild-1
      ALLBERT_DISCORD_CHANNEL_ID=discord-channel-1
      ALLBERT_DISCORD_USER_ID=discord-user-1
      ALLBERT_SLACK_BOT_TOKEN=#{Enum.at(secrets, 4)}
      ALLBERT_SLACK_APP_TOKEN=#{Enum.at(secrets, 5)}
      ALLBERT_SLACK_TEAM_ID=slack-team-1
      ALLBERT_SLACK_CHANNEL_ID=slack-channel-1
      ALLBERT_SLACK_USER_ID=slack-user-1
      ALLBERT_MATRIX_HOMESERVER_URL=https://matrix.example.test
      ALLBERT_MATRIX_ACCESS_TOKEN=#{Enum.at(secrets, 6)}
      ALLBERT_MATRIX_BOT_USER=@bot:example.test
      ALLBERT_MATRIX_ROOM_ID=!room:example.test
      ALLBERT_MATRIX_USER_ID=@operator:example.test
      ALLBERT_WHATSAPP_ACCESS_TOKEN=#{Enum.at(secrets, 7)}
      ALLBERT_WHATSAPP_PHONE_NUMBER_ID=whatsapp-phone-1
      ALLBERT_WHATSAPP_WABA_ID=whatsapp-waba-1
      ALLBERT_WHATSAPP_MAPPED_PHONE=15555550100
      ALLBERT_WHATSAPP_APP_SECRET=#{Enum.at(secrets, 8)}
      ALLBERT_WHATSAPP_WEBHOOK_VERIFY_TOKEN=#{Enum.at(secrets, 9)}
      ALLBERT_SIGNAL_ACCOUNT=+15555550101
      ALLBERT_SIGNAL_LOCAL_ACI=11111111-1111-1111-1111-111111111111
      ALLBERT_SIGNAL_MAPPED_ACI=22222222-2222-4222-8222-222222222222
      """
    )

    assert {_, 0} = run_harness(["prepare"], env)
    assert {_, 0} = run_harness(["core-setup"], env)
    values = state_path |> File.read!() |> state_values()

    output =
      case run_harness(["channel-configure", "all-test"], env) do
        {output, 0} -> output
        {output, rc} -> flunk("all-channel configuration exited #{rc}:\n#{output}")
      end

    assert output =~ "all test channel configurations PASS"

    evidence =
      File.read!(Path.join(values["V11_EVIDENCE_ROOT"], "OV-01-all-channel-configure.txt"))

    for channel <- ~w(signal telegram email discord slack matrix whatsapp) do
      assert evidence =~ "V11 CHANNEL CONFIGURATION PASS channel=#{channel}"
    end

    assert length(Regex.scan(~r/Enabled: true/, evidence)) == 7
    assert length(Regex.scan(~r/Identities: 1/, evidence)) == 7

    for secret <- secrets do
      refute evidence =~ secret
    end
  end

  test "notification and confirmation settings transitions persist and verify in one bounded process",
       %{env: env} do
    assert {_, 0} = run_harness(["prepare"], env)
    assert {_, 0} = run_harness(["core-setup"], env)
    assert {output, 0} = run_harness(["settings-test-all"], env)
    assert output =~ "channels.telegram.autonomous_notify.enabled=false"
    assert output =~ "channels.telegram.autonomous_notify.enabled=true"
    assert output =~ ~s(permissions.command_execute="needs_confirmation")
    assert output =~ ~s(permissions.command_execute="denied")
    assert output =~ "V11 SETTINGS TRANSITION PASS transition=all-test"
  end

  test "missing input stops before state or Home creation", %{
    env: env,
    root: root,
    state_path: state_path
  } do
    missing = Path.join(root, "missing.env")
    env = put_env(env, "V11_ENV_SOURCE_OVERRIDE", missing)

    assert {output, rc} = run_harness(["prepare"], env)
    assert rc != 0
    assert output =~ "credential input is missing"
    refute File.exists?(state_path)
    assert Path.wildcard(Path.join(root, "allbert-v11-validation.*")) == []
  end

  test ".env parsing treats shell syntax as data and never executes it", %{
    env: env,
    env_path: env_path,
    root: root
  } do
    marker = Path.join(root, "must-not-exist")
    File.write!(env_path, "V11_LITERAL=$(touch #{marker})\n")

    assert {output, 0} = run_harness(["prepare"], env)
    assert output =~ "OV-00 PASS"
    refute File.exists?(marker)
  end

  test "Bash and Zsh callers survive a harness STOP", %{env: env} do
    for shell <- ["bash", "zsh"] do
      command = "#{@harness} status >/dev/null 2>&1; rc=$?; echo caller-survived:$rc"

      assert {output, 0} =
               System.cmd(shell, ["-lc", command],
                 cd: @repo_root,
                 env: env,
                 stderr_to_stdout: true
               )

      assert output =~ "caller-survived:1"
    end
  end

  test "platform script invocation captures an interactive child without changing the caller",
       %{env: env, state_path: state_path} do
    assert {_, 0} = run_harness(["prepare"], env)
    assert {output, 0} = run_harness(["capture-test"], env)
    assert output =~ "V11_CAPTURE_TEST_PASS"

    values = state_path |> File.read!() |> state_values()

    assert File.read!(Path.join(values["V11_EVIDENCE_ROOT"], "OV-capture-test.txt")) =~
             "V11_CAPTURE_TEST_PASS"
  end

  test "daemon stop refuses a live PID that is not an owned Phoenix process", %{
    env: env,
    state_path: state_path
  } do
    assert {_, 0} = run_harness(["prepare"], env)

    original_state = File.read!(state_path)

    invalid_pid_state =
      String.replace(original_state, ~r/^V11_DAEMON_PID=.*$/m, "V11_DAEMON_PID=-1")

    File.write!(state_path, invalid_pid_state)
    File.chmod!(state_path, 0o600)

    assert {invalid_output, invalid_rc} = run_harness(["daemon-stop"], env)
    assert invalid_rc != 0
    assert invalid_output =~ "state has an invalid daemon PID"

    values = state_values(original_state)

    state =
      original_state
      |> String.replace(~r/^V11_DAEMON_PID=.*$/m, "V11_DAEMON_PID=#{System.pid()}")
      |> String.replace(~r/^V11_DAEMON_LABEL=.*$/m, "V11_DAEMON_LABEL=foreign")
      |> String.replace(
        ~r/^V11_DAEMON_LOG=.*$/m,
        "V11_DAEMON_LOG=#{values["V11_EVIDENCE_ROOT"]}/OV-daemon-foreign.txt"
      )

    File.write!(state_path, state)
    File.chmod!(state_path, 0o600)

    assert {output, rc} = run_harness(["daemon-stop"], env)
    assert rc != 0
    assert output =~ "ownership check failed"
    assert Process.alive?(self())
  end

  test "tampered traversal state fails closed without deleting the target", %{
    env: env,
    root: root,
    state_path: state_path
  } do
    assert {_, 0} = run_harness(["prepare"], env)

    values = state_path |> File.read!() |> state_values()
    target = Path.join(root, "must-not-delete")
    target_home = Path.join(target, "home")
    File.mkdir_p!(target_home)
    sentinel = Path.join(target, "sentinel")
    File.write!(sentinel, "preserve")
    traversing_root = Path.join(values["V11_VALIDATION_ROOT"], "../must-not-delete")

    state =
      state_path
      |> File.read!()
      |> String.replace(
        ~r/^V11_VALIDATION_ROOT=.*$/m,
        "V11_VALIDATION_ROOT=#{traversing_root}"
      )
      |> String.replace(~r/^ALLBERT_HOME=.*$/m, "ALLBERT_HOME=#{traversing_root}/home")
      |> String.replace(
        ~r/^V11_ENV_COPY=.*$/m,
        "V11_ENV_COPY=#{traversing_root}/home/.env"
      )

    File.write!(state_path, state)
    File.chmod!(state_path, 0o600)

    assert {output, rc} = run_harness(["status"], env)
    assert rc != 0
    assert output =~ "state validation root is not canonical"

    assert {cleanup_output, cleanup_rc} = run_harness(["cleanup"], env)
    assert cleanup_rc != 0
    assert cleanup_output =~ "state validation root is not canonical"
    assert File.read!(sentinel) == "preserve"
  end

  test "packaged host proof re-pins every durable path before invoking the binary", %{
    env: env,
    root: root
  } do
    fake_bin = Path.join(root, "fake allbert")
    evidence = Path.join(root, "host evidence")

    File.write!(
      fake_bin,
      """
      #!/usr/bin/env bash
      set -eu
      if [ "$1 $2 $3" = "admin cancellation-proof cancel" ]; then
        printf '%s\\n' \
          "ALLBERT_HOME=$ALLBERT_HOME" \
          "ALLBERT_HOME_DIR=$ALLBERT_HOME_DIR" \
          "ALLBERT_SETTINGS_ROOT=$ALLBERT_SETTINGS_ROOT" \
          "ALLBERT_MEMORY_ROOT=$ALLBERT_MEMORY_ROOT" \
          "ALLBERT_ARTIFACTS_ROOT=$ALLBERT_ARTIFACTS_ROOT" \
          "ALLBERT_VAULT_BACKEND=$ALLBERT_VAULT_BACKEND" \
          "DATABASE_PATH=$DATABASE_PATH" \
          "XDG_CONFIG_HOME=$XDG_CONFIG_HOME" \
          "XDG_DATA_HOME=$XDG_DATA_HOME" \
          "XDG_STATE_HOME=$XDG_STATE_HOME" \
          "XDG_CACHE_HOME=$XDG_CACHE_HOME" \
          "XDG_RUNTIME_DIR=$XDG_RUNTIME_DIR" \
          "ALLBERT_PLUGINS_ROOT=${ALLBERT_PLUGINS_ROOT-}" \
          >"$OV12_EVIDENCE_ROOT/pinned-env.txt"
      fi
      if [ "$1 $2" = "admin cancellation-proof" ]; then
        printf 'Confirmation: conf_%s.\\n' "$3"
        exit 1
      fi
      if [ "$1 $2 $3" = "admin confirmations approve" ]; then
        printf 'OV12 status=PASS mode=%s cleanup_complete?=true\\n' "${4#conf_}"
        exit 0
      fi
      if [ "$1 $2 $3" = "admin settings set" ]; then
        exit 0
      fi
      exit 64
      """
    )

    File.chmod!(fake_bin, 0o700)

    hostile_env =
      env
      |> put_env("ALLBERT_HOME_DIR", "/tmp/forbidden-home-dir")
      |> put_env("ALLBERT_SETTINGS_ROOT", "/tmp/forbidden-settings")
      |> put_env("ALLBERT_MEMORY_ROOT", "/tmp/forbidden-memory")
      |> put_env("ALLBERT_ARTIFACTS_ROOT", "/tmp/forbidden-artifacts")
      |> put_env("ALLBERT_PLUGINS_ROOT", "/tmp/forbidden-plugins")
      |> put_env("ALLBERT_VAULT_BACKEND", "os")
      |> put_env("DATABASE_PATH", "/tmp/forbidden.sqlite3")
      |> put_env("XDG_CONFIG_HOME", "/tmp/forbidden-xdg")

    assert {output, 0} =
             run_harness(["ov12-host", "linux-x64", fake_bin, evidence], hostile_env)

    assert output =~ "OV-12 host PASS host=linux-x64"
    pinned = File.read!(Path.join(evidence, "pinned-env.txt"))
    refute pinned =~ "/tmp/forbidden"
    assert pinned =~ "ALLBERT_VAULT_BACKEND=encrypted_file"
    assert pinned =~ "ALLBERT_PLUGINS_ROOT=\n"

    [home] = Regex.run(~r/^ALLBERT_HOME=(.+)$/m, pinned, capture: :all_but_first)
    assert String.starts_with?(home, Path.join(root, "allbert-ov12-linux-x64."))
    refute File.exists?(home)

    for {key, suffix} <- [
          {"ALLBERT_HOME_DIR", ""},
          {"ALLBERT_SETTINGS_ROOT", "/settings"},
          {"ALLBERT_MEMORY_ROOT", "/memory"},
          {"ALLBERT_ARTIFACTS_ROOT", "/artifacts"},
          {"DATABASE_PATH", "/db/allbert.sqlite3"},
          {"XDG_CONFIG_HOME", "/xdg/config"},
          {"XDG_DATA_HOME", "/xdg/data"},
          {"XDG_STATE_HOME", "/xdg/state"},
          {"XDG_CACHE_HOME", "/xdg/cache"},
          {"XDG_RUNTIME_DIR", "/xdg/runtime"}
        ] do
      assert pinned =~ "#{key}=#{home}#{suffix}"
    end
  end

  test "state parsing never evaluates a tampered value", %{
    env: env,
    root: root,
    state_path: state_path
  } do
    assert {_, 0} = run_harness(["prepare"], env)
    marker = Path.join(root, "state-must-not-exist")

    state =
      state_path
      |> File.read!()
      |> String.replace(~r/^V11_STATUS=.*$/m, "V11_STATUS=$(touch #{marker})")

    File.write!(state_path, state)
    File.chmod!(state_path, 0o600)

    assert {output, rc} = run_harness(["status"], env)
    assert rc != 0
    assert output =~ "state has an invalid status"
    refute File.exists?(marker)
  end

  test "cleanup removes only the fresh Home and state while retaining evidence", %{
    env: env,
    state_path: state_path
  } do
    assert {_, 0} = run_harness(["prepare"], env)
    values = state_path |> File.read!() |> state_values()

    assert {output, 0} = run_harness(["cleanup"], env)
    assert output =~ "cleanup PASS"
    refute File.exists?(values["V11_VALIDATION_ROOT"])
    refute File.exists?(state_path)
    assert File.dir?(values["V11_EVIDENCE_ROOT"])
  end

  defp run_harness(args, env) do
    System.cmd("bash", [@harness | args],
      cd: @repo_root,
      env: env,
      stderr_to_stdout: true
    )
  end

  defp put_env(env, name, value) do
    [{name, value} | Enum.reject(env, fn {key, _value} -> key == name end)]
  end

  defp file_mode(path) do
    path
    |> File.stat!()
    |> Map.fetch!(:mode)
    |> Bitwise.band(0o777)
  end

  defp physical_dir(path) do
    case System.cmd("pwd", ["-P"], cd: path, stderr_to_stdout: true) do
      {output, 0} -> String.trim(output)
      {output, rc} -> raise "physical path lookup failed (#{rc}): #{output}"
    end
  end

  defp state_values(state) do
    state
    |> String.split("\n", trim: true)
    |> Map.new(fn line ->
      [key, value] = String.split(line, "=", parts: 2)
      {key, unquote_bash(value)}
    end)
  end

  defp unquote_bash("''"), do: ""
  defp unquote_bash(value), do: String.trim(value, "'")
end
