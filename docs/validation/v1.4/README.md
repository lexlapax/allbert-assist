# v1.4 Source FV — What Was Driven, By Whom, And What Was Not

v1.4 is the kernel/pack boundary release. Its source FV therefore has one job:
prove that thirteen extracted packs actually work in a running system built
from source, not only in the suites that were written alongside them.

This file follows the v1.3 disclosure convention. It states plainly which parts
were exercised, which were not, and — the part that matters most — **who drove
it**.

## Who drove this

**Agent-driven at operator direction, 2026-08-14.** The operator directed the
agent to execute the source FV using the repository `.env` and the browser. The
agent drove every step recorded below. **No human personally exercised the TUI
or the Web UI in this run.**

That distinction is the reason this file exists. The v1.3 disclosure separated
"operator-exercised" from "agent-run", and this run is entirely the latter.
Anyone reading v1.4's release evidence should know that, and should not read
the PASS rows below as attended validation.

Secrets were sourced from the operator's `.env` into the process environment and
never printed, logged, or written into the repository. No credential was entered
into any vault, and nothing was written to the operator's OS keychain.

## The harness, and one thing it revealed

Run on a **fresh disposable Home** at
`$CLAUDE_JOB_DIR/tmp/fv-home`, never `~/.allbert`, at SHA `89ecc1d13` with
`MIX_ENV=dev`.

The first attempt used `mix phx.server`. That was the wrong harness, and finding
out why is itself a result:

> `ProductBootstrap.ensure_ready/1` is called from exactly one place in
> production code — `product_cli.ex:112`, the packaged CLI entry. `mix
> phx.server` never calls it.

Under `mix phx.server` alone the endpoint accepts connections while
`/health` still reports `pack: unavailable, phase: collecting, expected_ids:
[]`. It reaches `ready` about forty-five seconds later. **The web endpoint
serves before the Pack projection is ready.** That is a timing fact worth
recording rather than a defect, but it is invisible to every suite.

`allbert serve` cannot start a daemon from source at all — it prints
"`allbert serve` is handled by the release launcher". Source FV therefore runs
the web surface through `mix phx.server` and every pack/CLI step through
`ProductCLI.main/1`, which is the real product entry.

## Results

| Step | What it proves | Result |
| --- | --- | --- |
| SV-0 | Daemon boots from source on a fresh disposable Home | **PASS** — endpoint at `127.0.0.1:4111` |
| SV-1 | Pack composition reaches ready | **PASS** — `pack: ready`, coordinator ready, 8 expected ids all acked, snapshot digest bound |
| SV-1b | All thirteen packs register through the pack contract | **PASS** — 13 shipped/enabled/trusted; 7 channel packs `channels=1`, `stocksage` 16 actions + 1 skill, `browser` 13 actions, `notes_files` 3 actions + 1 skill |
| SV-2 | Product CLI dispatch works from source | **PASS** — `admin status` |
| SV-3 | Operator surface and channel packs | **PASS** — help renders including `allbert tui`; all 8 channels list with provider and release state |
| SV-4 | A real model-backed turn, end to end | **PASS** — returned exactly `ALLBERTFV` through local Ollama (`qwen2.5:7b`), keyless |
| SV-6 | The M15.1 `session_owner` seam resolves live | **PASS** — descriptor carries `AllbertAssist.Runtime.Attach.TUISession`; loaded, exports `start/1`, and `owner_application = {:ok, :allbert_tui}` |
| SV-7 | An extracted pack's action runs with a real filesystem effect | **PASS** — see the gated loop below |
| SV-8 | The confirmation boundary fails closed | **PASS** — see below |
| SV-5 | Web UI, interactive | **PARTIAL** — HTTP only |
| SV-9 | Licence/component viewer | **N/A from source** — see below |

### The gated loop, in full

This is the strongest single result, because it exercises the kernel contract,
an extracted pack, the resource-grant shape, and the confirmation boundary in
one path:

1. `write_note` invoked with no active app scope → **denied**,
   `app_scope_denied / missing_active_app_scope`: *"Action write_note is scoped
   to :notes_files and cannot run from nil."* The pack contract is enforced.
2. With `active_app: "notes_files"` → **`needs_confirmation`**, message *"Nothing
   has written yet."* The notes directory was verified **empty** at this point.
3. The durable confirmation names the exact resource:
   `write_local_path write exact_file:<notes_root>/fvcheck.md consumer=notes_files`,
   permission `notes_file_write`.
4. Approved → `status=approved`, `Target: write_note status=completed`, and the
   file exists with exactly the expected content.

Nothing was written before approval, and that was checked rather than assumed.

### SV-5 — Web UI, and why it is PARTIAL

The Chrome extension was **not connected**, so no interactive browser
verification was possible. What was verified over HTTP: the workspace root
returns `200` with ~40 KB of HTML carrying 144 LiveView markers and the
workspace shell.

That is a render check, not a use check. **No LiveView interaction, no click, no
form, no visual confirmation.** Any claim that the v1.4 Web surface was
functionally validated would be false on this evidence.

### SV-9 — licence viewer is packaged-only

`allbert licenses` fails closed from source:
`license evidence error [manifest_missing]: required release file missing:
THIRD-PARTY-MANIFEST.json`. That file is produced by the release finalizer, so
the viewer is correctly a **packaged**-FV item and moves to M17.b. Failing
closed is the right behaviour and is recorded as a pass of the boundary, not a
gap.

## Not exercised, and owed to M17.b packaged FV

- **Real configured Telegram and email endpoints.** All eight channels are
  registered but `enabled=false` with `credentials=missing` on a fresh Home. The
  plan places real configured endpoints in M17 step (6), attended packaged FV.
- **Install, service lifecycle, vault tiers, TTY, ABI, relocation, package
  smoke.** All packaged concerns.
- **Interactive TUI.** `allbert tui` needs a TTY; the daemon's attach server
  reports `not_started` under `mix phx.server`, so no attach session was opened.
  The seam behind it was verified structurally (SV-6), which is not the same as
  opening a session.

## One defect class this run surfaced

A **dev-environment compile warning** that no gate can see:

```
warning: unused alias TestRegistry
  apps/allbert_kernel/lib/allbert_assist/pack/effect_guard.ex:4:3
```

Every gate runs `MIX_ENV=test`, where that alias *is* used, so the warning only
appears in a `dev` build. This is the same env-skew class M13.3 found with
Dialyzer, where the gate measured `test` while the artifact shipped `prod`. It
is recorded here rather than fixed silently.
