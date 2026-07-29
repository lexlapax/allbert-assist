#!/usr/bin/env bash
# v1.2.1 M0.b3 — thin-TUI PTY and attended qualification.
#
# Automated source row:
#   scripts/smoke/v121_tui_qualification.sh --source
# Release-stage exact-artifact row (primary CI contract):
#   scripts/smoke/v121_tui_qualification.sh RELEASE_ROOT TARGET OUTPUT_JSON
# Standalone exact-archive row:
#   scripts/smoke/v121_tui_qualification.sh --artifact /path/allbert-v1.2.1-TARGET.tar.gz
# Mandatory operator-attended barriers add --attended. See the active
# request-flow for the required environment and PASS criteria.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
PYTHON_HELPER="$SCRIPT_DIR/v121_tui_pty.py"

MODE=""
ARTIFACT=""
ATTENDED=0
POSITIONAL_FV=0
RELEASE_ROOT=""
TARGET=""
FV_OUTPUT=""

usage() {
  cat <<'USAGE'
Usage:
  v121_tui_qualification.sh RELEASE_ROOT TARGET OUTPUT_JSON
  v121_tui_qualification.sh --source [--attended]
  v121_tui_qualification.sh --artifact ARCHIVE [--attended]

Automated rows use a new disposable Allbert Home and retain only a content-free
PASS manifest. The attended row requires V121_TUI_HOME,
V121_TUI_EVIDENCE_DIR, V121_TUI_PROVIDER_PROFILE, and an exact subject:

  source:   V121_EXPECTED_SHA=<clean pushed git sha>
  artifact: V121_EXPECTED_SHA256=<sha256 of ARCHIVE>
            V121_EXPECTED_SOURCE_SHA=<source sha from digest manifest>

Optional bounded controls:
  V121_TUI_PORT, V121_TUI_PROMPT_REGEX, V121_TUI_NO_DAEMON_REGEX,
  V121_TUI_OCCUPIED_REGEX, V121_TUI_DAEMON_LOSS_REGEX,
  V121_TUI_KEEP_TMP=1, V121_TUI_MIX_ENV (source row; default test/dev).
USAGE
}

if [ "$#" -eq 3 ] && [ "${1#-}" = "$1" ]; then
  POSITIONAL_FV=1
  MODE="artifact"
  RELEASE_ROOT="$1"
  TARGET="$2"
  FV_OUTPUT="$3"
  shift 3
fi

while [ "$#" -gt 0 ]; do
  case "$1" in
    --source)
      [ -z "$MODE" ] || { echo "v121-tui-qualification: choose one mode" >&2; exit 2; }
      MODE="source"
      shift
      ;;
    --artifact)
      [ -z "$MODE" ] || { echo "v121-tui-qualification: choose one mode" >&2; exit 2; }
      [ "$#" -ge 2 ] || { usage >&2; exit 2; }
      MODE="artifact"
      ARTIFACT="$2"
      shift 2
      ;;
    --attended)
      ATTENDED=1
      shift
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      echo "v121-tui-qualification: unknown argument: $1" >&2
      usage >&2
      exit 2
      ;;
  esac
done

[ -n "$MODE" ] || { usage >&2; exit 2; }
command -v python3 >/dev/null 2>&1 || {
  echo "v121-tui-qualification: python3 is required (standard library only; no packages)" >&2
  exit 1
}
command -v curl >/dev/null 2>&1 || {
  echo "v121-tui-qualification: curl is required for the daemon/Web health check" >&2
  exit 1
}
[ -f "$PYTHON_HELPER" ] || {
  echo "v121-tui-qualification: missing helper $PYTHON_HELPER" >&2
  exit 1
}

umask 077
# Keep the disposable Home's resolved path below the Unix-domain socket limit.
# A deep platform TMPDIR makes the product correctly choose its hashed short-path
# fallback, which would cause the bind-failure fixture to obstruct the wrong path.
WORK="$(mktemp -d /tmp/allbert-v121-tui.XXXXXX)"
DAEMON_PID=""
ACTIVE_CHILD_PID=""
PENDING_EVIDENCE_TMP=""
PENDING_EVIDENCE_FINAL=""
OWNED_EVIDENCE_DIR=""
CLEANING_UP=0
FINAL_SUCCESS_MESSAGE=""
ACQUIRING_CHILD=0
DEFERRED_SIGNAL_STATUS=0

terminate_pid() {
  local target_pid="$1"
  local attempts=0
  local process_state=""
  [ -n "$target_pid" ] || return 0
  kill -CONT "$target_pid" 2>/dev/null || true
  kill -TERM "$target_pid" 2>/dev/null || true
  while kill -0 "$target_pid" 2>/dev/null && [ "$attempts" -lt 200 ]; do
    process_state="$(ps -o stat= -p "$target_pid" 2>/dev/null || true)"
    case "$process_state" in
      ''|*Z*) break ;;
    esac
    sleep 0.1
    attempts=$((attempts + 1))
  done
  if kill -0 "$target_pid" 2>/dev/null; then
    process_state="$(ps -o stat= -p "$target_pid" 2>/dev/null || true)"
    case "$process_state" in
      *Z*) ;;
      *) kill -KILL "$target_pid" 2>/dev/null || true ;;
    esac
  fi

  attempts=0
  while kill -0 "$target_pid" 2>/dev/null && [ "$attempts" -lt 50 ]; do
    process_state="$(ps -o stat= -p "$target_pid" 2>/dev/null || true)"
    case "$process_state" in
      ''|*Z*) break ;;
    esac
    sleep 0.1
    attempts=$((attempts + 1))
  done
  if kill -0 "$target_pid" 2>/dev/null; then
    process_state="$(ps -o stat= -p "$target_pid" 2>/dev/null || true)"
    case "$process_state" in
      *Z*) ;;
      *)
        echo "v121-tui-qualification: process $target_pid did not terminate within the cleanup deadline" >&2
        return 1
        ;;
    esac
  fi
  wait "$target_pid" 2>/dev/null || true
}

cleanup() {
  trap '' INT TERM HUP
  local cleanup_mode="${1:-failure}"
  local cleanup_failed=0
  [ "$CLEANING_UP" -eq 0 ] || return 0
  CLEANING_UP=1
  if [ -n "$ACTIVE_CHILD_PID" ]; then
    terminate_pid "$ACTIVE_CHILD_PID" || cleanup_failed=1
    ACTIVE_CHILD_PID=""
  fi
  if [ -n "$DAEMON_PID" ]; then
    terminate_pid "$DAEMON_PID" || cleanup_failed=1
    DAEMON_PID=""
  fi
  if [ -n "$PENDING_EVIDENCE_TMP" ]; then
    rm -f -- "$PENDING_EVIDENCE_TMP" || cleanup_failed=1
    if [ -e "$PENDING_EVIDENCE_TMP" ] || [ -L "$PENDING_EVIDENCE_TMP" ]; then
      cleanup_failed=1
    fi
    PENDING_EVIDENCE_TMP=""
  fi
  if [ "$cleanup_mode" = "success" ] || [ "${V121_TUI_KEEP_TMP:-0}" != "1" ]; then
    rm -rf -- "$WORK" || cleanup_failed=1
    if [ -e "$WORK" ] || [ -L "$WORK" ]; then
      cleanup_failed=1
    fi
  else
    echo "v121-tui-qualification: private diagnostics retained at $WORK" >&2
  fi

  if [ "$cleanup_mode" != "success" ] || [ "$cleanup_failed" -ne 0 ]; then
    if [ -n "$PENDING_EVIDENCE_FINAL" ]; then
      rm -f -- "$PENDING_EVIDENCE_FINAL" || cleanup_failed=1
      if [ -e "$PENDING_EVIDENCE_FINAL" ] || [ -L "$PENDING_EVIDENCE_FINAL" ]; then
        echo "v121-tui-qualification: invalid evidence could not be rolled back: $PENDING_EVIDENCE_FINAL" >&2
        cleanup_failed=1
      fi
      PENDING_EVIDENCE_FINAL=""
    fi
    if [ -n "$OWNED_EVIDENCE_DIR" ]; then
      if [ -e "$OWNED_EVIDENCE_DIR" ] || [ -L "$OWNED_EVIDENCE_DIR" ]; then
        rmdir -- "$OWNED_EVIDENCE_DIR" 2>/dev/null || cleanup_failed=1
      fi
      if [ -e "$OWNED_EVIDENCE_DIR" ] || [ -L "$OWNED_EVIDENCE_DIR" ]; then
        echo "v121-tui-qualification: private evidence directory did not cleanly release: $OWNED_EVIDENCE_DIR" >&2
        cleanup_failed=1
      fi
      OWNED_EVIDENCE_DIR=""
    fi
  else
    PENDING_EVIDENCE_FINAL=""
    OWNED_EVIDENCE_DIR=""
  fi

  [ "$cleanup_failed" -eq 0 ]
}

on_signal() {
  local signal_status="$1"
  if [ "$ACQUIRING_CHILD" -eq 1 ]; then
    if [ "$DEFERRED_SIGNAL_STATUS" -eq 0 ]; then
      DEFERRED_SIGNAL_STATUS="$signal_status"
    fi
    return 0
  fi
  trap '' INT TERM HUP
  trap - EXIT
  cleanup failure || signal_status=1
  exit "$signal_status"
}

finish_child_acquisition() {
  ACQUIRING_CHILD=0
  local signal_status="$DEFERRED_SIGNAL_STATUS"
  DEFERRED_SIGNAL_STATUS=0
  if [ "$signal_status" -ne 0 ]; then
    on_signal "$signal_status"
  fi
}

spawn_active_child() {
  ACQUIRING_CHILD=1
  "$@" &
  ACTIVE_CHILD_PID=$!
  finish_child_acquisition
}

spawn_active_child_to_file() {
  local output_file="$1"
  shift
  ACQUIRING_CHILD=1
  "$@" >"$output_file" &
  ACTIVE_CHILD_PID=$!
  finish_child_acquisition
}

spawn_active_child_on_tty() {
  ACQUIRING_CHILD=1
  "$@" </dev/tty >/dev/tty 2>/dev/tty &
  ACTIVE_CHILD_PID=$!
  finish_child_acquisition
}

spawn_daemon_child() {
  local output_file="$1"
  shift
  ACQUIRING_CHILD=1
  "$@" >"$output_file" 2>&1 &
  DAEMON_PID=$!
  finish_child_acquisition
}

wait_active_child() {
  local timeout_seconds="$1"
  local label="$2"
  local child_pid="$ACTIVE_CHILD_PID"
  local deadline=$((SECONDS + timeout_seconds))
  local child_status=0

  while kill -0 "$child_pid" 2>/dev/null; do
    if [ "$SECONDS" -ge "$deadline" ]; then
      echo "v121-tui-qualification: $label exceeded ${timeout_seconds}s" >&2
      if ! terminate_pid "$child_pid"; then
        return 1
      fi
      ACTIVE_CHILD_PID=""
      return 124
    fi
    sleep 0.1
  done
  if wait "$child_pid"; then
    child_status=0
  else
    child_status=$?
  fi
  ACTIVE_CHILD_PID=""
  return "$child_status"
}

run_bounded_child() {
  local timeout_seconds="$1"
  local label="$2"
  shift 2
  spawn_active_child "$@"
  wait_active_child "$timeout_seconds" "$label"
}

run_bounded_child_to_file() {
  local timeout_seconds="$1"
  local label="$2"
  local output_file="$3"
  shift 3
  spawn_active_child_to_file "$output_file" "$@"
  wait_active_child "$timeout_seconds" "$label"
}

on_exit() {
  local exit_status=$?
  trap '' INT TERM HUP
  trap - EXIT
  if [ "$CLEANING_UP" -eq 0 ]; then
    cleanup failure || exit_status=1
  fi
  exit "$exit_status"
}

finalize_success() {
  trap '' INT TERM HUP
  if [ -z "$PENDING_EVIDENCE_FINAL" ] || [ ! -f "$PENDING_EVIDENCE_FINAL" ] || [ -L "$PENDING_EVIDENCE_FINAL" ]; then
    echo "v121-tui-qualification: staged PASS evidence is unavailable; PASS withheld" >&2
    cleanup failure || true
    return 1
  fi
  if ! cleanup success; then
    echo "v121-tui-qualification: private cleanup did not complete; PASS evidence rolled back" >&2
    return 1
  fi
  echo "$FINAL_SUCCESS_MESSAGE"
}

trap on_exit EXIT
trap 'on_signal 130' INT
trap 'on_signal 143' TERM
trap 'on_signal 129' HUP

sha256_file() {
  if command -v sha256sum >/dev/null 2>&1; then
    sha256sum "$1" | awk '{print $1}'
  else
    shasum -a 256 "$1" | awk '{print $1}'
  fi
}

sha256_text() {
  if command -v sha256sum >/dev/null 2>&1; then
    printf '%s' "$1" | sha256sum | awk '{print $1}'
  else
    printf '%s' "$1" | shasum -a 256 | awk '{print $1}'
  fi
}

validate_fresh_private_evidence_dir() {
  python3 - "$1" "${TMPDIR:-/tmp}" /tmp <<'PY'
import os
import pathlib
import stat
import sys

candidate_raw, *root_values = sys.argv[1:]
candidate_path = pathlib.Path(candidate_raw)
if candidate_path.is_symlink():
    raise SystemExit("v121-tui-qualification: evidence directory must not be a final symlink")
try:
    candidate = candidate_path.resolve(strict=True)
    roots = [pathlib.Path(value).resolve(strict=True) for value in root_values]
except (OSError, RuntimeError):
    raise SystemExit("v121-tui-qualification: evidence directory and temp roots must already exist")
if not candidate.is_dir():
    raise SystemExit("v121-tui-qualification: evidence path must be an existing directory")
metadata = candidate.stat()
if metadata.st_uid != os.geteuid():
    raise SystemExit("v121-tui-qualification: evidence directory must be operator-owned")
if stat.S_IMODE(metadata.st_mode) & 0o077:
    raise SystemExit(
        "v121-tui-qualification: evidence directory must grant no group/other access"
    )
system_root = roots[-1]
if candidate != system_root and system_root in candidate.parents:
    selected_root = system_root
else:
    matching_roots = [
        root for root in roots[:-1] if candidate != root and root in candidate.parents
    ]
    selected_root = max(matching_roots, key=lambda root: len(root.parts), default=None)
if selected_root is None:
    raise SystemExit("v121-tui-qualification: evidence directory must be below TMPDIR or /tmp")

# The selected temp root is either the OS sticky temp directory or must itself
# be operator-owned and non-writable by group/other. Every descendant ancestor
# receives the latter check so another user cannot replace the validated leaf.
if selected_root != system_root:
    root_metadata = selected_root.stat()
    if (
        root_metadata.st_uid != os.geteuid()
        or stat.S_IMODE(root_metadata.st_mode) & 0o022
    ):
        raise SystemExit("v121-tui-qualification: TMPDIR is not an operator-controlled root")
current = selected_root
for component in candidate.relative_to(selected_root).parts[:-1]:
    current /= component
    ancestor_metadata = current.stat(follow_symlinks=False)
    if not stat.S_ISDIR(ancestor_metadata.st_mode):
        raise SystemExit("v121-tui-qualification: evidence ancestor is not a directory")
    if ancestor_metadata.st_uid != os.geteuid():
        raise SystemExit("v121-tui-qualification: evidence ancestors must be operator-owned")
    if stat.S_IMODE(ancestor_metadata.st_mode) & 0o022:
        raise SystemExit("v121-tui-qualification: evidence ancestors must not be group/other writable")
try:
    next(candidate.iterdir())
except StopIteration:
    pass
except OSError:
    raise SystemExit("v121-tui-qualification: evidence directory could not be inspected")
else:
    raise SystemExit("v121-tui-qualification: evidence directory must be fresh and empty")
print(candidate)
PY
}

publish_no_clobber() {
  source_path="$1"
  destination_path="$2"
  if python3 - "$source_path" "$destination_path" <<'PY'
import os
import pathlib
import sys

source, destination = map(pathlib.Path, sys.argv[1:])
try:
    os.link(source, destination, follow_symlinks=False)
except FileExistsError:
    raise SystemExit("v121-tui-qualification: fresh evidence path is already occupied")
except OSError:
    raise SystemExit("v121-tui-qualification: atomic evidence publication failed")
source.unlink()
PY
  then
    return 0
  fi
  return 1
}

pick_port() {
  python3 -c 'import socket; s=socket.socket(); s.bind(("127.0.0.1", 0)); print(s.getsockname()[1]); s.close()'
}

DAEMON_BIN=""
DAEMON_ARGS=()
TUI_BIN=""
TUI_ARGS=()
SUBJECT=""
ARTIFACT_SHA256=""

if [ "$MODE" = "source" ]; then
  cd "$REPO_ROOT"
  DAEMON_BIN="mix"
  DAEMON_ARGS=(
    run
    --no-start
    -e
    'endpoint = Application.get_env(:allbert_assist_web, AllbertAssistWeb.Endpoint, []); Application.put_env(:allbert_assist_web, AllbertAssistWeb.Endpoint, Keyword.put(endpoint, :server, true), persistent: true); {:ok, _started} = Application.ensure_all_started(:allbert_assist_web); Process.sleep(:infinity)'
  )
  TUI_BIN="mix"
  TUI_ARGS=(allbert.tui)
  SOURCE_SHA="$(git rev-parse HEAD)"
  SUBJECT="git:$SOURCE_SHA"
elif [ "$POSITIONAL_FV" -eq 1 ]; then
  case "$TARGET" in
    macos-arm64|linux-x64|linux-arm64) ;;
    *) echo "v121-tui-qualification: unsupported target: $TARGET" >&2; exit 2 ;;
  esac
  [ -d "$RELEASE_ROOT" ] || {
    echo "v121-tui-qualification: release root not found: $RELEASE_ROOT" >&2
    exit 1
  }
  RELEASE_ROOT="$(cd "$RELEASE_ROOT" && pwd)"
  [ -x "$RELEASE_ROOT/bin/allbert" ] || {
    echo "v121-tui-qualification: no executable bin/allbert under release root" >&2
    exit 1
  }
  DAEMON_BIN="$RELEASE_ROOT/bin/allbert"
  DAEMON_ARGS=(serve)
  TUI_BIN="$DAEMON_BIN"
  TUI_ARGS=(tui)
  SUBJECT="target:$TARGET"
else
  [ -f "$ARTIFACT" ] || {
    echo "v121-tui-qualification: artifact not found: $ARTIFACT" >&2
    exit 1
  }
  ARTIFACT="$(cd "$(dirname "$ARTIFACT")" && pwd)/$(basename "$ARTIFACT")"
  ARTIFACT_SHA256="$(sha256_file "$ARTIFACT")"
  SUBJECT="sha256:$ARTIFACT_SHA256"
  if [ "$ATTENDED" -eq 1 ]; then
    : "${V121_EXPECTED_SHA256:?set V121_EXPECTED_SHA256 from the immutable digest manifest}"
    [ "$ARTIFACT_SHA256" = "$V121_EXPECTED_SHA256" ] || {
      echo "v121-tui-qualification: archive digest does not match V121_EXPECTED_SHA256" >&2
      exit 1
    }
  fi
  run_bounded_child 180 "artifact extraction" \
    env -u ALLBERT_V121_PROVIDER_CONFIG -u ALLBERT_V121_PROVIDER_MODEL \
    bash "$REPO_ROOT/scripts/release/stage_artifacts.sh" extract-release \
    "$ARTIFACT" "$WORK/artifact"
  RELEASE_ROOT="$WORK/artifact/allbert"
  DAEMON_BIN="$RELEASE_ROOT/bin/allbert"
  DAEMON_ARGS=(serve)
  TUI_BIN="$DAEMON_BIN"
  TUI_ARGS=(tui)
  case "$(uname -s)-$(uname -m)" in
    Darwin-arm64) TARGET="macos-arm64" ;;
    Linux-x86_64) TARGET="linux-x64" ;;
    Linux-aarch64) TARGET="linux-arm64" ;;
    *) TARGET="local-$(uname -s)-$(uname -m)" ;;
  esac
  if [ -n "${V121_TARGET:-}" ] && [ "$TARGET" != "$V121_TARGET" ]; then
    echo "v121-tui-qualification: archive target $V121_TARGET does not match host $TARGET" >&2
    exit 1
  fi
fi

if [ "$MODE" = "source" ]; then
  TARGET="source-local"
fi

PORT="${V121_TUI_PORT:-$(pick_port)}"
case "$PORT" in
  ''|*[!0-9]*) echo "v121-tui-qualification: V121_TUI_PORT must be numeric" >&2; exit 2 ;;
esac
if [ "$PORT" -lt 1024 ] || [ "$PORT" -gt 65535 ]; then
  echo "v121-tui-qualification: port must be between 1024 and 65535" >&2
  exit 2
fi

wait_for_health() {
  health_deadline=$((SECONDS + 90))
  while [ "$SECONDS" -lt "$health_deadline" ]; do
    if curl -fsS --connect-timeout 1 --max-time 2 \
      "http://127.0.0.1:$PORT/health" 2>/dev/null \
      | grep -Eq '"status"[[:space:]]*:[[:space:]]*"ok"'; then
      return 0
    fi
    if [ -n "$DAEMON_PID" ] && ! kill -0 "$DAEMON_PID" 2>/dev/null; then
      echo "v121-tui-qualification: daemon exited before health became ready" >&2
      return 1
    fi
    sleep 0.25
  done
  echo "v121-tui-qualification: health did not become ready within 90 seconds" >&2
  return 1
}

operator_attest() {
  prompt="$1"
  printf '%s [y/N] ' "$prompt" >/dev/tty
  IFS= read -r answer </dev/tty
  case "$answer" in
    y|Y|yes|YES) return 0 ;;
    *) echo "v121-tui-qualification: operator did not attest a required row" >&2; exit 1 ;;
  esac
}

run_attended() {
  [ -t 0 ] && [ -t 1 ] && [ -r /dev/tty ] && [ -w /dev/tty ] || {
    echo "v121-tui-qualification: --attended requires an interactive terminal" >&2
    exit 1
  }
  : "${V121_TUI_HOME:?set V121_TUI_HOME to a prepared disposable Allbert Home}"
  : "${V121_TUI_EVIDENCE_DIR:?set V121_TUI_EVIDENCE_DIR outside the disposable Home}"
  : "${V121_TUI_PROVIDER_PROFILE:?set V121_TUI_PROVIDER_PROFILE to the real configured profile}"
  [ "${V121_TUI_KEEP_TMP:-0}" != "1" ] || {
    echo "v121-tui-qualification: attended provider validation forbids retained private diagnostics" >&2
    exit 1
  }
  ATTENDED_HOME="$(cd -P -- "$V121_TUI_HOME" && pwd -P)"
  HOST_HOME_PHYSICAL="$(cd -P -- "${HOME:?}" && pwd -P)"
  TASK_TMP_ROOT="$(cd -P -- "${TMPDIR:-/tmp}" && pwd -P)"
  SYSTEM_TMP_ROOT="$(cd -P -- /tmp && pwd -P)"
  DEFAULT_HOME_RAW="$HOME/.allbert"
  if [ -d "$DEFAULT_HOME_RAW" ]; then
    DEFAULT_HOME="$(cd -P -- "$DEFAULT_HOME_RAW" && pwd -P)"
  else
    DEFAULT_HOME="$HOST_HOME_PHYSICAL/.allbert"
  fi
  case "$ATTENDED_HOME" in
    "$DEFAULT_HOME"|"$DEFAULT_HOME"/*)
      echo "v121-tui-qualification: attended validation refuses the default operator Home tree" >&2
      exit 1
      ;;
    /|"$HOST_HOME_PHYSICAL"|"$HOST_HOME_PHYSICAL"/*|"$TASK_TMP_ROOT"|"$SYSTEM_TMP_ROOT")
      echo "v121-tui-qualification: attended validation requires a bounded disposable Home" >&2
      exit 1
      ;;
  esac
  case "$ATTENDED_HOME" in
    "$TASK_TMP_ROOT"/*|"$SYSTEM_TMP_ROOT"/*) ;;
    *)
      echo "v121-tui-qualification: disposable Home must be physically under TMPDIR or /tmp" >&2
      exit 1
      ;;
  esac
  ATTENDED_EVIDENCE_DIR="$(validate_fresh_private_evidence_dir "$V121_TUI_EVIDENCE_DIR")"
  case "$ATTENDED_EVIDENCE_DIR" in
    "$ATTENDED_HOME"|"$ATTENDED_HOME"/*)
      echo "v121-tui-qualification: evidence directory must be outside the disposable Home" >&2
      exit 1
      ;;
    "$DEFAULT_HOME"|"$DEFAULT_HOME"/*|/|"$HOST_HOME_PHYSICAL"|"$HOST_HOME_PHYSICAL"/*|"$TASK_TMP_ROOT"|"$SYSTEM_TMP_ROOT")
      echo "v121-tui-qualification: evidence directory must be a bounded non-user-data directory" >&2
      exit 1
      ;;
  esac

  if [ "$MODE" = "source" ]; then
    export MIX_ENV="${V121_TUI_MIX_ENV:-dev}"
  fi

  mkdir -p "$WORK/child-tmp"
  BASE_ENV=(
    env -i
    "PATH=${PATH:?}"
    "HOME=${HOME:?}"
    "ALLBERT_HOME=$ATTENDED_HOME"
    "TMPDIR=$WORK/child-tmp"
    "TERM=${TERM:-xterm-256color}"
    "ALLBERT_TUI_LOG_LEVEL=none"
  )
  for env_name in SHELL LANG LC_ALL LC_CTYPE MIX_ENV SSL_CERT_FILE SSL_CERT_DIR; do
    env_value="${!env_name-}"
    if [ -n "$env_value" ]; then
      BASE_ENV+=("$env_name=$env_value")
    fi
  done
  PROVIDER_ENV=("${BASE_ENV[@]}")
  if [ -n "${ERL_AFLAGS:-}" ]; then
    TUI_ERL_AFLAGS="$ERL_AFLAGS +Bc"
  else
    TUI_ERL_AFLAGS="+Bc"
  fi
  TUI_ENV=("${BASE_ENV[@]}" "ERL_AFLAGS=$TUI_ERL_AFLAGS")
  for env_name in \
    DBUS_SESSION_BUS_ADDRESS XDG_RUNTIME_DIR ALLBERT_SETTINGS_MASTER_KEY \
    OPENAI_API_KEY ANTHROPIC_API_KEY OPENROUTER_API_KEY GOOGLE_API_KEY GEMINI_API_KEY; do
    env_value="${!env_name-}"
    if [ -n "$env_value" ]; then
      PROVIDER_ENV+=("$env_name=$env_value")
    fi
  done

  if [ "$MODE" = "source" ]; then
    : "${V121_EXPECTED_SHA:?set V121_EXPECTED_SHA to the exact pushed SHA}"
    [ "$SOURCE_SHA" = "$V121_EXPECTED_SHA" ] || {
      echo "v121-tui-qualification: HEAD does not match V121_EXPECTED_SHA" >&2
      exit 1
    }
    [ -z "$(git status --porcelain)" ] || {
      echo "v121-tui-qualification: attended source validation requires a clean tree" >&2
      exit 1
    }
    UPSTREAM_SHA="$(git rev-parse '@{upstream}' 2>/dev/null || true)"
    [ -n "$UPSTREAM_SHA" ] && [ "$SOURCE_SHA" = "$UPSTREAM_SHA" ] || {
      echo "v121-tui-qualification: HEAD is not the locally recorded pushed upstream SHA" >&2
      exit 1
    }
    run_bounded_child 120 "source migration" \
      "${PROVIDER_ENV[@]}" mix allbert.ecto.migrate --quiet
    run_bounded_child 120 "source model selection" \
      "${PROVIDER_ENV[@]}" mix allbert.model use \
      "$V121_TUI_PROVIDER_PROFILE" --enable-assist
    run_bounded_child 120 "source model-profile setting" \
      "${PROVIDER_ENV[@]}" mix allbert.settings set \
      intent.direct_answer_model_profile "$V121_TUI_PROVIDER_PROFILE"
    run_bounded_child 120 "source model-assist setting" \
      "${PROVIDER_ENV[@]}" mix allbert.settings set \
      intent.direct_answer_model_enabled true
    MODEL_LIST_FILE="$WORK/model-list-private.txt"
    run_bounded_child_to_file 120 "source model inventory" "$MODEL_LIST_FILE" \
      "${PROVIDER_ENV[@]}" mix allbert.model list
    MODEL_LIST="$(<"$MODEL_LIST_FILE")"
    printf '%s\n' "$MODEL_LIST" | grep -Fqx \
      "Active model profile: $V121_TUI_PROVIDER_PROFILE"
    printf '%s\n' "$MODEL_LIST" | grep -Fqx "Model-assisted intent: true"
    echo "v121-tui-qualification: real-provider preflight (redacted output is not retained)"
    run_bounded_child 180 "source real-provider preflight" \
      "${PROVIDER_ENV[@]}" mix allbert.model doctor "$V121_TUI_PROVIDER_PROFILE"
  else
    : "${V121_EXPECTED_SHA256:?set V121_EXPECTED_SHA256 to the exact archive digest}"
    : "${V121_EXPECTED_SOURCE_SHA:?set V121_EXPECTED_SOURCE_SHA from the immutable digest manifest}"
    [ "$ARTIFACT_SHA256" = "$V121_EXPECTED_SHA256" ] || {
      echo "v121-tui-qualification: archive digest does not match V121_EXPECTED_SHA256" >&2
      exit 1
    }
    case "$V121_EXPECTED_SOURCE_SHA" in
      *[!0-9a-f]*|'')
        echo "v121-tui-qualification: V121_EXPECTED_SOURCE_SHA must be a hexadecimal Git SHA" >&2
        exit 2
        ;;
    esac
    [ "${#V121_EXPECTED_SOURCE_SHA}" -eq 40 ] || {
      echo "v121-tui-qualification: V121_EXPECTED_SOURCE_SHA must contain 40 hex characters" >&2
      exit 2
    }
    run_bounded_child 120 "artifact model selection" \
      "${PROVIDER_ENV[@]}" "$TUI_BIN" admin models use \
      "$V121_TUI_PROVIDER_PROFILE" --enable-assist
    run_bounded_child 120 "artifact model-profile setting" \
      "${PROVIDER_ENV[@]}" "$TUI_BIN" admin settings set \
      intent.direct_answer_model_profile "$V121_TUI_PROVIDER_PROFILE"
    run_bounded_child 120 "artifact model-assist setting" \
      "${PROVIDER_ENV[@]}" "$TUI_BIN" admin settings set \
      intent.direct_answer_model_enabled true
    MODEL_LIST_FILE="$WORK/model-list-private.txt"
    run_bounded_child_to_file 120 "artifact model inventory" "$MODEL_LIST_FILE" \
      "${PROVIDER_ENV[@]}" "$TUI_BIN" admin models list
    MODEL_LIST="$(<"$MODEL_LIST_FILE")"
    printf '%s\n' "$MODEL_LIST" | grep -Fqx \
      "Active model profile: $V121_TUI_PROVIDER_PROFILE"
    printf '%s\n' "$MODEL_LIST" | grep -Fqx "Model-assisted intent: true"
    echo "v121-tui-qualification: real-provider preflight (redacted output is not retained)"
    run_bounded_child 180 "artifact real-provider preflight" \
      "${PROVIDER_ENV[@]}" "$TUI_BIN" admin models doctor "$V121_TUI_PROVIDER_PROFILE"
  fi
  operator_attest "Does the doctor show the selected real provider/model ready for an actual turn?"

  STTY_BEFORE="$(stty -g </dev/tty)"
  spawn_daemon_child "$WORK/daemon-private.log" \
    "${PROVIDER_ENV[@]}" PORT="$PORT" PHX_SERVER=1 ALLBERT_HOLD_WRITER_LOCK=1 \
    "$DAEMON_BIN" "${DAEMON_ARGS[@]}"
  wait_for_health

  cat >/dev/tty <<'CHECKLIST'

Mandatory single warm-client checklist (do not paste secrets):
  Send each line separately; do not paste the numeric labels.

  1. /status
     PASS: identity is local/default and daemon health is ready.
  2. Fetch https://example.com/ from the internet
     PASS: an external_network_request confirmation appears. Enter its exact
     ALLBERT:DENY:<id> command; it resolves denied and no fetched body,
     summary, or success result appears.
  3. Do these three tasks in parallel: write a detailed 1000-word explanation of OTP supervision; compare GenServer and Agent in 1000 words; explain supervision trees using a restaurant analogy in 1000 words
     PASS: kickoff promptly names exactly three children and returns the prompt
     before the children finish.
  4. Immediately after kickoff:
     change task 1 to explain OTP supervision as a hospital analogy in 1000 words
     PASS: only child 1 is steered; children 2 and 3 retain their tasks.
  5. While work is active: status?
     PASS: durable state describes this fan-out, not an unrelated action.
  6. Wait for one joined report. PASS: all three children are terminal, the
     parent joins once, and the report contains bounded results for every child;
     child 1 uses the hospital analogy.
  7. what is 2+2?
     PASS: the same warm client remains usable and the real provider answers 4.
  8. /quit
     PASS: normal detach; do not kill the client to finish this row.

The transcript stays on this terminal and is not written to release evidence.
CHECKLIST
  operator_attest "Is this checklist visible in another window/pane while the TUI owns the alternate screen?"

  set +e
  spawn_active_child_on_tty "${TUI_ENV[@]}" "$TUI_BIN" "${TUI_ARGS[@]}"
  wait "$ACTIVE_CHILD_PID"
  TUI_STATUS=$?
  ACTIVE_CHILD_PID=""
  set -e
  [ "$TUI_STATUS" -eq 0 ] || {
    echo "v121-tui-qualification: attended TUI exited $TUI_STATUS" >&2
    echo "Recovery after an uncatchable exit: stty sane; reset" >&2
    exit 1
  }

  STTY_AFTER="$(stty -g </dev/tty)"
  [ "$STTY_BEFORE" = "$STTY_AFTER" ] || {
    echo "v121-tui-qualification: terminal settings were not restored exactly" >&2
    echo "Run: stty sane" >&2
    echo "If the alternate screen/display remains damaged, run: reset" >&2
    exit 1
  }
  curl -fsS --connect-timeout 2 --max-time 5 \
    "http://127.0.0.1:$PORT/health" \
    | grep -Eq '"status"[[:space:]]*:[[:space:]]*"ok"' || {
    echo "v121-tui-qualification: daemon/Web health failed after TUI exit" >&2
    exit 1
  }

  operator_attest "Did /status show the expected identity and ready daemon?"
  operator_attest "Did exact-id DENY resolve the network confirmation with no result/effect?"
  operator_attest "Did exactly three children start and only child 1 accept the hospital steer?"
  operator_attest "Did status report that fan-out and did one complete joined report follow?"
  operator_attest "Did the independent 2+2 turn return 4 in the same warm client?"
  operator_attest "Did /quit restore a usable terminal with no visible corruption?"

  if ! terminate_pid "$DAEMON_PID"; then
    echo "v121-tui-qualification: attended daemon cleanup did not complete; PASS evidence withheld" >&2
    exit 1
  fi
  DAEMON_PID=""

  EVIDENCE_FILE="$ATTENDED_EVIDENCE_DIR/v121-tui-attended-${TARGET}-${SUBJECT#*:}.txt"
  if [ -e "$EVIDENCE_FILE" ] || [ -L "$EVIDENCE_FILE" ]; then
    echo "v121-tui-qualification: attended evidence already exists; choose a fresh evidence directory" >&2
    exit 1
  fi
  EVIDENCE_PATH_SHA256="$(sha256_text "$EVIDENCE_FILE")"
  HOME_PATH_SHA256="$(sha256_text "$ATTENDED_HOME")"
  PROVIDER_PROFILE_SHA256="$(sha256_text "$V121_TUI_PROVIDER_PROFILE")"
  if [ "$MODE" = "source" ]; then
    CANDIDATE_SHA="$SOURCE_SHA"
    EVIDENCE_ARTIFACT_SHA256="not_applicable"
  else
    CANDIDATE_SHA="$V121_EXPECTED_SOURCE_SHA"
    EVIDENCE_ARTIFACT_SHA256="$ARTIFACT_SHA256"
  fi
  PENDING_EVIDENCE_FINAL="$EVIDENCE_FILE"
  EVIDENCE_TMP="$(mktemp "$ATTENDED_EVIDENCE_DIR/.v121-tui-attended.XXXXXX")"
  PENDING_EVIDENCE_TMP="$EVIDENCE_TMP"
  {
    echo "schema=1"
    echo "kind=v121_tui_attended_qualification"
    echo "checklist_schema=v121_tui_attended_v1"
    echo "candidate_sha=$CANDIDATE_SHA"
    echo "target=$TARGET"
    echo "subject=$SUBJECT"
    echo "host_os=$(uname -s)"
    echo "host_arch=$(uname -m)"
    echo "surface=tui"
    echo "home_path_sha256=$HOME_PATH_SHA256"
    echo "provider_profile_sha256=$PROVIDER_PROFILE_SHA256"
    echo "artifact_sha256=$EVIDENCE_ARTIFACT_SHA256"
    echo "evidence_path_sha256=$EVIDENCE_PATH_SHA256"
    echo "expected_pass_clause=v121_tui_operator_attended_v1"
    echo "redacted_observation=operator_observed_all_named_rows_pass"
    echo "operator_attended=true"
    echo "real_provider_preflight=pass"
    echo "ordinary_prompt=pass"
    echo "confirmation_deny_no_effect=pass"
    echo "fanout_named_steering_join=pass"
    echo "independent_follow_up=pass"
    echo "normal_quit=pass"
    echo "terminal_exact_restore=pass"
    echo "post_tui_daemon_health=pass"
    echo "raw_transcript_retained=false"
  } >"$EVIDENCE_TMP"
  publish_no_clobber "$EVIDENCE_TMP" "$EVIDENCE_FILE"
  FINAL_SUCCESS_MESSAGE="v121-tui-qualification:attended PASS evidence=$EVIDENCE_FILE"
}

run_automated() {
  QUAL_HOME="$WORK/home"
  mkdir -p "$QUAL_HOME"
  if [ "$MODE" = "source" ]; then
    export MIX_ENV="${V121_TUI_MIX_ENV:-test}"
    export MIX_HOME="${MIX_HOME:-${HOME:?}/.mix}"
    [ -d "$MIX_HOME" ] || {
      echo "v121-tui-qualification: source mode requires an existing MIX_HOME with local tooling" >&2
      exit 1
    }
    run_bounded_child 120 "automated source migration" \
      env "ALLBERT_HOME=$QUAL_HOME" mix allbert.ecto.migrate --quiet
    if [ -n "$(git status --porcelain)" ]; then
      SUBJECT="$SUBJECT-dirty"
    fi
  fi

  if [ "$POSITIONAL_FV" -eq 1 ]; then
    EVIDENCE_FILE="$WORK/protocol-tty.json"
  else
    if [ -n "${V121_TUI_EVIDENCE_DIR:-}" ]; then
      EVIDENCE_DIR="$(validate_fresh_private_evidence_dir "$V121_TUI_EVIDENCE_DIR")"
    else
      EVIDENCE_ROOT="$(cd -P -- "${TMPDIR:-/tmp}" && pwd -P)"
      OWNED_EVIDENCE_DIR="$(mktemp -d "$EVIDENCE_ROOT/allbert-v121-tui-evidence.XXXXXX")"
      EVIDENCE_DIR="$(validate_fresh_private_evidence_dir "$OWNED_EVIDENCE_DIR")"
      OWNED_EVIDENCE_DIR="$EVIDENCE_DIR"
    fi
    case "$EVIDENCE_DIR" in
      "$QUAL_HOME"|"$QUAL_HOME"/*)
        echo "v121-tui-qualification: evidence directory must be outside the disposable Home" >&2
        exit 1
        ;;
    esac
    EVIDENCE_FILE="$EVIDENCE_DIR/v121-tui-pty-${SUBJECT#*:}.json"
  fi
  if [ -e "$EVIDENCE_FILE" ] || [ -L "$EVIDENCE_FILE" ]; then
    echo "v121-tui-qualification: evidence path is already occupied; use a fresh directory" >&2
    exit 1
  fi
  PENDING_EVIDENCE_FINAL="$EVIDENCE_FILE"

  PROMPT_REGEX="${V121_TUI_PROMPT_REGEX:-}"
  NO_DAEMON_REGEX="${V121_TUI_NO_DAEMON_REGEX:-}"
  OCCUPIED_REGEX="${V121_TUI_OCCUPIED_REGEX:-}"
  DAEMON_LOSS_REGEX="${V121_TUI_DAEMON_LOSS_REGEX:-}"
  [ -n "$PROMPT_REGEX" ] || PROMPT_REGEX='allbert(?::[^\r\n>]{1,64})?>[ ]?'
  [ -n "$NO_DAEMON_REGEX" ] || NO_DAEMON_REGEX='(?:allbert serve.{0,160}(?:start|repair|service)|(?:daemon|service).{0,160}allbert serve)'
  [ -n "$OCCUPIED_REGEX" ] || OCCUPIED_REGEX='(?:already.{0,48}attach|session.{0,48}already)'
  [ -n "$DAEMON_LOSS_REGEX" ] || DAEMON_LOSS_REGEX='(?:(?:daemon|connection).{0,80}(?:closed|lost|reset|unavailable)|socket.{0,48}closed)'

  PROVIDER_RECEIPT=""
  PYTHON_ARGS=(
    --mode "$MODE"
    --target "$TARGET"
    --home "$QUAL_HOME"
    --work "$WORK/pty-private"
    --evidence "$EVIDENCE_FILE"
    --subject "$SUBJECT"
    --port "$PORT"
    --daemon-bin "$DAEMON_BIN"
    --tui-bin "$TUI_BIN"
    --prompt-regex "$PROMPT_REGEX"
    --no-daemon-regex "$NO_DAEMON_REGEX"
    --occupied-regex "$OCCUPIED_REGEX"
    --daemon-loss-regex "$DAEMON_LOSS_REGEX"
  )
  for daemon_arg in "${DAEMON_ARGS[@]}"; do
    PYTHON_ARGS+=("--daemon-arg=$daemon_arg")
  done
  for tui_arg in "${TUI_ARGS[@]}"; do
    PYTHON_ARGS+=("--tui-arg=$tui_arg")
  done
  if [ -n "$RELEASE_ROOT" ]; then
    PYTHON_ARGS+=(--release-root "$RELEASE_ROOT")
  fi
  if [ "$POSITIONAL_FV" -eq 1 ] && [ "$TARGET" = "linux-x64" ]; then
    : "${ALLBERT_V121_PROVIDER_CONFIG:?linux-x64 requires ALLBERT_V121_PROVIDER_CONFIG}"
    : "${ALLBERT_V121_PROVIDER_MODEL:?linux-x64 requires ALLBERT_V121_PROVIDER_MODEL}"
    [ "${V121_TUI_KEEP_TMP:-0}" != "1" ] || {
      echo "v121-tui-qualification: provider FV forbids retained private diagnostics" >&2
      exit 1
    }
    PROVIDER_RECEIPT="$WORK/provider-receipt.json"
    PYTHON_ARGS+=(
      --provider-required
      --provider-receipt "$PROVIDER_RECEIPT"
    )
  fi

  set +e
  spawn_active_child python3 "$PYTHON_HELPER" "${PYTHON_ARGS[@]}"
  wait "$ACTIVE_CHILD_PID"
  PYTHON_STATUS=$?
  ACTIVE_CHILD_PID=""
  set -e
  [ "$PYTHON_STATUS" -eq 0 ] || return "$PYTHON_STATUS"

  if [ "$POSITIONAL_FV" -eq 1 ]; then
    python3 - "$EVIDENCE_FILE" "$TARGET" <<'PY'
import json
import pathlib
import sys

path, target = sys.argv[1:]
payload = json.loads(pathlib.Path(path).read_text())
expected_keys = {
    "schema", "kind", "created_at", "mode", "target", "subject",
    "raw_transcript_retained", "cases",
}
expected_cases = {
    "no-daemon-no-writer",
    "attach-degraded-web-available",
    "daemon-health-ready",
    "occupied-session-health",
    "resize-terminal-restore",
    "pressure-bounded-health",
    "ctrl-c-terminal-restore",
    "eof-terminal-restore",
    "sigterm-terminal-restore",
    "sighup-terminal-restore",
    "daemon-loss-restart-health",
    "release-root-immutable",
}
if target == "linux-x64":
    expected_cases.add("configured-provider-turn")
cases = payload.get("cases")
valid = (
    set(payload) == expected_keys
    and payload.get("schema") == 1
    and payload.get("kind") == "v121_tui_pty_qualification"
    and payload.get("mode") == "artifact"
    and payload.get("target") == target
    and payload.get("subject") == f"target:{target}"
    and payload.get("raw_transcript_retained") is False
    and isinstance(cases, list)
    and all(
        isinstance(case, dict)
        and set(case) == {"id", "status"}
        and case["status"] == "pass"
        for case in cases
    )
    and len(cases) == len(expected_cases)
    and {case["id"] for case in cases} == expected_cases
)
if not valid:
    raise SystemExit("v121-tui-qualification: invalid protocol/TTY evidence schema")
PY
    PROTOCOL_SHA256="$(sha256_file "$EVIDENCE_FILE")"
    PROVIDER_STATUS="not_required"
    PROVIDER_SHA256=""
    if [ "$TARGET" = "linux-x64" ]; then
      [ -f "$PROVIDER_RECEIPT" ] || {
        echo "v121-tui-qualification: provider receipt was not produced" >&2
        exit 1
      }
      python3 - "$PROVIDER_RECEIPT" "$TARGET" <<'PY'
import json
import pathlib
import re
import sys

path, target = sys.argv[1:]
payload = json.loads(pathlib.Path(path).read_text())
expected_keys = {
    "schema", "kind", "target", "subject", "challenge_sha256",
    "provider_profile_sha256", "model_sha256", "doctor", "turn_completion",
    "status", "raw_transcript_retained",
}
digest = re.compile(r"^[0-9a-f]{64}$")
valid = (
    set(payload) == expected_keys
    and payload.get("schema") == 1
    and payload.get("kind") == "v121_tui_provider_receipt"
    and payload.get("target") == target
    and payload.get("subject") == f"target:{target}"
    and payload.get("doctor") == "pass"
    and payload.get("turn_completion") == "pass"
    and payload.get("status") == "pass"
    and payload.get("raw_transcript_retained") is False
    and all(digest.fullmatch(payload.get(key, "")) for key in (
        "challenge_sha256", "provider_profile_sha256", "model_sha256"
    ))
)
if not valid:
    raise SystemExit("v121-tui-qualification: invalid provider evidence schema")
PY
      PROVIDER_STATUS="passed"
      PROVIDER_SHA256="$(sha256_file "$PROVIDER_RECEIPT")"
    fi
    PENDING_EVIDENCE_FINAL=""
    FV_PARENT="$(dirname "$FV_OUTPUT")"
    [ -d "$FV_PARENT" ] && [ ! -L "$FV_PARENT" ] || {
      echo "v121-tui-qualification: FV output parent must be an existing directory" >&2
      exit 1
    }
    if [ -e "$FV_OUTPUT" ] || [ -L "$FV_OUTPUT" ]; then
      echo "v121-tui-qualification: FV output already exists" >&2
      exit 1
    fi
    PENDING_EVIDENCE_FINAL="$FV_OUTPUT"
    FV_TMP="$(mktemp "$FV_PARENT/.v121-tui-fv.XXXXXX")"
    PENDING_EVIDENCE_TMP="$FV_TMP"
    python3 - "$FV_TMP" "$TARGET" "$PROVIDER_STATUS" "$PROTOCOL_SHA256" "$PROVIDER_SHA256" <<'PY'
import json
import pathlib
import sys

output, target, provider, protocol_digest, provider_digest = sys.argv[1:]
payload = {
    "schema_version": 1,
    "target": target,
    "protocol_tty": "passed",
    "provider": provider,
    "evidence": {
        "protocol_tty_sha256": protocol_digest,
        "provider_receipt_sha256": provider_digest or None,
    },
}
pathlib.Path(output).write_text(json.dumps(payload, sort_keys=True, indent=2) + "\n")
PY
    publish_no_clobber "$FV_TMP" "$FV_OUTPUT"
    FINAL_SUCCESS_MESSAGE="v121-tui-qualification:fv PASS target=$TARGET output=$FV_OUTPUT"
  else
    FINAL_SUCCESS_MESSAGE="v121-tui-qualification:automated PASS evidence=$EVIDENCE_FILE"
  fi
}

if [ "$ATTENDED" -eq 1 ]; then
  run_attended
else
  run_automated
fi
finalize_success
