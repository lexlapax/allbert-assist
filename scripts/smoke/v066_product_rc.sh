#!/usr/bin/env bash
# v0.66 M1 — Product RC & No-Docs Validation acceptance script.
#
# Two-layer verification (v0.66-plan Locked Decision 1). This script owns the
# deterministic, model-free CORE of the product-RC path — the parts that can be
# proved in a checkout against a throwaway ALLBERT_HOME without a packaged binary,
# a running service, a browser, a model, or a second host: the onboarding state
# machine reports a fresh home, and the launch-critical local files/notes/memory
# loop holds (connect a notes root, fail closed on a bad root, search/read a note
# through the registered action seam, seed + review-keep a memory candidate). Each
# check prints `smoke:<id>`; the script exits non-zero on the first failure.
#
# The install/serve/browser/model/cross-platform/advanced-surface/export-import/
# uninstall steps CANNOT be proved here (no packaged binary / service / network /
# second host). They are printed as the operator checklist run against the packaged
# binary and recorded in docs/validation/v0.66/ as operator-attested evidence.
#
# Usage: scripts/smoke/v066_product_rc.sh
set -euo pipefail

pass() { echo "smoke:$1 pass ${2:-}"; }
fail() { echo "smoke:$1 FAIL ${2:-}" >&2; exit 1; }

WORK="$(mktemp -d)"
export ALLBERT_HOME="$WORK/home"
NOTES_ROOT="$ALLBERT_HOME/launch-notes"
mkdir -p "$NOTES_ROOT"
printf '# Onboarding\n\nBring the local knowledge checklist.\n' > "$NOTES_ROOT/onboarding.md"
trap 'rm -rf "$WORK"' EXIT

echo "smoke: v0.66 product-RC deterministic core (home=$ALLBERT_HOME)"

# 0. Onboarding state machine: a fresh home is pre-onboarding, never product-ready.
#    Booting the app creates the db (home dir + schema exist), so a clean install
#    resolves to :onboarding_incomplete (or :home_missing before first boot) — the
#    state the guided wizard runs against, never :product_ready without onboarding.
mix run -e '
  state = AllbertAssist.CLI.FirstRun.detect([])
  unless state in [:home_missing, :onboarding_incomplete] do
    raise("fresh home resolved #{inspect(state)}, expected a pre-onboarding state")
  end
' >/dev/null 2>&1 || fail onboard-state-fresh "fresh home did not resolve a pre-onboarding state"
pass onboard-state-fresh

# 1. Connect a notes root (config-free), and verify it persisted.
mix allbert.notes set-root "$NOTES_ROOT" >/dev/null 2>&1 || fail connect-root "set-root failed"
mix allbert.notes show 2>/dev/null | grep -qF "$NOTES_ROOT" || fail connect-root-persist "show did not report the root"
pass connect-root "$NOTES_ROOT"

# 2. Fail-closed on a non-directory path (no silent broken root).
if mix allbert.notes set-root "$WORK/does-not-exist" >/dev/null 2>&1; then
  fail connect-root-failclosed "set-root accepted a missing directory"
fi
pass connect-root-failclosed

# 3. Search/read find the seeded note through the registered action seam.
mix run -e '
  context = %{
    active_app: :notes_files,
    request: %{
      active_app: :notes_files,
      operator_id: "local",
      channel: :cli,
      input_signal_id: "v066-smoke"
    }
  }
  {:ok, response} = AllbertAssist.Actions.Runner.run("search_notes", %{query: "onboarding", limit: 10}, context)
  found? = response.status == :completed and Enum.any?(response.notes, &(Map.get(&1, :relative_path) == "onboarding.md"))
  unless found?, do: raise("search_notes did not return onboarding.md")
' >/dev/null 2>&1 || fail notes-search "search_notes did not find the seeded note"
pass notes-search

mix run -e '
  context = %{
    active_app: :notes_files,
    request: %{
      active_app: :notes_files,
      operator_id: "local",
      channel: :cli,
      input_signal_id: "v066-smoke"
    }
  }
  {:ok, response} = AllbertAssist.Actions.Runner.run("read_note", %{path: "onboarding.md"}, context)
  read? = response.status == :completed and response.note.body =~ "Bring the local knowledge checklist" and response.resource_refs != []
  unless read?, do: raise("read_note did not read onboarding.md with resource refs")
' >/dev/null 2>&1 || fail notes-read "read_note did not read the seeded note"
pass notes-read

# 4. Fresh home: no memory candidates yet.
mix allbert.memory status 2>/dev/null | grep -qE "unreviewed=0" || fail memory-status-fresh "expected unreviewed=0"
pass memory-status-fresh

# 5. Seed one unreviewed candidate (stands in for something Allbert learned in chat).
mix run -e '
  AllbertAssist.Memory.append(%{
    category: :preferences,
    body: "prefer concise answers",
    actor: "local",
    agent: "acceptance",
    channel: :cli,
    source_signal_id: "acc"
  })
' >/dev/null 2>&1 || fail memory-seed "could not seed a candidate"
mix allbert.memory status 2>/dev/null | grep -qE "unreviewed=1" || fail memory-status-candidate "expected unreviewed=1"
pass memory-candidate

# 6. Review -> keep: the candidate becomes recallable, nothing auto-promoted.
CAND_PATH="$(mix allbert.memory list --status unreviewed 2>/dev/null | grep -F "prefer concise answers" | awk '{print $NF}' | head -1)"
[ -n "$CAND_PATH" ] || fail memory-list "candidate path not found in list"
mix allbert.memory review "$CAND_PATH" --status kept --note "operator accepted" >/dev/null 2>&1 || fail memory-review "review keep failed"
mix allbert.memory status 2>/dev/null | grep -qE "kept=1" || fail memory-kept "expected kept=1 after review"
pass memory-review-keep "$CAND_PATH"

echo "smoke: v0.66 deterministic product-RC core PASSED"
echo
cat <<'CHECKLIST'
Operator checklist for the v0.66 packaged validation (attested layer — needs a
packaged binary, a running service, a browser, a configured model, and where noted
a second host). Record each with redacted evidence in docs/validation/v0.66/:

  Install & serve (M1/M2 [smoke]/[host]):
   1. Install Allbert from the packaged path on a clean host (no Elixir/OTP):
      macOS/Homebrew `brew install ...`, Linux `curl ... | sh`, Windows/WSL2 manual.
   2. Start the persistent service; `curl -fsS http://localhost:4000/health` green;
      `allbert admin health` reports runtime/web/channels healthy.

  Onboard & first chat (M2/M7 [browser]/[model]):
   3. Complete web QuickStart on the consumer-default path: guided local-runtime
      setup if needed, one-click curated-local-model download (no model CLI, no key).
   4. Ask a first useful question and confirm a grounded answer (first value).
   5. Run the natural-prompt routing set; confirm no mis-route to a disabled/demo
      capability (StockSage/demo intents must not lead the default first run).

  Local knowledge (M5 [model]):
   6. Connect a notes folder; ask "find notes about onboarding" -> grounded answer;
      ask Allbert to write a note, approve the confirmation, verify the file appears.
   7. Keep a memory candidate; in a later chat confirm the kept preference influences
      the answer (:kept-only recall).

  Inspect & advanced surfaces (M3/M4/M6 [browser]/[smoke]/[model]):
   8. Browser-smoke /, /workspace, /jobs, /objectives, onboarding, settings/model,
      workspace:notes, workspace:memory, operator panels (no console errors).
   9. Grouped CLI/TUI admin reads with no raw `mix` (security status, models list).
  10. Exercise every advanced-surface class (Locked Decision 6): browser research,
      every configured channel, MCP/OpenAI-compatible/ACP, Plan/Build approval,
      export/import. Record any unconfigured class as blocking unless scoped out.

  Portability & teardown (M9 [host]/[smoke]):
  11. Export/import or upgrade an Allbert Home; verify behavior and redaction.
  12. Uninstall service/binary; verify Home preservation unless removal is requested.

  Gates (M8/M10/M11 [gate]):
  13. Run `mix allbert.test release.v066` (GREEN) and reconcile evidence.
CHECKLIST
