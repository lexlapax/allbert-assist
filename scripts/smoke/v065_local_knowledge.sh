#!/usr/bin/env bash
# v0.65 M7 — local-knowledge product acceptance script.
#
# The exact fresh-home path v0.66 validates: connect a notes root, search a note,
# review a memory candidate, and confirm recall eligibility. The deterministic,
# model-free core (notes-root connect + memory review round-trip) runs as hard
# `smoke:<id>` checks against a throwaway ALLBERT_HOME using the checkout Mix tasks
# (`mix allbert.notes` / `mix allbert.memory`, the same dispatch the packaged
# `allbert admin notes|memory` uses). The model-dependent chat + recall steps are
# printed as the operator checklist v0.66 runs against the packaged binary with a
# model configured.
#
# Usage: scripts/smoke/v065_local_knowledge.sh
# Exits non-zero on the first failed check.
set -euo pipefail

pass() { echo "smoke:$1 pass ${2:-}"; }
fail() { echo "smoke:$1 FAIL ${2:-}" >&2; exit 1; }

WORK="$(mktemp -d)"
export ALLBERT_HOME="$WORK/home"
NOTES_ROOT="$ALLBERT_HOME/launch-notes"
mkdir -p "$NOTES_ROOT"
printf '# Onboarding\n\nBring the local knowledge checklist.\n' > "$NOTES_ROOT/onboarding.md"
trap 'rm -rf "$WORK"' EXIT

echo "smoke: v0.65 local-knowledge acceptance (home=$ALLBERT_HOME)"

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
      input_signal_id: "v065-smoke"
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
      input_signal_id: "v065-smoke"
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

echo "smoke: deterministic local-knowledge core PASSED"
echo
cat <<'CHECKLIST'
Operator checklist for the v0.66 packaged validation (needs a configured model):
  1. Start the packaged service; open the browser workspace.
  2. Onboarding -> "Connect a notes folder" (or `allbert admin notes set-root PATH`).
  3. Open the Notes destination; ask "find notes about onboarding" -> grounded answer.
  4. Ask Allbert to write a note; approve the confirmation; verify the file appears.
  5. Ask "remember this preference after review: prefer concise answers".
  6. Open the Memory destination; Keep the candidate.
  7. In a later chat, confirm the kept preference influences the answer.
  8. Run `mix allbert.test release.v065`.
CHECKLIST
