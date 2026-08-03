#!/usr/bin/env bash
# ARCHIVED v1.3 attended-validation script. Extracted from
# docs/plans/v1.3-request-flow.md so the operator invoked one line
# instead of pasting hundreds. The v1.3 FOV run it belongs to completed
# and passed on 2026-08-02; this file is provenance, not a live fixture.
#
# It is no longer executed by any test and no longer verified against the
# current schema, renderer, or CLI, so treat it as a record of what was
# run rather than as something that still runs. Release-specific
# validation scripts are not permanent repository fixtures.
if test -n "${FOV_DAEMON_PID:-}" && kill -0 "$FOV_DAEMON_PID" 2>/dev/null; then
  kill "$FOV_DAEMON_PID" 2>/dev/null || true
fi
if test -n "${FOV_DAEMON_PID:-}"; then
  wait "$FOV_DAEMON_PID" 2>/dev/null || true
fi
FOV_DAEMON_PID=
trap - EXIT

fov_8_close_validate() {
  FOV_MAIN_DB="$ALLBERT_HOME/db/allbert.sqlite3"
  FOV_SEARCH_DB="$ALLBERT_HOME/projections/search/current.sqlite3"
  test -f "$FOV_MAIN_DB" || return 1
  test -f "$FOV_SEARCH_DB" || return 1
  test -f "$FOV_DAEMON_LOG" || return 1

  if (exec 3<>/dev/tcp/127.0.0.1/4137) 2>/dev/null; then
    return 1
  fi
  for FOV_SQLITE_SIDECAR in \
    "$FOV_MAIN_DB-wal" "$FOV_MAIN_DB-shm" "$FOV_MAIN_DB-journal" \
    "$FOV_SEARCH_DB-wal" "$FOV_SEARCH_DB-shm" "$FOV_SEARCH_DB-journal"
  do
    test ! -e "$FOV_SQLITE_SIDECAR" || return 1
  done

  sqlite3 -readonly -noheader "file:$FOV_MAIN_DB?immutable=1" \
    'PRAGMA integrity_check;' \
    > "$FOV_ROOT/main-db-integrity-final.txt" || return 1
  sqlite3 -readonly -noheader "file:$FOV_SEARCH_DB?immutable=1" \
    'PRAGMA integrity_check;' \
    > "$FOV_ROOT/search-db-integrity-final.txt" || return 1
  sqlite3 -readonly -noheader "file:$FOV_MAIN_DB?immutable=1" \
    'PRAGMA foreign_key_check;' \
    > "$FOV_ROOT/main-db-foreign-keys-final.txt" || return 1
  sqlite3 -readonly -noheader "file:$FOV_SEARCH_DB?immutable=1" \
    'PRAGMA foreign_key_check;' \
    > "$FOV_ROOT/search-db-foreign-keys-final.txt" || return 1

  test ! -s "$FOV_ROOT/main-db-foreign-keys-final.txt" || return 1
  test ! -s "$FOV_ROOT/search-db-foreign-keys-final.txt" || return 1
  printf '0|0\n' > "$FOV_ROOT/db-foreign-key-counts-final.txt" || return 1

  awk '
  /^\[debug\]/ {debug++}
  /^\[(warning|error)\]/ {bad++}
  /^=(CRASH|SUPERVISOR|ERROR) REPORT====/ {bad++}
  /^\*\* \(/ {bad++}
  END {printf "%d|%d\n",debug+0,bad+0}
  ' "$FOV_DAEMON_LOG" \
    > "$FOV_ROOT/daemon-log-level-counts.txt" || return 1

  if grep -Fq -f "$FOV_ROOT/settings-master-key" "$FOV_DAEMON_LOG"; then
    printf '1\n' > "$FOV_ROOT/daemon-master-key-leak.txt" || return 1
  else
    printf '0\n' > "$FOV_ROOT/daemon-master-key-leak.txt" || return 1
  fi

  if test -d "$ALLBERT_HOME/memory/traces"; then
    FOV_TRACE_FILE_COUNT="$(
      find "$ALLBERT_HOME/memory/traces" -type f -name '*.md' -print |
        wc -l | tr -d '[:space:]'
    )" || return 1
  else
    FOV_TRACE_FILE_COUNT=0
  fi
  if test -d "$ALLBERT_HOME/settings/audit"; then
    FOV_SETTINGS_AUDIT_COUNT="$(
      find "$ALLBERT_HOME/settings/audit" -type f -name '*.md' -print |
        wc -l | tr -d '[:space:]'
    )" || return 1
  else
    FOV_SETTINGS_AUDIT_COUNT=0
  fi
  printf '%s|%s\n' "$FOV_TRACE_FILE_COUNT" "$FOV_SETTINGS_AUDIT_COUNT" \
    > "$FOV_ROOT/home-private-artifact-counts.txt" || return 1

  cat "$FOV_ROOT/main-db-integrity-final.txt" || return 1
  cat "$FOV_ROOT/search-db-integrity-final.txt" || return 1
  cat "$FOV_ROOT/db-foreign-key-counts-final.txt" || return 1
  cat "$FOV_ROOT/daemon-log-level-counts.txt" || return 1
  cat "$FOV_ROOT/daemon-master-key-leak.txt" || return 1
  cat "$FOV_ROOT/home-private-artifact-counts.txt" || return 1

  test "$(cat "$FOV_ROOT/main-db-integrity-final.txt")" = 'ok' || return 1
  test "$(cat "$FOV_ROOT/search-db-integrity-final.txt")" = 'ok' || return 1
  test "$(cat "$FOV_ROOT/db-foreign-key-counts-final.txt")" = '0|0' || return 1
  test "$(cat "$FOV_ROOT/daemon-log-level-counts.txt")" = '0|0' || return 1
  test "$(cat "$FOV_ROOT/daemon-master-key-leak.txt")" = '0' || return 1
  test "$(cat "$FOV_ROOT/home-private-artifact-counts.txt")" = '0|1' || return 1

  FOV_SHA256_MANIFEST="$FOV_ROOT/evidence-sha256.txt"
  (
    cd "$FOV_ROOT" || exit 1
    shasum -a 256 \
      source-sha.txt \
      doctor.txt \
      direct-answer.txt \
      fanout-manager.txt \
      fanout-synthesis.txt \
      fanout-call-budget.txt \
      fanout-token-budget.txt \
      model-doctor.txt \
      home/log/source-daemon.log \
      home/db/allbert.sqlite3 \
      home/projections/search/current.sqlite3 \
      main-db-integrity.txt \
      search-db-integrity.txt \
      main-db-foreign-keys.txt \
      search-db-foreign-keys.txt \
      db-foreign-key-counts.txt \
      durable-fanout-topology.txt \
      durable-budget-types.txt \
      worker-quality-receipts.txt \
      durable-report-state.txt \
      manager-admission.txt \
      report-selection.txt \
      durable-report-body-binding.txt \
      durable-synthesis-binding.txt \
      main-db-integrity-final.txt \
      search-db-integrity-final.txt \
      main-db-foreign-keys-final.txt \
      search-db-foreign-keys-final.txt \
      db-foreign-key-counts-final.txt \
      daemon-log-level-counts.txt \
      daemon-master-key-leak.txt \
      home-private-artifact-counts.txt
  ) > "$FOV_SHA256_MANIFEST" || return 1
  chmod 600 "$FOV_SHA256_MANIFEST" || return 1
  (
    cd "$FOV_ROOT" || exit 1
    shasum -a 256 -c evidence-sha256.txt
  ) > "$FOV_ROOT/evidence-sha256-check.txt" 2>&1 || return 1
  chmod 600 "$FOV_ROOT/evidence-sha256-check.txt" || return 1
  chmod -R go-rwx "$FOV_ROOT" || return 1
}

if fov_8_close_validate; then
  FOV_CLOSE_RESULT=pass
else
  FOV_CLOSE_RESULT=fail
fi
unset -f fov_8_close_validate
unset ALLBERT_SETTINGS_MASTER_KEY ALLBERT_HOME
echo "FOV-8 retained evidence root: $FOV_ROOT"

if test "$FOV_CLOSE_RESULT" = pass; then
  echo "FOV-8 SHA-256 manifest: $FOV_SHA256_MANIFEST"
  echo 'PASS FOV-8: focused fan-out qualification is closed; start full validation at SV-0 with a fresh Home'
else
  echo 'FAIL FOV-8: retained databases, daemon log, or port did not close cleanly'
fi
