#!/usr/bin/env bash
# v1.2.1 M0.b3 — thin-TUI PTY qualification.
#
# Automated source row:
#   scripts/smoke/v121_tui_qualification.sh --source
# Release-stage exact-artifact row (primary CI contract):
#   scripts/smoke/v121_tui_qualification.sh RELEASE_ROOT TARGET OUTPUT_JSON
# Standalone exact-archive row:
#   scripts/smoke/v121_tui_qualification.sh --artifact /path/allbert-v1.2.1-TARGET.tar.gz
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
PYTHON_HELPER="$SCRIPT_DIR/v121_tui_pty.py"

MODE=""
ARTIFACT=""
POSITIONAL_FV=0
RELEASE_ROOT=""
TARGET=""
FV_OUTPUT=""

usage() {
  cat <<'USAGE'
Usage:
  v121_tui_qualification.sh RELEASE_ROOT TARGET OUTPUT_JSON
  v121_tui_qualification.sh --source
  v121_tui_qualification.sh --artifact ARCHIVE

Automated rows use a new disposable Allbert Home and retain only a content-free
PASS manifest.

Optional bounded controls:
  V121_TUI_EVIDENCE_DIR, V121_TUI_PORT, V121_TUI_PROMPT_REGEX,
  V121_TUI_NO_DAEMON_REGEX,
  V121_TUI_OCCUPIED_REGEX, V121_TUI_DAEMON_LOSS_REGEX,
  V121_TUI_KEEP_TMP=1, V121_TUI_MIX_ENV (source row; default test).
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
[ -f "$PYTHON_HELPER" ] || {
  echo "v121-tui-qualification: missing helper $PYTHON_HELPER" >&2
  exit 1
}

umask 077
# Keep the disposable Home's resolved path below the Unix-domain socket limit.
# A deep platform TMPDIR makes the product correctly choose its hashed short-path
# fallback, which would cause the bind-failure fixture to obstruct the wrong path.
WORK="$(mktemp -d /tmp/allbert-v121-tui.XXXXXX)"
ACTIVE_CHILD_PID=""
PENDING_EVIDENCE_TMP=""
PENDING_EVIDENCE_FINAL=""
PENDING_EVIDENCE_ID=""
OWNED_EVIDENCE_DIR=""
CLEANING_UP=0
FINAL_SUCCESS_MESSAGE=""
ACQUIRING_CHILD=0
DEFERRED_SIGNAL_STATUS=0

evidence_identity() {
  python3 - "$1" <<'PY'
import os
import stat
import sys

try:
    metadata = os.lstat(sys.argv[1])
except OSError:
    raise SystemExit(1)
if not stat.S_ISREG(metadata.st_mode):
    raise SystemExit(1)
print(f"{metadata.st_dev}:{metadata.st_ino}")
PY
}

pending_evidence_is_owned() {
  local identity=""
  [ -n "$PENDING_EVIDENCE_FINAL" ] && [ -n "$PENDING_EVIDENCE_ID" ] || return 1
  identity="$(evidence_identity "$PENDING_EVIDENCE_FINAL" 2>/dev/null)" || return 1
  [ "$identity" = "$PENDING_EVIDENCE_ID" ]
}

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
  if [ "$cleanup_mode" = "success" ] || [ "${V121_TUI_KEEP_TMP:-0}" != "1" ]; then
    rm -rf -- "$WORK" || cleanup_failed=1
    if [ -e "$WORK" ] || [ -L "$WORK" ]; then
      cleanup_failed=1
    fi
  else
    echo "v121-tui-qualification: private diagnostics retained at $WORK" >&2
  fi

  if [ "$cleanup_mode" = "success" ] && [ "$cleanup_failed" -eq 0 ] && [ -n "$PENDING_EVIDENCE_TMP" ]; then
    rm -f -- "$PENDING_EVIDENCE_TMP" || cleanup_failed=1
    if [ -e "$PENDING_EVIDENCE_TMP" ] || [ -L "$PENDING_EVIDENCE_TMP" ]; then
      cleanup_failed=1
    else
      PENDING_EVIDENCE_TMP=""
    fi
  fi

  if [ "$cleanup_mode" != "success" ] || [ "$cleanup_failed" -ne 0 ]; then
    if [ -n "$PENDING_EVIDENCE_FINAL" ]; then
      if pending_evidence_is_owned; then
        rm -f -- "$PENDING_EVIDENCE_FINAL" || cleanup_failed=1
        if pending_evidence_is_owned; then
          echo "v121-tui-qualification: invalid evidence could not be rolled back: $PENDING_EVIDENCE_FINAL" >&2
          cleanup_failed=1
        fi
      elif [ -n "$PENDING_EVIDENCE_ID" ] && { [ -e "$PENDING_EVIDENCE_FINAL" ] || [ -L "$PENDING_EVIDENCE_FINAL" ]; }; then
        echo "v121-tui-qualification: evidence path changed ownership; left untouched: $PENDING_EVIDENCE_FINAL" >&2
        cleanup_failed=1
      fi
      PENDING_EVIDENCE_FINAL=""
      PENDING_EVIDENCE_ID=""
    fi
    if [ -n "$PENDING_EVIDENCE_TMP" ]; then
      rm -f -- "$PENDING_EVIDENCE_TMP" || cleanup_failed=1
      if [ -e "$PENDING_EVIDENCE_TMP" ] || [ -L "$PENDING_EVIDENCE_TMP" ]; then
        cleanup_failed=1
      fi
      PENDING_EVIDENCE_TMP=""
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
    PENDING_EVIDENCE_ID=""
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
  if [ -z "$PENDING_EVIDENCE_FINAL" ] || ! pending_evidence_is_owned; then
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
  local source_path="$1"
  local destination_path="$2"
  local source_identity=""
  local destination_identity=""
  source_identity="$(evidence_identity "$source_path")" || {
    echo "v121-tui-qualification: staged evidence is not a regular file" >&2
    return 1
  }
  PENDING_EVIDENCE_FINAL="$destination_path"
  PENDING_EVIDENCE_ID="$source_identity"
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
PY
  then
    destination_identity="$(evidence_identity "$destination_path")" || {
      echo "v121-tui-qualification: published evidence is not a regular file" >&2
      return 1
    }
    [ "$source_identity" = "$destination_identity" ] || {
      echo "v121-tui-qualification: published evidence identity changed" >&2
      return 1
    }
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
    PYTHON_EVIDENCE_FILE="$EVIDENCE_FILE"
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
    PYTHON_EVIDENCE_FILE="$WORK/protocol-tty-staging.json"
  fi
  if [ -e "$EVIDENCE_FILE" ] || [ -L "$EVIDENCE_FILE" ]; then
    echo "v121-tui-qualification: evidence path is already occupied; use a fresh directory" >&2
    exit 1
  fi
  if [ -e "$PYTHON_EVIDENCE_FILE" ] || [ -L "$PYTHON_EVIDENCE_FILE" ]; then
    echo "v121-tui-qualification: evidence staging path is already occupied; use a fresh directory" >&2
    exit 1
  fi

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
    --evidence "$PYTHON_EVIDENCE_FILE"
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
    PENDING_EVIDENCE_ID=""
    FV_PARENT="$(dirname "$FV_OUTPUT")"
    [ -d "$FV_PARENT" ] && [ ! -L "$FV_PARENT" ] || {
      echo "v121-tui-qualification: FV output parent must be an existing directory" >&2
      exit 1
    }
    if [ -e "$FV_OUTPUT" ] || [ -L "$FV_OUTPUT" ]; then
      echo "v121-tui-qualification: FV output already exists" >&2
      exit 1
    fi
    PENDING_EVIDENCE_TMP="$(mktemp "$FV_PARENT/.v121-tui-fv.XXXXXX")"
    FV_TMP="$PENDING_EVIDENCE_TMP"
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
    PENDING_EVIDENCE_TMP="$(mktemp "$EVIDENCE_DIR/.v121-tui-pty.XXXXXX")"
    EVIDENCE_TMP="$PENDING_EVIDENCE_TMP"
    cp "$PYTHON_EVIDENCE_FILE" "$EVIDENCE_TMP"
    chmod 600 "$EVIDENCE_TMP"
    publish_no_clobber "$EVIDENCE_TMP" "$EVIDENCE_FILE"
    FINAL_SUCCESS_MESSAGE="v121-tui-qualification:automated PASS evidence=$EVIDENCE_FILE"
  fi
}

run_automated
finalize_success
