# ADR 0076: Packaging, Distribution & Unified CLI Entry Points

Status: Accepted (v0.62) — ratified at the v0.62 request-flow S8 sign-off (2026-07-06).
Date: 2026-06-25 (amended 2026-07-05 by the v0.62 implementation-readiness
pass: Bakeware struck as archived, CLI process model + vault tiering + First-
Model-Path execution authority recorded, Distribution Trust section added;
second-pass readiness corrections clarified platform tiers, attach transport,
service ownership, and Ollama authority; third/fourth-pass corrections on
2026-07-06 aligned installer execution to `:command_execute`, recorded the
v0.64 trust intake, and confirmed full v0.62 scope with all eight M0 proofs
binding).
Related: ADR 0077 (Product Experience Design & IA — designs the entry-point / CLI
UX in v0.60 M5; this release implements it in v0.62), ADR 0078 (First-Model Path —
its chosen option requires detecting/guiding Ollama setup and managing a curated
model pull, without bundling the Ollama runtime into the packaged artifact),
ADR 0070 (TUI operator console — this completes its mix-free
convergence), ADR 0067 (TUI/terminal channel), ADR 0004 / ADR 0031 (Settings
Central), ADR 0069 (onboarding — v0.63 builds on the entry points and vault
model defined here), ADR 0006 (Security Central — packaging changes how Allbert
is installed and invoked, not what any surface may do), and the Allbert Home
layout decisions. Anchors the v0.62 Packaging & Entry Points release.

## Context

Allbert is **mix-only** today. The v0.58 maturity review confirmed: no escript, no
`releases:`, no Burrito/Bakeware, no `rel/`, no install script, no Homebrew, no
Docker. A new user needs a git checkout plus the full Elixir/OTP toolchain, and
the start path is `mix setup` → `mix phx.server` / `mix allbert.onboard`. There
are 55 flat Mix task modules at the 2026-07-05 readiness review (46 core + 9
plugin; "53" was the v0.58 count), with no unified binary, no grouped `--help`,
and operator commands intermixed with developer/CI commands.

For the pre-1.0 product audience, the toolchain requirement is the **dominant
adoption blocker** — the exact friction that gets powerful-but-Docker/dev-required
tools penalized in every 2026 comparison, while packaged binaries with
one-command install (LM Studio, Jan, OpenClaw, Hermes) win on first value. This
release reshapes Allbert Home layout and entry points before guided onboarding,
trusted first-run, local knowledge, and product RC validation lock in the
first-run flow.

## Decision

1. **Packaged `allbert` binary.** Ship a release-built artifact (OTP release
   with ERTS bundling — the v0.62 M0 spike chooses between Burrito 1.5.x and a
   hand-wrapped release; **Bakeware is struck: archived upstream 2024**) so no
   Elixir/OTP is required on the user's machine, distributed via **Homebrew**
   and a **curl install script**. Artifacts are **built natively per target
   triple in CI** — cross-compilation is not viable for this dependency tree
   (rebar3-built `erlexec` and the `muontrap`/`erlexec` port *executables* are
   invisible to or mis-built by NIF-oriented cross recompilation). The
   provisional freeze-blocking matrix is `macos-arm64`, `linux-x64`, and
   `linux-arm64`; the M0/S2 spike sign-off must explicitly promote
   `macos-x64` or record it as non-blocking compatibility.
2. **Unified grouped CLI dispatcher.** A single `allbert <group> <command>`
   surface — `ask | chat | tui | serve | admin <area> | gen`, plus the
   bare-`allbert` first-run/resume dispatcher from the design artifact —
   subsuming the flat mix-task sprawl, with coherent grouped help.
   **Process model (operator decision 2026-07-05): attach-first** — commands
   connect to a running daemon over a local-only authenticated attach transport;
   an embedded runtime boots only when no daemon runs, under single-writer
   discipline (never two BEAM writers on one SQLite file). Operator commands are
   separated from developer/CI commands; the latter stay `mix`-only. The
   v0.62 as-built transport is a Unix-domain socket under Allbert Home
   (`runtime/attach.sock`) with a per-Home token file and protocol/Home/user/
   version handshake; Erlang distribution was not used. The entry-point and CLI
   *UX* (group/command shape, help layout,
   first-invocation experience) is designed in the v0.60 Product Experience
   Design release (ADR 0077 M5); this release implements it.
3. **Background-daemon management.** `allbert serve` plus install/uninstall of a
   per-user launchd / systemd service, with a health check the user can see
   succeed — covering the runtime, web workspace, and channels. Native Windows
   Scheduled Task support stays Tier 2 unless a later ADR promotes it.
4. **Complete the ADR 0070 convergence.** The mix-free TUI operator console
   absorbs the remaining admin-inspection reads so operators never need raw `mix`
   for day-to-day operation.
5. **OS secret-vault.** Credential storage moves to a **three-tier backend**
   (operator decision 2026-07-05): (1) the OS keychain / secret service via
   shell-out where available — no maintained Elixir vault library exists in
   2026; (2) a documented fallback to the existing encrypted
   `Settings.Secrets` store where no vault is reachable (headless Linux
   daemons cannot assume a D-Bus keyring session); (3) env injection for
   automation. Settings Central keeps holding *references* (the existing
   `secret://` schema types); the v0.63 onboarding wizard teaches this final
   credential path instead of a temporary one.
6. **First-Model-Path packaging hook.** ADR 0078 (decided in v0.60) selects an
   assisted local-model QuickStart, so this release must **detect and guide an
   Ollama install plus curated model pull** alongside the packaged artifact.
   Ollama is a managed external dependency, not bundled into the `allbert`
   binary; BYOK remains the Advanced/fallback path. **Execution authority
   (operator decision 2026-07-05): Allbert executes the guided install and
   pull itself, through the S4-ratified supported upstream path only, each step
   behind an explicit operator confirmation with trace/egress recording** —
   this is its own v0.62 milestone, not a packaging footnote.

The concrete v0.60 M5 entry-point artifact is
`docs/design/entry-point-cli-ux.md`: command taxonomy, grouped help model,
first-run detection, first-model-state check, wizard launch sequence, and
Mix-to-`allbert` mapping for the v0.62 implementation.

## Consequences

- **Toolchain-free install** — the v1.0 acceptance-matrix install criterion
   becomes achievable for a non-developer-toolchain user.
- The packaged binary and the grouped CLI surface become **Tier-1 freeze
   candidates** at v1.0; settling them before onboarding and product RC is what
   makes the freeze meaningful.
- **No authority change.** Packaging changes how Allbert is installed and invoked;
   it does not change what any surface may do. Security Central, confirmations, and
   the action boundary are unchanged; the `mix` tasks remain available for
   development.
- Allbert Home layout may shift to accommodate packaged-install paths and the OS
   vault — done here, before guided onboarding and product RC lock the
   user-facing flow.

## Distribution Trust (added 2026-07-05)

Packaging is Allbert's **first external distribution surface**; the local-first
and inspectability promises extend to it:

- **Enumerated network touches.** Installation and first-run may touch the
  network in exactly four ways: (1) the install-script artifact fetch, (2) the
  Homebrew tap/artifact fetch, (3) the Ollama installer fetch, (4) the curated
  model pull. (3) and (4) execute only behind explicit operator confirmations
  with trace records and through existing authority classes: `:external_network`
  for metadata/model fetches (the reviewed `ExternalNetworkRequest` path, hosts
  admitted via existing `external_services.*` values) and for the curated model
  pull over the loopback-only local Ollama API (`/api/pull`, implemented with
  `Req` and `stream: false` for a bounded JSON summary), and
  **`:command_execute` with exact argv/resource allowlists for ALL installer
  execution — Homebrew formula or official script** (operator decision
  2026-07-06; `:package_install` is not applicable: its `InstallSpec` is
  npm/pip-only and rejects global installs by design). If the effect cannot
  fit an existing class, v0.62
  records a blocker or invokes the BYOK-primary contingency; it does not add a
  new permission atom during implementation. Nothing else; the binary itself
  performs **no telemetry, no phone-home, and no auto-update check**.
- **Verifiable artifacts — TOFU-over-HTTPS is the accepted v0.62 trust model
  (operator decision 2026-07-05, restated M8.17).** Release artifacts publish
  SHA256 checksums, and both install paths verify the downloaded artifact against
  `SHA256SUMS` (refusing to install on a mismatch). Because the installer fetches
  `SHA256SUMS` over HTTPS from the **same** GitHub release origin as the artifact,
  that check proves download **integrity**, not independent provenance — trust is
  **trust-on-first-use of the GitHub HTTPS origin**. The release also publishes
  `SHA256SUMS.cosign.bundle` (keyless cosign), but v0.62 uses it **only for
  optional, out-of-band, operator-driven manual verification** — no `cosign`
  dependency is added to `install.sh` or the formula, so the installer does not
  itself verify a signature. **Mandatory installer-side signature verification is
  recorded in v0.64 trusted-install scope** (`v0.64-plan.md`), which will close
  the TOFU gap (closed — shipped fail-closed in v0.64; see the v0.64 amendment below). The bundled ERTS/OTP version is pinned as a CI input
  with portable crypto linkage; its provenance (project-built vs the packaging
  tool's CDN builds) is settled by the M0 spike and recorded here at
  acceptance.
- **Signing posture (operator decision 2026-07-05).** v0.62 ships **unsigned,
  via Homebrew and curl only** — both paths are quarantine-free on macOS;
  browser-download distribution is out of scope. Developer-ID signing +
  notarization is a named **v0.64 trusted-install work item** (including the
  Apple Developer account decision and the self-extraction × hardened-runtime
  interaction test).
- **Inspectable install.** Both install paths install only documented files,
  write an uninstall manifest, and leave Allbert Home untouched on uninstall
  absent an explicit `--purge`. Tap/artifact-hosting ownership (domain, repo)
  is recorded at the v0.62 S3 sign-off — including the explicit decision that
  release-artifact URLs are anonymously fetchable. S3 also decides the exact
  Homebrew package type (formula vs cask — noting `brew services` blocks are
  **formula-only**), whether Homebrew's service block is used, and
  whether service lifecycle stays entirely under `allbert serve`; v0.62 must
  not ship two competing service managers for the same install path.
- **Packaged-plugin constraint.** A packaged install can never gain new plugin
  *code* (plugins compile into the artifact at build time); Home-directory
  declarative entries and operator-confirmed dynamic drafts remain the runtime
  extension paths. This is a documented product fact, not a defect.

## Amendment (v0.64 implemented, 2026-07-10 UTC)

v0.64 closes the v0.62 trust-on-first-use gap for the non-developer first run and
records the package-manager boundary explicitly:

- The curl installer performs mandatory, fail-closed signature verification. It
  downloads `SHA256SUMS.cosign.bundle`, requires `cosign verify-blob` against the
  GitHub Actions workflow identity/issuer, and does not install the Allbert artifact
  until signature and artifact SHA256 verification both succeed.
- The Homebrew path uses Homebrew's package-manager trust contract: the trusted tap
  formula pins the release URL and SHA256 for each target, and Homebrew verifies the
  artifact against those values. It does not run the curl installer's cosign verifier
  inside `brew install`. v0.64.2 makes the tap-fill process version-aware so formula
  version, URLs, and checksums update together before tap publication.
- **Sign↔verify coupling (required same-release).** The release workflow's cosign
  *sign* step is a hard gate in the same release that introduces installer
  verification (`.github/workflows/release-artifacts.yml`); the two changes cannot
  land apart. `v0.64.0` correctly blocked before publish when the Linux rehearsal did
  not create a cosign bundle for the local `file://` installer path, and `v0.64.1`
  fixed the rehearsal by signing local checksums before running the fail-closed
  installer.
- The primary packaged first-run path is persistent service start plus browser
  onboarding. Foreground `allbert serve` remains a diagnostic and service-manager
  fallback.
- The First-Model-Path packaging hook remains managed Ollama plus curated model
  pull. v0.64 changes the presentation and feedback loop, not the dependency
  model: no manual `ollama` CLI, no API key on the consumer-default path, and a
  web progress surface for the pull API.
- Upgrade rollback must be either automated or documented as a proven restore
  command from the backup-before-migrate artifact before v0.64 can close.
- Startup migrations now acquire a bounded cross-process lock before pre-supervision
  migration work so concurrent fresh-Home first commands do not both enter migration
  execution before the runtime writer lock is held.
- Developer-ID signing/notarization did not ship for the current Homebrew/curl
  distribution path. It remains future work for a browser-downloaded/native desktop
  distribution channel, not a blocker for the v0.64 Homebrew/curl package path.

## Non-goals and guardrails

- **Not a native desktop GUI client.** A full native client stays post-1.0; the
  web workspace remains the operator UI through v1.0 (the binary serves it).
- **Not hosted/remote distribution or plugin auto-update** — those remain
  future-features items.
- The CLI dispatcher reorganizes entry points; it does not add capability or
  authority — every command still routes through the same runtime/action/settings
  spine (ADR 0073).
- The attach transport is local-only. It does not expose a routable listener,
  authenticates against per-Allbert-Home runtime state, and refuses
  version/Home/user/protocol mismatches instead of booting a second writer.
  v0.62 ships the UDS mechanism ratified at S2; loopback distribution remains a
  rejected fallback, not an implementation dependency.
- Developer-ID signing/notarization remains future work for a distribution channel
  that needs it. v0.64 ships Homebrew/curl distribution with curl cosign verification,
  Homebrew formula SHA256 verification, and a proven backup-restore path rather than
  automated rollback.

## Platform Support Tiers And Feasibility Spike

Two explicit scope decisions, recorded here so they are not assumed downstream:

- **Tier 1 — macOS and Linux** are fully supported and freeze-blocking for v1.0:
  the binary, Homebrew/curl install, `launchd`/`systemd` daemon, and the macOS
  Keychain / Linux Secret Service vaults. The CPU/artifact matrix is settled by
  the M0/S2 spike; until then the freeze-blocking proposal is `macos-arm64`,
  `linux-x64`, and `linux-arm64`, with `macos-x64` explicitly decided at S2.
  **Tier 2 — Windows** is supported via WSL2; native Windows packaging, a
  Scheduled-Task daemon, and Windows Credential Manager are best-effort/beta and
  **not** v1.0 freeze-blocking unless a later ADR promotes them.
- **Feasibility spike first.** Because the codebase has no packaging today, the
  packaging mechanism (Burrito 1.5.x or a hand-wrapped OTP release; Bakeware is
  archived and struck) is chosen by a time-boxed v0.62 M0 spike that must prove
  an ERTS-bundled binary boots with the `exqlite` SQLite NIF **and the
  `erlexec`/`muontrap` port executables**, serves the compiled web assets,
  **registers** one source-tree plugin from the packaged layout, drives the TUI
  raw-mode input, and supports the attach transport, on a Tier-1 OS with no
  toolchain present (the full eight-proof list lives in the v0.62 plan M0). The
  spike result selects the mechanism; this ADR does not pre-commit one.

## Amendment (v0.63 M8.1, 2026-07-08) — the `eval` dispatch must start non-DB runtime deps

Operator validation found packaged bare/first-run `allbert` crashing with
`unknown registry: Req.Finch`. The packaged dispatcher runs non-serve commands via
`mix release` `eval`, which **loads but does not start** OTP applications. Pure /
first-run commands legitimately skip the DB runtime, but some still make HTTP calls
(the localhost first-model Ollama probe on the post-completion `detect` path), which
need Req's `Req.Finch` pool — started only when the `:req` application starts.

Decision: the CLI entry (`run_entry/1`) explicitly `Application.ensure_all_started(:req)`
before dispatch. This is HTTP-only (no database, no writer lock), so it does not breach
the "pure commands skip the runtime" invariant — `:req` is the HTTP client, not the
Allbert runtime. Any non-DB runtime dependency a pure command needs must be started the
same way; relying on `eval` to have started it is a defect. The release smoke rehearsal
(M8.8) now exercises a bare/first-run command through the packaged `eval` path so this
class of "loaded-not-started" gap is caught before an operator.

## Amendment (v1.0.5 M8, 2026-07-21) — cross-process settings and service lifecycle

The signed `v1.0.5-rc.1` WSL2 rehearsal exposed two packaged-process failures
that the checkout and container gates did not exercise together:

- concurrent short-lived release CLIs operating on one Home could observe
  malformed `settings.yml`; same-directory atomic rename alone did not serialize
  the full read-modify-write transaction or guarantee a temporary name unique
  across separate BEAM OS processes; and
- a confirmed systemd install used `enable --now` from an embedded runtime that
  still held the same Home/database while `systemctl` waited for the new service.
  The service waited for the startup migration lock, producing a wait cycle.
  Uninstall also removed the unit independently of the returned manager result,
  while the generic confirmation resume could represent a target `:error` as a
  denied operator decision.

The packaged-process contract is amended:

1. Settings Central owns a Settings-specific SQLite sidecar lock at
   `<ALLBERT_HOME>/settings/settings.lock.db`, using the already-shipped Exqlite
   `BEGIN EXCLUSIVE`/connection-lifetime pattern from `Runtime.WriterLock` (50 ms
   retry, 5-second bound). It does not reuse the runtime's long-lived database
   writer lock. A writer acquires it before the read-modify-validate-write
   transaction, re-reads inside the lock, writes
   `settings.yml.tmp-<OS pid>-<unique integer>` in the same directory,
   flushes/closes it, and atomically renames it. Readers consume only the stable
   path. Timeout or lock failure preserves the last valid generation and returns
   a stable diagnostic.
2. Service-control confirmation records the operator's approval durably before
   a manager effect that may start or stop the runtime executing that command.
   Target execution status is separate annotation: a failed target remains an
   approved attempt with `target_status: error`, not an invented denial.
3. systemd install runs daemon-reload, `enable allbert.service`, then
   `start --no-block allbert.service`; uninstall runs
   `disable allbert.service`, then `stop --no-block allbert.service`.
   `target_status: queued` is durable before start/stop. This lets a one-shot CLI
   release its writer lock before the new service boots and lets a running
   service retain the approved decision even if its own stop wins the response
   race. A surviving caller annotates the terminal target result.
   Operator validation polls the manager and `/health` to a bounded terminal
   state; a queued command is not called healthy merely because it was accepted.
4. Unit removal follows an accepted successful or named already-absent stop/
   disable result and is followed by daemon-reload. Other failures retain the
   unit and return exact redacted command results. Install and uninstall are
   idempotent.

All execution still resolves through `Actions.Registry` and
`Actions.Runner.run/3`; the amendment changes process/effect ordering, not
authority. Release tests inject manager commands and never operate a developer's
real service. The signed-RC real-host rows remain the final systemd proof.
