# Local Knowledge: Files, Notes, And Reviewed Memory

The v0.65 launch path. After first chat, the primary useful workflow is local
knowledge: point Allbert at a folder of your notes, ask about them, confirm a safe
write, decide what Allbert may remember, and have that reviewed memory improve a later
answer. Nothing here grants new authority — it makes the existing notes/files and memory
review surfaces obvious to use.

Design + decisions: `docs/design/local-knowledge-path.md`, `docs/plans/v0.65-plan.md`,
and the ADR 0077 v0.65 amendment. Memory internals: `docs/operator/active-memory.md`.

## The loop

1. **Connect a notes folder** (config-free).
2. **Search / read** a note.
3. **Confirm a write** (`write_note` is confirmation-gated).
4. **Review memory** — keep, reject, or delete candidates.
5. **Recall later** — a kept memory improves a later answer.

## 1. Connect a notes folder

Set the notes root without hand-editing config, from any of:

- **Onboarding** — the "Connect a notes folder" affordance on the first-chat step
  (both QuickStart and Advanced reach it).
- **CLI** — `allbert admin notes set-root PATH` (the `PATH` must be an existing
  directory; it fails closed otherwise). `allbert admin notes show` prints the current
  root.
- **Web** — the `workspace:notes` destination and Settings Central.

The root is the Settings Central key `apps.notes_files.notes_root` (default
`<ALLBERT_HOME>/notes`). The generic `allbert admin settings set
apps.notes_files.notes_root PATH` still works as a low-level fallback, but the affordances
above are the product path.

## 2. Search / read notes

Open the **Notes** workspace destination (`workspace:notes`) from the sidebar, or ask in
chat ("find notes about onboarding", "summarize this note"). The panel searches and reads
through the registered `search_notes` / `read_note` actions with the notes/files app
scope; it is not a direct file-browser helper.

**What Allbert can read is bounded.** File access is enforced by Security Central's
permission gate plus **root-and-extension bounding** — Allbert only reads inside the
folder you connected, only known text/markdown extensions, up to a size cap. The resource
references shown in traces are provenance/audit metadata (what was touched); they are not
themselves the access gate. There is no broad filesystem grant.

## 3. Confirm a note write

`write_note` is **confirmation-gated**: Allbert proposes the write from chat/action
dispatch and nothing is written to disk until you approve the durable confirmation (web
approval, or `allbert admin confirmations approve <ID>`). The Notes panel does not add a
separate full note editor; the approval is a traced, auditable record.

## 4. Review memory

Open the **Memory** workspace destination (`workspace:memory`) to review candidates:

- **Keep** — the entry becomes recallable (`review_memory_entry status=kept`).
- **Reject** — the entry is flagged and stays out of recall
  (`review_memory_entry status=flagged`); it remains inspectable.
- **Delete** — confirmation-gated; archives the entry rather than hard-deleting it.

From the terminal: `allbert admin memory list|show|review|delete`, and
`allbert admin memory status` for read-only counts by review status. Status defaults to
the current user/operator scope and prints that scope; use
`allbert admin memory status --all-users` only when you intentionally want the aggregate.

**Nothing is remembered automatically.** Every new memory candidate is written
`unreviewed` and is **never recalled until a human review marks it `kept`** — including
anything an agent proposes. The `:notes_files` namespace is non-writable, so note content
never auto-promotes into memory.

## 5. Recall later

In a later chat, Allbert retrieves only **kept** memory and blends it into the answer
(with the usual recency/thread/identity scoring). Flagged, prune-nominated, and unreviewed
entries are never recalled.

## What this does not do

- No broad filesystem access — only the connected root, bounded by extension and size.
- No silent note writes — `write_note` is always confirmation-gated.
- No automatic memory promotion — review is explicit and required before recall.
- No new permission class, authority source, or confirmation floor.
