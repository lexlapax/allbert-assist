# Local Knowledge Path

Status: v0.65 design artifact (2026-07-10). Expands the v0.65 plan
(`docs/plans/v0.65-plan.md`) and the ADR 0077 v0.65 amendment into the local
files/notes + reviewed-memory launch path, its as-built substrate, the two new
information-architecture destinations, and the enforcement/guardrail contract. It is
design only; it does not add authority.

## Decision Summary

For the 1.0 non-developer launch, the **primary useful workflow** after first chat is
local knowledge: point Allbert at a local notes/files folder, ask about those notes,
confirm a safe write, decide what Allbert may remember, and have that reviewed memory
improve a later answer. Remote channels, MCP, browser research, and public protocols
remain implemented, release-blocking regression surfaces — but they are not the
first-run product path.

The engine for this already ships (v0.42 notes/files native plugin; v0.21/v0.39b memory
review + active-memory). v0.65's job is to make it an **obvious, config-free product
surface** and to document the real boundaries — not to re-implement the engine, and not
to add authority.

## First Useful Local-Knowledge Loop

The launch loop is five concrete steps:

1. **Configure a notes root** — from onboarding, the post-first-chat QuickStart
   affordance, web/settings affordance, or `allbert admin notes set-root PATH`; no
   hand-edited config.
2. **Search / read** a note (`search_notes`, `read_note`; the `workspace:notes`
   destination).
3. **Confirm a write** — `write_note`, confirmation-gated, with a durable
   confirmation + trace.
4. **Review memory** — inspect a candidate and keep / reject / delete it in the
   `workspace:memory` panel (or `admin memory`); Reject means `:flagged`, while Delete
   archives through confirmation.
5. **Recall later** — a subsequent chat retrieves the kept memory into the answer.

## As-Built Substrate (what v0.65 documents, not re-implements)

- **Native action plugin, not MCP.** `plugins/allbert.notes_files/` is an in-process
  `AllbertAssist.Action` plugin registered in the shipped-module map, not an MCP server.
  "Connect a notes root" is therefore a native settings-root concern, not MCP-server
  configuration. (The v0.65 request-flow previously mis-cited MCP trust ADRs; corrected.)
- **Three actions.** `search_notes` / `read_note` (`:read_only`, no confirmation);
  `write_note` (`:notes_file_write`, `confirmation: :required`, resumable) with a real
  durable-confirmation resume.
- **Notes root setting** `apps.notes_files.notes_root` (default `<ALLBERT_HOME>/notes`).
- **Memory review loop** as registered actions with review statuses
  `:unreviewed / :kept / :flagged / :prune_nominated`; delete is confirmation-gated
  (archives, not hard-delete).
- **Recall is real end-to-end.** The default answer action retrieves active memory and
  injects it into the live model prompt; only `:kept` entries are retrieved.

## Enforcement Contract (the real seam)

Local file access is **not** gated by Resource Access grants. It is enforced by:

- `PermissionGate.authorize/2` on the action's permission class, and
- **root-and-extension path bounding** in the plugin (`inside_root?`, an extension
  allowlist, and a max read-bytes cap).

The `ResourceURI` / `Scope` refs the plugin emits on each response are **provenance and
audit metadata** — they describe what was touched; they are not consulted as a
grant/scope check at the `File.*` boundary. Docs and copy must describe this real seam;
routing notes I/O through `Grants` would be a separate, explicit future decision, not an
implied v0.65 behavior.

## Memory Review + Auto-Promotion Guard

The "never auto-promote; review before durable recall" property is enforced, not
aspirational:

| State | Meaning | Recallable? |
|---|---|---|
| `:unreviewed` | A candidate; the default for every newly written entry (incl. agent `AppendMemory`). | No |
| `:kept` | A human review action promoted it. | Yes — retrieved into later answers. |
| `:flagged` | Reviewed and held back; this is the v0.65 UI Reject result. | No |
| `:prune_nominated` | Nominated for removal. | No |

The only `:unreviewed → :kept` transition is a permissioned human review action. An
agent can create a candidate but cannot make it recallable. The `:notes_files` memory
namespace is non-writable and rejects writes outright, so note content never
auto-promotes into memory.

## Information Architecture (two new first-class destinations)

v0.65 adds two navigable destinations, modelled on `workspace:models`:

- **`workspace:notes`** — search/read/confirm-write over the configured root, rendering
  the notes app's existing panel surfaces, reachable from a nav item (not only a raw
  `app:notes_files` destination URL).
- **`workspace:memory`** — an interactive review panel that wires the existing
  `ReviewMemoryEntry` / `DeleteMemoryEntry` actions (keep / reject-as-`:flagged` /
  delete) through the Runner, with delete confirmation-gated. It surfaces an
  already-permissioned loop and adds no authority.

The dedicated CLI affordance for setup is `allbert admin notes set-root PATH`, backed by
the same `set_notes_root` action as onboarding/web. The generic
`admin settings set apps.notes_files.notes_root PATH` remains a low-level fallback, not
the product path.

These IA additions are recorded in the ADR 0077 v0.65 amendment.

## Guardrails

- No new file permission class, confirmation floor, or broad filesystem grant.
- No automatic indexing of arbitrary home directories; the root is explicit.
- No auto-promotion of notes, files, chat output, or plugin output into memory.
- Resource Access refs remain provenance; the enforcement seam is
  `PermissionGate` + path/extension bounding until a later ADR says otherwise.
- The new surfaces make controls easier to use; they never infer authority from a
  plugin/app surface or lower a confirmation floor.
