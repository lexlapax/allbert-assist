#!/usr/bin/env bash
# Allbert v1.1 operator-validation harness.
#
# This file is executed, never sourced. Strict shell options and exit paths are
# therefore confined to this process and cannot close or mutate the operator's
# interactive Zsh/Bash session. Persistent validation state contains paths and
# status only; provider credentials remain in the mode-600 copied .env and are
# loaded privately for each subcommand.

set -euo pipefail
IFS=$'\n\t'
umask 077

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd -P)"
if [ "${V11_HARNESS_TEST_MODE:-0}" = 1 ] && [ "${MIX_ENV:-}" = test ]; then
  STATE_FILE="${V11_STATE_FILE:-$HOME/allbert-validation/v1.1-current.state}"
else
  STATE_FILE="$HOME/allbert-validation/v1.1-current.state"
fi
STATE_VERSION=1
ROOT_MARKER=.allbert-v11-validation-root

die() {
  printf 'V11 STOP: %s\n' "$*" >&2
  exit 1
}

note() {
  printf 'V11: %s\n' "$*"
}

require_command() {
  command -v "$1" >/dev/null 2>&1 || die "required command is unavailable: $1"
}

require_external_channel() {
  case "$1" in
    telegram|email|discord|slack|matrix|whatsapp|signal) ;;
    *) die "unsupported external channel: $1" ;;
  esac
}

require_ov_id() {
  [[ "$1" =~ ^OV-[0-9][0-9]$ ]] || die "invalid OV identifier: $1"
}

stat_mode() {
  stat -f '%Lp' "$1" 2>/dev/null || stat -c '%a' "$1"
}

physical_dir() {
  [ -d "$1" ] || return 1
  (cd -P -- "$1" && pwd -P)
}

shell_quote() {
  printf '%q' "$1"
}

write_state() {
  local state_dir tmp value
  state_dir="$(dirname "$STATE_FILE")"
  mkdir -p "$state_dir"
  chmod 700 "$state_dir"
  tmp="$STATE_FILE.tmp.$$"

  for value in "${V11_STATUS:-preparing}" "${V11_TEST_MODE:-0}" "${V11_SHA:-}" \
    "${V11_REPO_ROOT:-$REPO_ROOT}" "${V11_EVIDENCE_ROOT:-}" \
    "${V11_VALIDATION_ROOT:-}" "${V11_TEMP_PARENT:-}" "${ALLBERT_HOME:-}" \
    "${V11_ENV_COPY:-}" "${V11_DAEMON_PID:-}" "${V11_DAEMON_LABEL:-}" \
    "${V11_DAEMON_LOG:-}"; do
    case "$value" in
      *$'\n'*|*$'\r'*) die "state values may not contain line breaks" ;;
    esac
  done

  {
    printf 'V11_STATE_VERSION=%s\n' "$STATE_VERSION"
    printf 'V11_STATUS=%s\n' "${V11_STATUS:-preparing}"
    printf 'V11_TEST_MODE=%s\n' "${V11_TEST_MODE:-0}"
    printf 'V11_SHA=%s\n' "${V11_SHA:-}"
    printf 'V11_REPO_ROOT=%s\n' "${V11_REPO_ROOT:-$REPO_ROOT}"
    printf 'V11_EVIDENCE_ROOT=%s\n' "${V11_EVIDENCE_ROOT:-}"
    printf 'V11_VALIDATION_ROOT=%s\n' "${V11_VALIDATION_ROOT:-}"
    printf 'V11_TEMP_PARENT=%s\n' "${V11_TEMP_PARENT:-}"
    printf 'ALLBERT_HOME=%s\n' "${ALLBERT_HOME:-}"
    printf 'V11_ENV_COPY=%s\n' "${V11_ENV_COPY:-}"
    printf 'V11_DAEMON_PID=%s\n' "${V11_DAEMON_PID:-}"
    printf 'V11_DAEMON_LABEL=%s\n' "${V11_DAEMON_LABEL:-}"
    printf 'V11_DAEMON_LOG=%s\n' "${V11_DAEMON_LOG:-}"
  } >"$tmp"

  chmod 600 "$tmp"
  mv "$tmp" "$STATE_FILE"
}

load_state() {
  local line key value seen='|' physical evidence_parent
  [ -f "$STATE_FILE" ] || die "validation state is unavailable; run '$0 prepare'"
  [ "$(stat_mode "$STATE_FILE")" = 600 ] || die "state file must have mode 600: $STATE_FILE"

  V11_STATE_VERSION=''
  V11_STATUS=''
  V11_TEST_MODE=''
  V11_SHA=''
  V11_REPO_ROOT=''
  V11_EVIDENCE_ROOT=''
  V11_VALIDATION_ROOT=''
  V11_TEMP_PARENT=''
  ALLBERT_HOME=''
  V11_ENV_COPY=''
  V11_DAEMON_PID=''
  V11_DAEMON_LABEL=''
  V11_DAEMON_LOG=''

  while IFS= read -r line || [ -n "$line" ]; do
    case "$line" in
      *=*) ;;
      *) die "state contains a malformed line" ;;
    esac
    key="${line%%=*}"
    value="${line#*=}"
    case "$seen" in
      *"|$key|"*) die "state contains duplicate key: $key" ;;
    esac
    seen="$seen$key|"
    case "$key" in
      V11_STATE_VERSION) V11_STATE_VERSION="$value" ;;
      V11_STATUS) V11_STATUS="$value" ;;
      V11_TEST_MODE) V11_TEST_MODE="$value" ;;
      V11_SHA) V11_SHA="$value" ;;
      V11_REPO_ROOT) V11_REPO_ROOT="$value" ;;
      V11_EVIDENCE_ROOT) V11_EVIDENCE_ROOT="$value" ;;
      V11_VALIDATION_ROOT) V11_VALIDATION_ROOT="$value" ;;
      V11_TEMP_PARENT) V11_TEMP_PARENT="$value" ;;
      ALLBERT_HOME) ALLBERT_HOME="$value" ;;
      V11_ENV_COPY) V11_ENV_COPY="$value" ;;
      V11_DAEMON_PID) V11_DAEMON_PID="$value" ;;
      V11_DAEMON_LABEL) V11_DAEMON_LABEL="$value" ;;
      V11_DAEMON_LOG) V11_DAEMON_LOG="$value" ;;
      *) die "state contains unknown key: $key" ;;
    esac
  done <"$STATE_FILE"

  [ "${V11_STATE_VERSION:-}" = "$STATE_VERSION" ] || die "unsupported state version"
  case "${V11_STATUS:-}" in
    preparing|ready|core_ready) ;;
    *) die "state has an invalid status" ;;
  esac
  case "${V11_TEST_MODE:-}" in
    0|1) ;;
    *) die "state has an invalid test-mode marker" ;;
  esac
  [ "${V11_REPO_ROOT:-}" = "$REPO_ROOT" ] || die "state belongs to another checkout"
  [[ "${V11_SHA:-}" =~ ^[0-9a-f]{40}$ ]] || die "state has an invalid candidate SHA"
  [ -n "${V11_EVIDENCE_ROOT:-}" ] || die "state has no evidence root"
  [ -n "${V11_VALIDATION_ROOT:-}" ] || die "state has no validation root"

  physical="$(physical_dir "$V11_TEMP_PARENT")" || die "state temp parent is unavailable"
  [ "$physical" = "$V11_TEMP_PARENT" ] || die "state temp parent is not canonical"
  physical="$(physical_dir "$V11_VALIDATION_ROOT")" || die "state validation root is unavailable"
  [ "$physical" = "$V11_VALIDATION_ROOT" ] || die "state validation root is not canonical"
  case "$V11_VALIDATION_ROOT" in
    "$V11_TEMP_PARENT"/allbert-v11-validation.*) ;;
    *) die "state validation root is not temp-parent confined" ;;
  esac
  [ -f "$V11_VALIDATION_ROOT/$ROOT_MARKER" ] || die "validation root marker is missing"
  [ "$(cat "$V11_VALIDATION_ROOT/$ROOT_MARKER")" = "$V11_SHA" ] ||
    die "validation root marker does not match the candidate"

  mkdir -p "$HOME/allbert-validation"
  evidence_parent="$(physical_dir "$HOME/allbert-validation")" ||
    die "evidence parent is unavailable"
  physical="$(physical_dir "$V11_EVIDENCE_ROOT")" || die "state evidence root is unavailable"
  [ "$physical" = "$V11_EVIDENCE_ROOT" ] || die "state evidence root is not canonical"
  case "$V11_EVIDENCE_ROOT" in
    "$evidence_parent"/v1.1-"$V11_SHA".*) ;;
    *) die "state evidence root is not validation-evidence confined" ;;
  esac

  [ "${ALLBERT_HOME:-}" = "$V11_VALIDATION_ROOT/home" ] || die "state Home is not validation-root confined"
  [ -d "$ALLBERT_HOME" ] || die "state Home is unavailable"
  [ "${V11_ENV_COPY:-}" = "$ALLBERT_HOME/.env" ] || die "state .env path is not Home-confined"

  if [ -n "${V11_DAEMON_PID:-}" ]; then
    [[ "$V11_DAEMON_PID" =~ ^[1-9][0-9]*$ ]] || die "state has an invalid daemon PID"
    [[ "${V11_DAEMON_LABEL:-}" =~ ^[A-Za-z0-9._-]+$ ]] ||
      die "state has an invalid daemon label"
    [ "${V11_DAEMON_LOG:-}" = "$V11_EVIDENCE_ROOT/OV-daemon-$V11_DAEMON_LABEL.txt" ] ||
      die "state daemon log is not evidence-root confined"
  elif [ -n "${V11_DAEMON_LABEL:-}${V11_DAEMON_LOG:-}" ]; then
    die "state has partial daemon ownership data"
  fi
}

load_env_file() {
  local path="$1" mode="${2:-apply}" line key value first last
  [ -f "$path" ] || die "credential input is missing: $path"

  while IFS= read -r line || [ -n "$line" ]; do
    line="${line%$'\r'}"
    if [[ "$line" =~ ^[[:space:]]*$ ]] || [[ "$line" =~ ^[[:space:]]*# ]]; then
      continue
    fi
    line="${line#"${line%%[![:space:]]*}"}"
    if [[ "$line" =~ ^export[[:space:]]+ ]]; then
      line="${line#export}"
      line="${line#"${line%%[![:space:]]*}"}"
    fi
    case "$line" in
      *=*) ;;
      *) die ".env contains a non-assignment line" ;;
    esac
    key="${line%%=*}"
    value="${line#*=}"
    [[ "$key" =~ ^[A-Za-z_][A-Za-z0-9_]*$ ]] || die ".env contains an invalid variable name"
    value="${value#"${value%%[![:space:]]*}"}"
    value="${value%"${value##*[![:space:]]}"}"
    if [ -n "$value" ]; then
      first="${value:0:1}"
      last="${value: -1}"
      if [ "$first" = '"' ] || [ "$first" = "'" ]; then
        [ "$last" = "$first" ] || die ".env contains an unterminated quoted value for $key"
        value="${value:1:${#value}-2}"
      fi
    fi
    if [ "$mode" = apply ]; then
      case "$key" in
        ALLBERT_HOME|ALLBERT_HOME_DIR|ALLBERT_SETTINGS_ROOT|ALLBERT_MEMORY_ROOT|\
          ALLBERT_ARTIFACTS_ROOT|ALLBERT_PLUGINS_ROOT|ALLBERT_VAULT_BACKEND|\
          DATABASE_PATH|HOME|TMPDIR|PATH|SHELL|PWD|OLDPWD|CDPATH|IFS|ENV|BASH_ENV|\
          BASHOPTS|SHELLOPTS|MIX_ENV|MIX_HOME|HEX_HOME|MIX_TEST_PARTITION|PORT|\
          RELEASE_NAME|RELEASE_ROOT|XDG_CONFIG_HOME|XDG_DATA_HOME|XDG_STATE_HOME|\
          XDG_CACHE_HOME|XDG_RUNTIME_DIR|ERL_AFLAGS|ERL_ZFLAGS|ERL_LIBS|\
          ELIXIR_ERL_OPTIONS|LD_*|DYLD_*|V11_*)
          ;;
        *) export "$key=$value" ;;
      esac
    elif [ "$mode" != validate ]; then
      die "unsupported .env parse mode: $mode"
    fi
  done <"$path"
}

require_status() {
  local expected="$1"
  load_state
  [ "$V11_STATUS" = "$expected" ] ||
    die "validation status is '$V11_STATUS', expected '$expected'"
}

load_runtime_env() {
  load_state
  [ -f "$V11_ENV_COPY" ] || die "copied .env is missing: $V11_ENV_COPY"
  [ "$(stat_mode "$V11_ENV_COPY")" = 600 ] || die "copied .env must have mode 600"
  load_env_file "$V11_ENV_COPY" apply

  # Credential input may contain development overrides. Runtime state never
  # escapes the validation Home.
  export ALLBERT_HOME="$V11_VALIDATION_ROOT/home"
  export ALLBERT_HOME_DIR="$ALLBERT_HOME"
  export ALLBERT_SETTINGS_ROOT="$ALLBERT_HOME/settings"
  export ALLBERT_MEMORY_ROOT="$ALLBERT_HOME/memory"
  export ALLBERT_ARTIFACTS_ROOT="$ALLBERT_HOME/artifacts"
  export ALLBERT_PLUGINS_ROOT="$REPO_ROOT/plugins"
  export ALLBERT_VAULT_BACKEND=encrypted_file
  export DATABASE_PATH="$ALLBERT_HOME/db/allbert.sqlite3"
  export XDG_CONFIG_HOME="$ALLBERT_HOME/xdg/config"
  export XDG_DATA_HOME="$ALLBERT_HOME/xdg/data"
  export XDG_STATE_HOME="$ALLBERT_HOME/xdg/state"
  export XDG_CACHE_HOME="$ALLBERT_HOME/xdg/cache"
  export XDG_RUNTIME_DIR="$ALLBERT_HOME/xdg/runtime"
  export MIX_ENV=dev
  export PORT=4000
  unset BASH_ENV ENV CDPATH

  [ "$ALLBERT_HOME" != "$HOME/.allbert" ] || die "validation resolved the normal Home"
  [ "$ALLBERT_SETTINGS_ROOT" = "$ALLBERT_HOME/settings" ] || die "settings escaped Home"
  [ "$ALLBERT_MEMORY_ROOT" = "$ALLBERT_HOME/memory" ] || die "memory escaped Home"
  [ "$ALLBERT_ARTIFACTS_ROOT" = "$ALLBERT_HOME/artifacts" ] || die "artifacts escaped Home"
  [ "$DATABASE_PATH" = "$ALLBERT_HOME/db/allbert.sqlite3" ] || die "database escaped Home"
  [ "$ALLBERT_PLUGINS_ROOT" = "$REPO_ROOT/plugins" ] || die "plugin root escaped checkout"
  [ "$ALLBERT_VAULT_BACKEND" = encrypted_file ] || die "vault backend is not Home-local"
  [ "$XDG_CONFIG_HOME" = "$ALLBERT_HOME/xdg/config" ] || die "XDG config escaped Home"
  [ "$XDG_DATA_HOME" = "$ALLBERT_HOME/xdg/data" ] || die "XDG data escaped Home"
  [ "$XDG_STATE_HOME" = "$ALLBERT_HOME/xdg/state" ] || die "XDG state escaped Home"
  [ "$XDG_CACHE_HOME" = "$ALLBERT_HOME/xdg/cache" ] || die "XDG cache escaped Home"
  [ "$XDG_RUNTIME_DIR" = "$ALLBERT_HOME/xdg/runtime" ] || die "XDG runtime escaped Home"
}

run_capture() {
  local evidence="$1"
  shift
  mkdir -p "$(dirname "$evidence")"
  "$@" 2>&1 | tee "$evidence"
}

process_command() {
  ps -p "$1" -o command= 2>/dev/null || true
}

process_cwd() {
  case "$(uname -s)" in
    Darwin)
      lsof -a -p "$1" -d cwd -Fn 2>/dev/null | sed -n 's/^n//p' | head -1 || true
      ;;

    Linux)
      readlink "/proc/$1/cwd" 2>/dev/null || true
      ;;

    *)
      return 0
      ;;
  esac
}

daemon_owned() {
  local pid="$1" command cwd
  command="$(process_command "$pid")"
  cwd="$(process_cwd "$pid")"
  [ -n "$command" ] && [ "$cwd" = "$REPO_ROOT" ] &&
    printf '%s\n' "$command" | grep -q 'mix phx.server'
}

ensure_daemon_absent() {
  if [ -n "${V11_DAEMON_PID:-}" ]; then
    if kill -0 "$V11_DAEMON_PID" 2>/dev/null; then
      die "daemon already recorded as running: pid=$V11_DAEMON_PID label=$V11_DAEMON_LABEL"
    fi
    V11_DAEMON_PID=""
    V11_DAEMON_LABEL=""
    V11_DAEMON_LOG=""
    write_state
  fi
}

cmd_help() {
  cat <<'EOF'
Usage: scripts/validation/v11_operator.sh COMMAND [ARGS]

State and core:
  prepare                         OV-00: clean main, fresh Home, audits/gates
  status                          Print redacted state and daemon status
  core-setup                      OV-01: migrate, capture onboarding, set TUI/fanout
  tui                             OV-02: launch transcript-captured warm TUI

Web and channel lifecycle:
  daemon-start LABEL              Start one validation Phoenix/channel daemon
  daemon-stop                     Stop the owned validation daemon
  channel-configure CHANNEL       Configure one channel from the copied .env
  channel-doctor OV-ID CHANNEL    Capture one redacted channel doctor
  notify-off CHANNEL              Set/verify autonomous notification OFF
  notify-on CHANNEL               Set/verify status+completion notification ON
  confirmation-on                 Set command execution to confirmation-required
  confirmation-off                Restore command execution to denied
  audit-copy OV-ID CHANNEL        Copy the private notify audit for redaction
  external-smoke OV-ID CHANNEL    Run a named opt-in external smoke

Cancellation and closeout:
  ov12-source                     Capture source cancellation tests
  ov12-host HOST BIN EVIDENCE     Run packaged proof in a host-local fresh Home
  cleanup                         Remove only the validated fresh Home; keep evidence

The harness is executed, never sourced. A non-zero result cannot exit the
caller's terminal. Do not continue to the next numbered OV row after V11 STOP.
EOF
}

cmd_prepare() {
  local env_source left_right top_count evidence_parent validation_root
  require_command git
  require_command mix
  require_command bash
  require_command tee
  require_command pgrep

  cd "$REPO_ROOT"

  if [ "${V11_HARNESS_TEST_MODE:-0}" != 1 ]; then
    V11_TEST_MODE=0
    [ "$(git branch --show-current)" = main ] || die "candidate must be on main"
    left_right="$(git rev-list --left-right --count HEAD...origin/main)"
    [ "$left_right" = $'0\t0' ] || die "main is not synchronized with origin/main: $left_right"
    [ -z "$(git status --short)" ] || die "worktree is not clean"
    if pgrep -f '[a]llbert.*serve|[m]ix phx.server|[m]ix allbert.tui' >/dev/null; then
      die "exit every Allbert daemon, TUI, and Phoenix server before prepare"
    fi
  elif [ "${MIX_ENV:-}" != test ]; then
    die "V11_HARNESS_TEST_MODE is allowed only with MIX_ENV=test"
  else
    V11_TEST_MODE=1
  fi

  [ ! -e "$STATE_FILE" ] || die "state already exists; inspect '$0 status' before cleanup/restart"
  if [ "${V11_HARNESS_TEST_MODE:-0}" = 1 ]; then
    env_source="${V11_ENV_SOURCE_OVERRIDE:-$REPO_ROOT/.env}"
  else
    env_source="$REPO_ROOT/.env"
  fi
  [ -f "$env_source" ] || die "credential input is missing: $env_source"
  load_env_file "$env_source" validate

  V11_SHA="$(git rev-parse HEAD)"
  V11_REPO_ROOT="$REPO_ROOT"
  mkdir -p "$HOME/allbert-validation"
  chmod 700 "$HOME/allbert-validation"
  evidence_parent="$(physical_dir "$HOME/allbert-validation")"
  V11_EVIDENCE_ROOT="$(mktemp -d "$evidence_parent/v1.1-$V11_SHA.XXXXXX")"
  V11_EVIDENCE_ROOT="$(physical_dir "$V11_EVIDENCE_ROOT")"
  chmod 700 "$V11_EVIDENCE_ROOT"

  V11_TEMP_PARENT="${TMPDIR:-/tmp}"
  V11_TEMP_PARENT="$(physical_dir "$V11_TEMP_PARENT")" || die "temporary parent is unavailable"
  validation_root="$(mktemp -d "$V11_TEMP_PARENT/allbert-v11-validation.XXXXXX")"
  V11_VALIDATION_ROOT="$(physical_dir "$validation_root")"
  ALLBERT_HOME="$V11_VALIDATION_ROOT/home"
  V11_ENV_COPY="$ALLBERT_HOME/.env"
  V11_STATUS=preparing
  V11_DAEMON_PID=""
  V11_DAEMON_LABEL=""
  V11_DAEMON_LOG=""
  printf '%s\n' "$V11_SHA" >"$V11_VALIDATION_ROOT/$ROOT_MARKER"
  chmod 600 "$V11_VALIDATION_ROOT/$ROOT_MARKER"
  write_state
  mkdir -p "$ALLBERT_HOME"
  [ -z "$(find "$ALLBERT_HOME" -mindepth 1 -print -quit)" ] || die "new Home is not empty"
  cp "$env_source" "$V11_ENV_COPY"
  chmod 600 "$V11_ENV_COPY"
  top_count="$(find "$ALLBERT_HOME" -mindepth 1 -maxdepth 1 -print | wc -l | tr -d ' ')"
  [ "$top_count" = 1 ] || die "fresh Home contains state beyond the copied .env"

  if [ "${V11_HARNESS_TEST_MODE:-0}" = 1 ] &&
     [ "${V11_FAIL_AFTER_CREATE_FOR_TESTS:-0}" = 1 ]; then
    die "injected post-create failure"
  fi
  load_runtime_env

  [ ! -e "$DATABASE_PATH" ] || die "database existed before the first product command"
  [ ! -d "$ALLBERT_SETTINGS_ROOT" ] || die "settings existed before the first product command"

  printf 'candidate_sha=%s\nvalidation_home=%s\nbootstrap_state=empty\nenv_copy=%s\n' \
    "$V11_SHA" "$ALLBERT_HOME" "$V11_ENV_COPY" \
    >"$V11_EVIDENCE_ROOT/OV-00-environment.txt"
  git status --short --branch >"$V11_EVIDENCE_ROOT/OV-00-git.txt"
  elixir --version >"$V11_EVIDENCE_ROOT/OV-00-elixir.txt"

  if [ "${V11_HARNESS_TEST_MODE:-0}" != 1 ]; then
    run_capture "$V11_EVIDENCE_ROOT/OV-00-hex.txt" mix hex.info
    run_capture "$V11_EVIDENCE_ROOT/OV-00-audit.txt" mix allbert.hex_audit
    run_capture "$V11_EVIDENCE_ROOT/OV-00-release-v1.txt" \
      env MIX_ENV=test mix allbert.test release.v1
    run_capture "$V11_EVIDENCE_ROOT/OV-00-release-v11.txt" \
      env MIX_ENV=test mix allbert.test release.v11
  else
    printf 'test-mode: gates intentionally not executed\n' >"$V11_EVIDENCE_ROOT/OV-00-test-mode.txt"
  fi

  V11_STATUS=ready
  write_state
  note "OV-00 PASS candidate=$V11_SHA"
  note "Home=$ALLBERT_HOME"
  note "evidence=$V11_EVIDENCE_ROOT"
}

cmd_status() {
  local daemon_status=stopped
  load_state
  if [ -n "${V11_DAEMON_PID:-}" ]; then
    if kill -0 "$V11_DAEMON_PID" 2>/dev/null; then
      if daemon_owned "$V11_DAEMON_PID"; then
        daemon_status="running:$V11_DAEMON_PID:$V11_DAEMON_LABEL"
      else
        daemon_status="unsafe-pid-mismatch:$V11_DAEMON_PID"
      fi
    else
      daemon_status="stale:$V11_DAEMON_PID"
    fi
  fi
  printf 'candidate_sha=%s\nstatus=%s\nvalidation_home=%s\nevidence_root=%s\ndaemon=%s\n' \
    "$V11_SHA" "$V11_STATUS" "$ALLBERT_HOME" "$V11_EVIDENCE_ROOT" "$daemon_status"
}

capture_interactive() {
  local evidence="$1" command="$2"
  require_command script
  case "$(uname -s)" in
    Darwin) script -q "$evidence" bash -lc "$command" ;;
    Linux) script -q -e -c "$command" "$evidence" ;;
    *) die "interactive capture is unsupported on $(uname -s)" ;;
  esac
}

cmd_core_setup() {
  local core_output
  require_status ready
  load_runtime_env
  ensure_daemon_absent

  run_capture "$V11_EVIDENCE_ROOT/OV-01-migrate.txt" mix allbert.ecto.migrate --quiet
  if [ "$V11_TEST_MODE" = 1 ]; then
    printf 'test-mode: interactive onboarding intentionally bypassed\n' \
      >"$V11_EVIDENCE_ROOT/OV-01-onboarding.txt"
  else
    capture_interactive "$V11_EVIDENCE_ROOT/OV-01-onboarding.txt" \
      "cd $(shell_quote "$REPO_ROOT") && mix allbert.onboard --quickstart"
  fi
  if [ "$V11_TEST_MODE" = 1 ]; then
    export V11_TEST_MODE
    export V11_VALIDATION_TEST_BYPASS_ONBOARDING=1
  else
    unset V11_VALIDATION_TEST_BYPASS_ONBOARDING || true
  fi
  core_output="$(mix run --no-start scripts/validation/v11_core_setup.exs)"
  printf '%s\n' "$core_output" | tee "$V11_EVIDENCE_ROOT/OV-01-core-settings.txt"
  printf '%s\n' "$core_output" | grep -q 'onboard status=complete' ||
    die "onboarding completion verification is absent"
  printf '%s\n' "$core_output" | grep -q 'V11 CORE SETTINGS PASS' ||
    die "core settings verification is absent"
  printf '%s\n' "$core_output" | sed -n '/Channel: tui/,$p' \
    >"$V11_EVIDENCE_ROOT/OV-01-tui.txt"

  V11_STATUS=core_ready
  write_state
  note 'OV-01 core setup PASS; inspect onboarding evidence before OV-02'
}

cmd_tui() {
  require_status core_ready
  load_runtime_env
  ensure_daemon_absent
  capture_interactive "$V11_EVIDENCE_ROOT/OV-02-tui.txt" \
    "cd $(shell_quote "$REPO_ROOT") && mix allbert.tui"
}

cmd_capture_test() {
  load_state
  [ "$V11_TEST_MODE" = 1 ] || die "capture-test is test-only"
  capture_interactive "$V11_EVIDENCE_ROOT/OV-capture-test.txt" \
    "printf V11_CAPTURE_TEST_PASS"
  grep -q 'V11_CAPTURE_TEST_PASS' "$V11_EVIDENCE_ROOT/OV-capture-test.txt" ||
    die "interactive transcript capture emitted no PASS marker"
}

cmd_daemon_start() {
  local label="${1:-}" health_ok="" log pid
  [ -n "$label" ] || die "daemon-start requires LABEL"
  [[ "$label" =~ ^[A-Za-z0-9._-]+$ ]] || die "daemon label contains unsafe characters"
  require_status core_ready
  load_runtime_env
  ensure_daemon_absent
  require_command curl
  require_command nohup
  case "$(uname -s)" in
    Darwin) require_command lsof ;;
    Linux) require_command readlink ;;
  esac

  if curl -fsS http://127.0.0.1:4000/health >/dev/null 2>&1; then
    die "port 4000 already serves a healthy process"
  fi

  log="$V11_EVIDENCE_ROOT/OV-daemon-$label.txt"
  cd "$REPO_ROOT"
  nohup mix phx.server >"$log" 2>&1 </dev/null &
  pid=$!
  V11_DAEMON_PID="$pid"
  V11_DAEMON_LABEL="$label"
  V11_DAEMON_LOG="$log"
  write_state

  for _ in $(seq 1 30); do
    if curl -fsS http://127.0.0.1:4000/health >/dev/null 2>&1; then
      health_ok=1
      break
    fi
    sleep 1
  done

  if [ -z "$health_ok" ]; then
    tail -n 80 "$log" || true
    die "daemon did not become healthy within 30 seconds; pid retained in state"
  fi
  daemon_owned "$pid" || die "started PID is not an owned mix phx.server process"
  curl -fsS http://127.0.0.1:4000/health >"$V11_EVIDENCE_ROOT/OV-daemon-$label-health.txt"
  note "daemon PASS label=$label pid=$pid"
}

cmd_daemon_stop() {
  local pid
  load_state
  [ -n "${V11_DAEMON_PID:-}" ] || { note 'daemon already stopped'; return 0; }
  pid="$V11_DAEMON_PID"
  if kill -0 "$pid" 2>/dev/null; then
    daemon_owned "$pid" || die "refusing to kill PID $pid: ownership check failed"
    kill "$pid"
    for _ in $(seq 1 30); do
      kill -0 "$pid" 2>/dev/null || break
      sleep 1
    done
    kill -0 "$pid" 2>/dev/null && die "owned daemon did not stop within 30 seconds"
  fi
  V11_DAEMON_PID=""
  V11_DAEMON_LABEL=""
  V11_DAEMON_LOG=""
  write_state
  note 'daemon stopped'
}

cmd_channel_configure() {
  local channel="${1:-}" channels evidence output
  [ -n "$channel" ] || die "channel-configure requires CHANNEL"
  require_status core_ready
  load_runtime_env
  ensure_daemon_absent
  if [ "$channel" = all-test ]; then
    [ "$V11_TEST_MODE" = 1 ] || die "all-test channel configuration is test-only"
    channels='telegram,email,discord,slack,matrix,whatsapp,signal'
    evidence="$V11_EVIDENCE_ROOT/OV-01-all-channel-configure.txt"
  else
    require_external_channel "$channel"
    channels="$channel"
    evidence="$V11_EVIDENCE_ROOT/OV-01-$channel-configure.txt"
  fi

  export V11_CHANNEL="$channels"
  run_capture "$evidence" mix run --no-start scripts/validation/v11_channel_configure.exs
  if [ "$channel" = all-test ]; then
    for output in telegram email discord slack matrix whatsapp signal; do
      grep -q "V11 CHANNEL CONFIGURATION PASS channel=$output" "$evidence" ||
        die "$output configuration emitted no PASS marker"
    done
    note 'all test channel configurations PASS'
    return 0
  fi
  output="$(sed -n "/Channel: $channel/,\$p" "$evidence")"
  printf '%s\n' "$output" >"$V11_EVIDENCE_ROOT/OV-01-$channel-show.txt"
  grep -q 'V11 CHANNEL CONFIGURATION PASS' "$evidence" ||
    die "$channel configuration emitted no PASS marker"
  note "channel configuration PASS channel=$channel"
}

cmd_channel_doctor() {
  local ov_id="${1:-}" channel="${2:-}"
  [ -n "$ov_id" ] && [ -n "$channel" ] || die "channel-doctor requires OV-ID CHANNEL"
  require_ov_id "$ov_id"
  require_status core_ready
  load_runtime_env
  ensure_daemon_absent
  require_external_channel "$channel"
  run_capture "$V11_EVIDENCE_ROOT/$ov_id-$channel-doctor.txt" \
    mix allbert.channels "$channel" doctor
}

cmd_notify_off() {
  local channel="${1:-}"
  [ -n "$channel" ] || die "notify-off requires CHANNEL"
  require_status core_ready
  load_runtime_env
  ensure_daemon_absent
  require_external_channel "$channel"
  export V11_CHANNEL="$channel"
  export V11_SETTINGS_TRANSITION=notify-off
  run_capture "$V11_EVIDENCE_ROOT/OV-04-$channel-setting.txt" \
    mix run --no-start scripts/validation/v11_settings_transition.exs
}

cmd_notify_on() {
  local channel="${1:-}"
  [ -n "$channel" ] || die "notify-on requires CHANNEL"
  require_status core_ready
  load_runtime_env
  ensure_daemon_absent
  require_external_channel "$channel"
  export V11_CHANNEL="$channel"
  export V11_SETTINGS_TRANSITION=notify-on
  run_capture "$V11_EVIDENCE_ROOT/OV-05-$channel-setting.txt" \
    mix run --no-start scripts/validation/v11_settings_transition.exs
}

cmd_confirmation_on() {
  require_status core_ready
  load_runtime_env
  ensure_daemon_absent
  export V11_SETTINGS_TRANSITION=confirmation-on
  run_capture "$V11_EVIDENCE_ROOT/OV-11-confirmation-setting.txt" \
    mix run --no-start scripts/validation/v11_settings_transition.exs
}

cmd_confirmation_off() {
  require_status core_ready
  load_runtime_env
  ensure_daemon_absent
  export V11_SETTINGS_TRANSITION=confirmation-off
  run_capture "$V11_EVIDENCE_ROOT/OV-11-confirmation-restore.txt" \
    mix run --no-start scripts/validation/v11_settings_transition.exs
}

cmd_settings_test_all() {
  require_status core_ready
  [ "$V11_TEST_MODE" = 1 ] || die "settings-test-all is test-only"
  load_runtime_env
  ensure_daemon_absent
  export V11_TEST_MODE
  export V11_CHANNEL=telegram
  export V11_SETTINGS_TRANSITION=all-test
  run_capture "$V11_EVIDENCE_ROOT/OV-settings-transition-all-test.txt" \
    mix run --no-start scripts/validation/v11_settings_transition.exs
}

cmd_audit_copy() {
  local ov_id="${1:-}" channel="${2:-}" source destination
  [ -n "$ov_id" ] && [ -n "$channel" ] || die "audit-copy requires OV-ID CHANNEL"
  require_ov_id "$ov_id"
  require_external_channel "$channel"
  load_runtime_env
  source="$ALLBERT_HOME/channels/notify/audit/$(date +%Y-%m).md"
  [ -f "$source" ] || die "notify audit is missing: $source"
  destination="$V11_EVIDENCE_ROOT/$ov_id-$channel-audit.private.md"
  cp "$source" "$destination"
  chmod 600 "$destination"
  note "private audit copied: $destination"
  note 'inspect and redact before sharing; .private.md is not share-ready'
}

cmd_external_smoke() {
  local ov_id="${1:-}" channel="${2:-}"
  [ -n "$ov_id" ] && [ -n "$channel" ] || die "external-smoke requires OV-ID CHANNEL"
  require_ov_id "$ov_id"
  require_external_channel "$channel"
  load_runtime_env
  run_capture "$V11_EVIDENCE_ROOT/$ov_id-$channel-external-smoke.txt" \
    env MIX_ENV=test mix allbert.test external-smoke -- "$channel"
}

cmd_ov12_source() {
  require_status core_ready
  load_runtime_env
  run_capture "$V11_EVIDENCE_ROOT/OV-12-source-cancel.txt" env MIX_ENV=test mix test \
    apps/allbert_assist/test/allbert_assist/execution/process_group_cancel_test.exs \
    apps/allbert_assist/test/allbert_assist/objectives/delegate_cancel_test.exs
}

ov12_run_mode() {
  local mode="$1" evidence request_output request_rc confirmation_id approval_output approval_rc
  evidence="$OV12_EVIDENCE_ROOT/OV-12-$OV12_HOST-$mode.txt"
  set +e
  request_output="$("$ALLBERT_BIN" admin cancellation-proof "$mode" 2>&1)"
  request_rc=$?
  set -e
  printf '%s\n' "$request_output" | tee "$evidence"
  [ "$request_rc" -eq 1 ] || die "OV-12 $mode confirmation handoff exited $request_rc, expected 1"
  confirmation_id="$(printf '%s\n' "$request_output" |
    sed -n 's/.*Confirmation: \(conf_[^.[:space:]]*\).*/\1/p' | head -1)"
  [ -n "$confirmation_id" ] || die "OV-12 $mode emitted no confirmation id"
  set +e
  approval_output="$("$ALLBERT_BIN" admin confirmations approve "$confirmation_id" 2>&1)"
  approval_rc=$?
  set -e
  printf '%s\n' "$approval_output" | tee -a "$evidence"
  [ "$approval_rc" -eq 0 ] || die "OV-12 $mode approval exited $approval_rc"
  if [ "$mode" = session-escape ] && printf '%s\n' "$approval_output" |
    grep -q 'status=UNSUPPORTED'; then
    note "OV-12 session-escape has the documented unsupported disposition"
  else
    printf '%s\n' "$approval_output" | grep -q 'OV12 status=PASS' ||
      die "OV-12 $mode emitted no PASS marker"
  fi
}

cmd_ov12_host() {
  local host="${1:-}" bin="${2:-}" evidence_root="${3:-}" home temp_parent rc=0
  [ -n "$host" ] && [ -n "$bin" ] && [ -n "$evidence_root" ] ||
    die "ov12-host requires HOST BIN EVIDENCE_ROOT"
  case "$host" in
    macos|linux-x64|linux-arm64|wsl2) ;;
    *) die "unsupported OV-12 host label: $host" ;;
  esac
  case "$bin" in
    /*) ;;
    *) die "candidate binary path must be absolute: $bin" ;;
  esac
  case "$evidence_root" in
    /*) ;;
    *) die "OV-12 evidence root must be an absolute path" ;;
  esac
  [ -x "$bin" ] || die "candidate binary is not executable: $bin"
  mkdir -p "$evidence_root"
  chmod 700 "$evidence_root"
  temp_parent="$(physical_dir "${TMPDIR:-/tmp}")" || die "temporary parent is unavailable"
  home="$(mktemp -d "$temp_parent/allbert-ov12-$host.XXXXXX")"
  home="$(physical_dir "$home")"
  chmod 700 "$home"

  (
    export OV12_HOST="$host"
    export ALLBERT_BIN="$bin"
    export OV12_EVIDENCE_ROOT="$evidence_root"
    export ALLBERT_HOME="$home"
    export ALLBERT_HOME_DIR="$ALLBERT_HOME"
    export ALLBERT_SETTINGS_ROOT="$ALLBERT_HOME/settings"
    export ALLBERT_MEMORY_ROOT="$ALLBERT_HOME/memory"
    export ALLBERT_ARTIFACTS_ROOT="$ALLBERT_HOME/artifacts"
    export ALLBERT_VAULT_BACKEND=encrypted_file
    export DATABASE_PATH="$ALLBERT_HOME/db/allbert.sqlite3"
    export XDG_CONFIG_HOME="$ALLBERT_HOME/xdg/config"
    export XDG_DATA_HOME="$ALLBERT_HOME/xdg/data"
    export XDG_STATE_HOME="$ALLBERT_HOME/xdg/state"
    export XDG_CACHE_HOME="$ALLBERT_HOME/xdg/cache"
    export XDG_RUNTIME_DIR="$ALLBERT_HOME/xdg/runtime"
    unset ALLBERT_PLUGINS_ROOT RELEASE_ROOT BASH_ENV ENV CDPATH
    trap 'printf "OV-12 Home retained: %s\\n" "$ALLBERT_HOME"' EXIT
    "$ALLBERT_BIN" admin settings set permissions.command_execute needs_confirmation
    ov12_run_mode cancel
    ov12_run_mode timeout
    ov12_run_mode session-escape
    "$ALLBERT_BIN" admin settings set permissions.command_execute denied
    trap - EXIT
    case "$ALLBERT_HOME" in
      "$temp_parent"/allbert-ov12-*) rm -rf -- "$ALLBERT_HOME" ;;
      *) die "refusing unexpected OV-12 cleanup path: $ALLBERT_HOME" ;;
    esac
  ) || rc=$?

  [ "$rc" -eq 0 ] || die "OV-12 host proof failed; retained Home=$home"
  note "OV-12 host PASS host=$host"
}

cmd_cleanup() {
  local expected_prefix physical
  load_state
  if [ -n "${V11_DAEMON_PID:-}" ] && kill -0 "$V11_DAEMON_PID" 2>/dev/null; then
    die "stop the owned daemon before cleanup: pid=$V11_DAEMON_PID"
  fi
  [ "$ALLBERT_HOME" = "$V11_VALIDATION_ROOT/home" ] || die "cleanup Home mismatch"
  [ "$ALLBERT_HOME" != "$HOME/.allbert" ] || die "refusing normal Home cleanup"
  expected_prefix="$V11_TEMP_PARENT/allbert-v11-validation."
  physical="$(physical_dir "$V11_VALIDATION_ROOT")" || die "validation root is unavailable"
  [ "$physical" = "$V11_VALIDATION_ROOT" ] || die "validation root is not canonical"
  case "$V11_VALIDATION_ROOT" in
    "$expected_prefix"*) ;;
    *) die "refusing unexpected validation cleanup path: $V11_VALIDATION_ROOT" ;;
  esac
  [ -f "$V11_VALIDATION_ROOT/$ROOT_MARKER" ] || die "validation root marker is missing"
  [ "$(cat "$V11_VALIDATION_ROOT/$ROOT_MARKER")" = "$V11_SHA" ] ||
    die "validation root marker does not match the candidate"
  rm -rf -- "$V11_VALIDATION_ROOT"
  rm -f -- "$STATE_FILE"
  note "cleanup PASS; evidence retained at $V11_EVIDENCE_ROOT"
}

main() {
  local command="${1:-help}"
  shift || true
  case "$command" in
    help|-h|--help) cmd_help "$@" ;;
    prepare) cmd_prepare "$@" ;;
    status) cmd_status "$@" ;;
    core-setup) cmd_core_setup "$@" ;;
    tui) cmd_tui "$@" ;;
    capture-test) cmd_capture_test "$@" ;;
    daemon-start) cmd_daemon_start "$@" ;;
    daemon-stop) cmd_daemon_stop "$@" ;;
    channel-configure) cmd_channel_configure "$@" ;;
    channel-doctor) cmd_channel_doctor "$@" ;;
    notify-off) cmd_notify_off "$@" ;;
    notify-on) cmd_notify_on "$@" ;;
    confirmation-on) cmd_confirmation_on "$@" ;;
    confirmation-off) cmd_confirmation_off "$@" ;;
    settings-test-all) cmd_settings_test_all "$@" ;;
    audit-copy) cmd_audit_copy "$@" ;;
    external-smoke) cmd_external_smoke "$@" ;;
    ov12-source) cmd_ov12_source "$@" ;;
    ov12-host) cmd_ov12_host "$@" ;;
    cleanup) cmd_cleanup "$@" ;;
    *) die "unknown command: $command (run '$0 help')" ;;
  esac
}

main "$@"
