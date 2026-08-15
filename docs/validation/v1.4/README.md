# v1.4 Release Evidence

## Binary closeout

v1.4.0 shipped on 2026-08-15. The immutable public release is
[`v1.4.0`](https://github.com/lexlapax/allbert-assist/releases/tag/v1.4.0).
Its exact source and tag are
`9c82179e79d624d9e682e683ecd2151734d3d392`; the accepted generation is
`v14-20260815T182644Z-9c82179e79d6`.

| Binding | Accepted evidence |
| --- | --- |
| GitHub Release | ID `371125351`; published `2026-08-15T19:48:23Z`; Latest, non-prerelease, immutable; exactly 18 assets |
| Candidate manifest | asset `515968742`; SHA-256 `ea238201cd6ce314471ec7c331a11ec19c42597d46a72936130a5e3c5a7d4f9a` |
| Qualification | run `31902242882`; artifact `9251424641`; SHA-256 `3b6fe103eeb1739a023021e746c8f8cd67da8a52057f209cb6d125f792755125`; macOS arm64, Linux x64, and Linux arm64 passed |
| macOS arm64 archive | `32931a29f2200e13a29eaa1eaf564c3414432957760a34fb9841149b1b8ea039` |
| Linux x64 archive | `49a2b40a39406da68b90da02d8d62b7ca39cd2dd8266b2c50c87188ab3cf47be` |
| Linux arm64 archive | `729d2150b8de2ee88efba80df0c4cab9bf324447596299bcb338a3a7448600dc` |
| Signed checksums | `SHA256SUMS` asset `516013528`, SHA-256 `1dca238dbd802ec7531c1082c61245abc593b553947eecec59f70c280ae1370d`; Cosign bundle asset `516013557`, SHA-256 `a741f9a90c8e678b7ba5932bb70cd662514e4a20159acc4232faf4f6fe0ada05` |
| Homebrew | public tap commit `775cbf8f1896838afad0919b20aac56cfd30c7db`; strict online audit, public-tap install, `brew test`, version, and licence checks passed |

R4b accepted the exact candidate after three-target qualification, unsigned
draft identity checks, Homebrew-shadow install, release-assembly and Pack
topology verification, ABI/native-byte comparison, licence equality, and
independent package smoke. The previously completed human-observed packaged
service, vault, real TTY/TUI, Memory/model/jobs, Telegram, and email behavior
checks remained valid because the final repair changed only release-test and
documentation code; every package identity and integrity check affected by the
new bytes was repeated on this generation.

The normal final release test was invoked twice only because the operator
approved a one-time v1.4 exception. Attempt 1 at `1f6ca6007` stopped in its
opening fast-local phase on two stale test definitions and supplies no release
acceptance. The approved replacement at the accepted source passed in
2,146,000 ms: high-coverage fast-local, external-runtime, security, Web,
Kernel, Composition, StockSage, extracted components, static checks, and
Dialyzer all passed with zero failures or findings.

Protected promotion run `31904696318` revalidated the candidate, created the
three byte-identical latest aliases, generated and signed the six-row checksum
file, uploaded the final five assets, verified the Cosign identity, and proved
the exact 18-asset set. Its final publish request received GitHub integration
token HTTP 403. An operator-token recovery independently rechecked all 18 asset
IDs, names, API and downloaded digests, alias byte equality, six checksum rows,
and the exact workflow/tag Cosign identity, then changed only Release
`371125351` from draft to public. A fresh read proved it immutable and Latest
with every asset ID and digest unchanged.

The published signed installer was then exercised from disposable prefixes and
Homes through both the pinned `v1.4.0` archive and the default `latest` alias:
Cosign verification, checksum verification, `allbert 1.4.0`, licence viewer,
and operator status passed. The public `lexlapax/allbert` tap was filled
from the published checksums, audited, pushed, freshly tapped from GitHub,
installed, and tested. Temporary v1.3/v1.4 candidate taps were then removed;
the retained installation receipt names only official tap commit `775cbf8f`.
No validation wrote to the operator's real Allbert Home.

## Source FV — What Was Driven, By Whom, And What Was Not

v1.4 is the kernel/pack boundary release. Its source FV therefore has one job:
prove that thirteen extracted packs actually work in a running system built
from source, not only in the suites that were written alongside them.

This file follows the v1.3 disclosure convention. It states plainly which parts
were exercised, which were not, and — the part that matters most — **who drove
it**.

## Who drove this

**Agent-driven at operator direction, 2026-08-14.** The operator directed the
agent to execute the source FV using the repository `.env`, and — after
connecting the Chrome extension — to drive the Web surface in a real browser.
The agent performed every step recorded below, including the browser
interactions. **No human personally exercised the TUI or the Web UI in this
run.**

That distinction is the reason this file exists. The v1.3 disclosure separated
"operator-exercised" from "agent-run", and this run is entirely the latter.
Anyone reading v1.4's release evidence should know that, and should not read
the PASS rows below as attended validation. The operator explicitly authorised
and directed the run; what the rows cannot say is that a human watched the
screen.

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

### Final release-identity retake

The observable rows invalidated by the 1.4.0 version checkpoint were retaken
agent-driven on 2026-08-14 at source-gate SHA `dd493b110`, again with a fresh
disposable Home under `/private/tmp` and without writing to the operator's real
Allbert Home:

- the warm product CLI reported exactly `allbert 1.4.0`;
- the live endpoint served `workspace-sw.js` with cache identity
  `allbert-workspace-shell-v1.4.0` and no 1.3.2 cache identity;
- Chrome loaded the real workspace at `http://localhost:4112/workspace`, then a
  full reload preserved the workspace, its conversation, the composer, and all
  five Pack surfaces (Artifacts, Browser, Notes/files, Research, and StockSage);
- the Chrome console contained zero errors after the reload.

This is a proportional retake of reported-version and Web cache/reload behavior,
not a claim that a human exercised the source UI. The original source FV rows
below remain bound to their disclosed SHA. At that stage packaged acceptance
was still owed to R4b; the binary-closeout section above records its completion.

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
| SV-5 | Web UI, interactive | **PASS** — see below |
| SV-5b | Pack web surfaces render real data | **PASS** — `notes_files` and `stocksage` |
| SV-5c | Cross-surface continuity and durability | **PASS** — CLI turns appear in the Web thread and survive reload |
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

### SV-5 — Web UI, driven in a real browser

The first pass of this FV recorded SV-5 as PARTIAL because the Chrome extension
was not connected. The operator connected it and directed a second pass; the
Web surface was then driven interactively in Chrome against the same disposable
Home.

**SV-5 — a real chat turn through the UI.** Typed into the workspace composer
and submitted with Enter. The LiveView showed *"Allbert is responding — Runtime
turn in progress"*, then rendered the answer **`WEBFV`** with
`Status: completed` and `Signal 01a00245-9270-7ce5-aa17-261cbfae8619`. That is
LiveView → runtime → intent → local model → response, in the browser.

**SV-5b — pack surfaces render real data.** The workspace APPS rail lists five
extracted packs: Artifacts, Browser, Notes/files, Research, StockSage.

- **`notes_files`** opened to its own panel, status `ready`, and its search
  returned `fvcheck — fvcheck.md - ALLBERTFV-NOTE-OK`. That closes a full round
  trip: an action denied for scope, then confirmation-gated, then approved and
  written to disk, then read back by the pack's own LiveView surface.
- **`stocksage`** opened its dashboard — ANALYSIS panel with TICKER/ENGINE/
  RATING/CONFIDENCE tiles, plus Recent analyses and Analysis queue, all `ready`.

**SV-5c — continuity and durability.** Turns issued through the CLI earlier in
this run appear in the Web thread, and the Web turn survived a full page reload.

**No console errors** were captured on a fresh workspace load.

One observation, recorded but not called a defect because it was seen once and
not reproduced: the first click on StockSage highlighted the sidebar item
without opening its panel or setting the `destination` query param; a second
click opened it. Notes/files opened on the first click.

### SV-9 — licence viewer is packaged-only

`allbert licenses` fails closed from source:
`license evidence error [manifest_missing]: required release file missing:
THIRD-PARTY-MANIFEST.json`. That file is produced by the release finalizer, so
the viewer is correctly a **packaged**-FV item and moves to M17.b. Failing
closed is the right behaviour and is recorded as a pass of the boundary, not a
gap.

## Not exercised in source FV; completed in M17.b packaged FV

- **Real configured Telegram and email endpoints.** All eight channels were
  registered but `enabled=false` with `credentials=missing` on the source-FV
  Home. The later packaged FV completed both configured endpoint rows.
- **Install, service lifecycle, vault tiers, TTY, ABI, relocation, package
  smoke.** All were completed during packaged acceptance.
- **Interactive TUI.** `allbert tui` needs a TTY; the daemon's attach server
  reports `not_started` under `mix phx.server`, so no attach session was opened.
  The seam behind it was verified structurally (SV-6), which is not the same as
  opening a session. **This is the one surface in v1.4 that no part of this run
  exercised end to end**. The later packaged FV completed the real TTY/TUI row.

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
