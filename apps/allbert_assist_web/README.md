# AllbertAssistWeb

Phoenix web surface for Allbert Assist.

Start the web demo:

```sh
export ALLBERT_HOME=/tmp/allbert-v006-demo
export ALLBERT_TRACE_ENABLED=true
mix phx.server
```

Open:

```text
http://localhost:4000/agent
http://localhost:4000/settings
```

The `/agent` LiveView is the v0.26 Allbert workspace. It renders
`AllbertAssist.App.CoreApp`'s Surface tree through catalog-dispatched
LiveComponents: chat, persistent per-thread canvas tiles, task-scoped
ephemeral surfaces, objective/status badges, trace cards, confirmation cards,
theme controls, mobile tabs, and offline text/markdown tile editors.
Workspace effects still cross the same runtime/action boundary as the CLI:
registered actions, `Actions.Runner.run/3`, Security Central, Settings
Central, traces, and Allbert Home remain authoritative.
The mobile breakpoint is fixed at 768px in v0.26; the Settings key is
read-only until a dynamic media-query strategy is implemented honestly.

The `/settings` LiveView uses Settings Central for operator settings,
provider profile status, skill trust settings, and editable permission
defaults. Its Security & Permissions section reads effective Security Central
status through the registered `security_status` action. v0.06 action-backed
skill behavior remains in the shared runtime/action boundary, so LiveView skill
prompts use the same selected-skill, contract, Security Central, and trace
metadata as the CLI.

v0.23 is an internal Jido state-machine convergence release. It does not add a
new web surface: `/agent`, `/settings`, and `/jobs` continue to call the same
runtime, settings, security, confirmation, and jobs boundaries. Default trace
output remains unchanged; `## Jido Debug` appears only when
`allbert.jido.debug_trace` is explicitly enabled.

v0.26 keeps that rule while making `/agent` substantially richer: the page owns
rendering and browser APIs, not runtime authority. The browser-side Yjs +
IndexedDB editor stores local drafts and sends bounded snapshots to the
workspace facade; server-side reconciliation records canvas revisions and
surfaces conflict/revert UI. Rejected or corrupt local drafts are retained in
browser storage with fallback-shell recovery metadata rather than discarded.
