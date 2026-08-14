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

## Amendment (v1.4 M1.a3, 2026-08-06) — composition owns entry orchestration

ADR 0098 moves only the shared entry owner. Descriptorless
`allbert_composition` owns both `AllbertAssist.Pack.ProductCLI.run_entry/1` and
`main/1`. `run_entry/1` owns the required pre-dispatch Req startup, attach-first
selection, readiness-bound embedded bootstrap, and returned stream/output/code
tuple; `main/1` alone prints and halts. Residual `AllbertAssist.CLI`
retains the single command table, classifier/EntryPlan, renderer, and attached/
local dispatch APIs; neither residual nor kernel depends upward on composition.
The old residual `main/1` and `run_entry/1` owners retire rather than delegate
upward.

The behavioral decisions in this ADR remain unchanged. `licenses` is still
classified before Req, attachment, or product bootstrap and still reads only
packaged evidence. Other runtime-free paths preserve the v0.63 idempotent Req
startup where the entry plan assigns it. Runtime-needing paths receive an exact
Pack epoch and fail closed before effect when readiness is missing or stale.
Raw release eval remains an explicit unsafe operator/debug escape; repository-
owned product validation must use the v1.4 ProductBootstrap guard.
Residual compatibility `AllbertAssist.CLI.run/1` and `run_attached/1` preserve
ready-phase dispatch by admitting one already-ready kernel epoch and
revalidating that exact token at the effect boundary; neither starts
composition, attaches, or retries against a replacement epoch. ProductCLI and
Runtime Attach production paths continue to carry their bootstrap/daemon-
admitted epochs instead. An Attach readiness rejection uses the additive
existing-wire error `{:error, {:command_rejected, :product_not_ready}}` and is a
final stderr/exit-3 result, never a transport-failure fallback.

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

## Amendment (v1.2.5 → v1.3 final readiness, 2026-07-28) — thin TUI and packaged license evidence

Two additive post-1.0 decisions refine this ADR without changing any existing
command's meaning or the distribution channels. `licenses` is one additive
read-only informational leaf under the Tier-2 CLI evolution rule, not a
regrouping of the frozen command taxonomy.

### Daemon-backed `allbert tui`

ADR 0091 makes `allbert tui` a thin terminal client of the one daemon that owns
the selected Allbert Home. The client opens no Repo, runs no migration, and
boots no embedded application tree. The existing kind-absent attach-v1 command
packet remains the legacy one-shot CLI contract; only the additive, bounded
`:tui_session` frame family creates a long-lived terminal attachment.

When no matching daemon is available, or a daemon is known to be running but its
attach endpoint cannot authenticate or negotiate a session, the TUI returns
repair/start guidance and exits. It never falls back to an embedded writer.
When the daemon's attach listener cannot bind, the Web/runtime service remains
up in an explicitly degraded health state, while commands that need to attach
(including the TUI) fail closed. This supersedes this ADR's earlier
TUI-specific embedded fallback; ordinary no-daemon one-shot CLI behavior remains
unchanged unless its command requires daemon custody.

### One small final-artifact license finalizer

Every binary release carries `LICENSE`, the project's minimal relevant
`NOTICE`, and generated third-party license/provenance material for the known
components actually shipped in that target artifact. Generation is an offline
release-build step after all artifact-mutating steps (including assets, plugins,
native-library patching, and dispatcher installation) and before archive,
checksum, and signing. The packaged CLI provides a read-only viewer over those
files; it does not rescan dependencies, regenerate notices, contact a network,
or maintain license runtime state.

`allbert licenses` is a pre-runtime dispatcher case. Argument classification
happens before the shared `run_entry` path initializes Req, starts the
application/Repo, or attempts daemon attachment. The command starts only the
release evaluation VM and the small packaged-file reader needed to render the
already-generated material. It performs no network access. The finalizer and
viewer remain one `AllbertAssist.Licenses` concern, not a supervised service,
registry, database, or second dependency-management subsystem.

Implementation stays deliberately small: one finalizer, Mix's final release
application closure as a baseline, and one reviewed declarative catalog for
non-application and file-scoped exceptions. Target inspection covers known
extras such as ERTS/OTP, Elixir, plugins/web assets, SQLite, a copied OpenSSL
library where present, Mozilla-derived CA data, and IANA-derived time-zone data.
Package-level SPDX metadata is evidence to check, not proof for every nested
file. A missing or unapproved license for a known managed component fails the
build; the system does not attempt a recursive universal license detector.

Castore's code remains Apache-2.0, while its Mozilla-derived
`priv/cacerts.pem` is one narrow file-scoped MPL-2.0 exception. The catalog
binds that payload to exact source/conversion provenance and digest, packages
the MPL text, and supplies an immutable exact-source retrieval reference with
digest and conversion provenance. The build fails if that source-availability
path is absent or the payload drifts. Publication qualification performs an
unauthenticated fetch of the immutable reference and must match the recorded
source digest. The finalizer and
packaged viewer remain network-free; a failed external availability check
blocks publication. Schema v1 selects the immutable-reference route and rejects
companion mode; companion packaging may be introduced later only as an additive
schema revision. This does not create a blanket MPL allowlist.

The claim is therefore **best-effort inventory of known shipped components**,
not a complete SBOM, a legal-compliance guarantee, or proof about every byte.
Exact component-to-file claims apply only to catalogued managed components,
declared build inputs, target conditions, and reviewed path rules. Unmatched or
unclassified files produce bounded review warnings and evidence; they do not
cause the finalizer to invent universal byte ownership. Apache-2.0
redistribution keeps the root NOTICE limited to relevant notices; file-level
material and source provenance stay in the generated payload.

The product-tag source workflow selects each successful target archive from one
builder attempt and uploads the versioned archives and digest manifest as
immutable `upload-artifact@v4` artifacts with `retention-days: 30` and
`overwrite: false`. Artifact names are attempt-qualified and collision-free:
they include the source run id, the producer `run_attempt`, target, and artifact
kind. Each upload's returned artifact id is captured. The digest manifest binds
every archive as `{artifact_id, artifact_name, producer_run_attempt, target,
sha256}` in addition to the product tag and peeled tag commit SHA.

A failed builder may be rerun and produces a new attempt-qualified artifact;
an already-successful builder is not rerun merely to retry qualification. Once
an archive digest set has been admitted, qualification-only retries rerun only
the failed qualification job(s) and reuse the recorded archive artifact ids.
They never rebuild, overwrite, or silently substitute a previously admitted
target. Native archive upload is the builder's final effect after its target
smoke. On any later source-run attempt, a builder preflight queries that same
run's prior target artifacts and job-attempt conclusion: exactly one artifact
from a successful prior builder is verified and reused without invoking the
toolchain, no accepted artifact permits a build, and duplicate accepted target
artifacts fail closed. This makes even an accidental rerun-all qualification
attempt unable to manufacture a second successful archive.

M0.a3 uploads an attempt-qualified immutable container holding
`m0a3-evidence.json`. M0.c3 consumes its artifact id, adds the TUI/FV rows, and
uploads an attempt-qualified immutable container holding the final content-free
`qualification-evidence-manifest.json`. Each evidence document records its own
producer `run_attempt`; the final manifest binds the exact source archive and
M0.a3 artifact ids, names, attempts, and digests. Every evidence/manifest upload
also uses v4, `retention-days: 30`, and `overwrite: false`, and captures the v4
artifact id as a job output and in the content-free source-run summary. The
final container's id is necessarily bound by that upload output and the
promotion input rather than self-recorded inside its already-hashed payload;
promotion verifies its REST metadata against the source run, attempt, name,
and expected digest. The source run stops before signing or publication.

A separate protected `workflow_dispatch` promotion must run at the exact
product-tag ref while every selected native-archive artifact is unexpired and
no more than 21 days past its GitHub artifact `created_at`; later qualification
attempts do not reset that clock. Its immutable inputs are
`tag`, `source_run_id`, `source_run_attempt`, `digest_manifest_artifact_id`,
`digest_manifest_sha256`, `qualification_manifest_artifact_id`, and
`qualification_manifest_sha256`; `tag` must equal `GITHUB_REF_NAME`. Before any
artifact download or publication, the promotion queries GitHub's REST API and
authenticates the source run as all of:

- the same repository id and full name;
- the exact workflow id whose path is
  `.github/workflows/release-artifacts.yml`;
- event `push`, not `workflow_dispatch` or another manual/build source;
- successful conclusion and current `run_attempt` equal to the dispatched
  `source_run_attempt`;
- source `head_sha` equal to the recursively peeled immutable product-tag
  commit; and
- source ref evidence naming that exact product tag: the attempt-qualified
  source manifest records `github.ref == refs/tags/<tag>`,
  `github.ref_type == tag`, and `github.ref_name == <tag>`.

Any mismatch stops promotion. The promotion then downloads the explicitly
bound artifacts by artifact id, verifies every name/attempt/tag/SHA/digest and
per-target evidence binding, and rehashes the archives. It never selects an
artifact by a floating name or "latest" run.

The `release-promotion` environment is created and protected before the product
tag. Pretag release evidence records the successful responses (and response
digests) from
`GET /repos/{owner}/{repo}/environments/release-promotion` and
`GET /repos/{owner}/{repo}/environments/release-promotion/deployment-branch-policies`.
PASS requires a non-empty required-reviewer rule, custom deployment branch/tag
policies enabled, and a `type: tag` rule whose pattern matches the planned
product tag (for example, the reviewed `v*` policy). Absence, an API/read
failure, or GitHub's implicit creation of an unprotected environment blocks
tagging. At promotion time that environment gates the job before GitHub
allocates its runner or exposes environment secrets. Only after approval do
explicit `actions: read`, `contents: write`, and `id-token: write` permissions
permit download, signing, and publication. The promotion contains no build
job.

Publication is restartable without mutable replacement. Promotion resolves the
release by exact tag, creates it as a draft only when absent, and never deletes
or recreates an existing release. A different tag/target or incompatible
release state stops. The release remains draft until the complete asset set and
signature verify; a previously published exact-tag partial release may be
completed only under the same byte checks. Promotion never uses `--clobber`.
`SHA256SUMS` is deterministic: lowercase hex digest, two ASCII spaces, asset
name, and LF, sorted by asset-name bytes with no timestamp. For every archive,
versionless alias, and `SHA256SUMS` asset, an absent asset is uploaded, an
existing asset is downloaded and skipped only when its SHA-256 equals the
expected digest, and a differing existing asset stops the run. If the cosign
bundle is absent, promotion signs and uploads it; if it already exists,
promotion reuses it only after verifying it against the identical
`SHA256SUMS` bytes, GitHub's OIDC issuer, and the approved tag-ref promotion-
workflow identity. An invalid bundle or a bundle for different checksum bytes
stops the run instead of being regenerated over the existing name. Only after
that verification may promotion publish the draft and permit tap fill. The
release asset and installed archive must retain the qualified digest.

Failure handling preserves immutable tags and one-build evidence. An unchanged-
byte qualification retry within the window reuses the staged archive ids. A
source fix or any artifact-byte fix requires a new operator-authorized patch
tag; an existing tag is never moved. A repository/workflow/event/ref/SHA/
attempt/digest/evidence mismatch rejects promotion. Missing, older-than-window,
or expired staged artifacts stop for operator disposition and are never
silently rebuilt under an accepted digest set. The small license finalizer/
viewer remains best-effort inventory functionality inside the release build,
not a release-state service or legal-compliance subsystem.

## Amendment (v1.3 M9.a2, 2026-07-29) — qualify drafts before immutability

The tag-first hosted-build model above solved byte substitution but made the
first product-tag push irreversible before its own workflow and artifact
contracts had executed. Repeated pre-publication failures therefore consumed
`v1.2.1` through `v1.2.5` despite creating no GitHub Release. v1.3 changes the
boundary without weakening an accepted published release: **release
immutability begins when the draft is published, not when a provisional draft
tag is first created.**

GitHub immutable releases must be enabled and verified before this path cuts
over. While the release is a draft, its intended product tag, target SHA, and
assets are candidate state. An operator may discard the complete failed draft
generation and its provisional tag, then stage a complete replacement under
the same intended version. Partial in-place repair, `--clobber`, mixed
generations, and silent tag movement remain forbidden. Once protected
promotion publishes the draft, GitHub locks the release tag and assets; that
tag is never moved, deleted, or reused, and a later source/byte correction
requires a patch version.

Release construction moves to operator-controlled target environments:

- macOS arm64 builds natively on the operator Mac;
- Linux x64 builds and smokes in a pinned-digest native `linux/amd64`
  container on the `serenity` Linux host; and
- Linux arm64 builds and smokes from the same multi-architecture image digest
  in a native `linux/arm64` container on Apple Silicon Docker Desktop.

Docker Desktop runs the engine inside a Linux VM. On Apple Silicon an explicit
`--platform linux/arm64` container therefore executes Linux/aarch64 userspace
on the matching host architecture; it produces a Linux arm64 artifact, not a
macOS artifact. The builder must record `uname -s == Linux`,
`uname -m == aarch64`, the image name and digest, libc floor, native-NIF build
mode, and exact toolchain. The x64 path applies the symmetric
`Linux`/`x86_64` checks. It
must not substitute `linux/amd64` emulation: Docker documents Intel containers
on Apple Silicon as slower, more memory-intensive best effort. Builds use the
container filesystem and copy only final staged output across the bind mount,
avoiding host-filesystem modes or symlinks becoming build inputs.

One exact clean pushed SHA and candidate generation bind all three archives.
The existing final-artifact/license finalizer remains the last byte mutation;
the existing target smoke runs before upload. Draft release assets and a
content-free candidate manifest bind intended version, SHA, generation,
target, archive digest, release-asset ID/digest, exact toolchain, and builder
host class or container-image digest. No-build GitHub qualification downloads
only those explicitly bound assets, runs packaged license/protocol/provider
rows, and emits the final qualification manifest. The operator validates the
exact macOS artifact's TUI before approving promotion.

GitHub documents release-asset GETs as requiring only `contents: read`, but it
also limits draft-release visibility to identities with push access. The
workflow's target-qualification and evidence-composition jobs therefore need
job-local `contents: write` so their `GITHUB_TOKEN` can read the unpublished
draft. This is visibility authority, not mutation intent: the stateless
qualification helper uses only GET endpoints, checkout does not persist the
token, top-level permissions remain empty, and only protected promotion calls
release mutation endpoints.

Protected GitHub promotion remains the only signing/publication authority. It
rehashes the draft assets, verifies the candidate and qualification bindings,
creates deterministic checksums, signs through OIDC, uploads signatures, and
publishes the same draft without rebuilding. The cosign identity consequently
attests protected GitHub qualification/promotion of the recorded
operator-built bytes; it does not claim that GitHub-hosted runners compiled
them.

Implementation is subtractive. Reuse the finalizer, smoke harnesses, and
promotion verification; add at most one thin target-build helper and keep
SSH/Docker/draft lifecycle commands in the request flow. After one shadow
rehearsal, remove the hosted native-build matrix, successful-builder reuse
branches, and tag-first patch-recovery logic. Do not add self-hosted runners, a
release daemon, database, durable candidate service, or a second permanent
construction path.

As built, the thin helper rejects root execution because packaged Erlexec is
itself part of the smoke and correctly refuses root without an explicit target
user. Container preparation may run as root, but compilation, finalization,
and smoke switch to one unprivileged ephemeral user. Both Linux targets use
the Hex-maintained multi-architecture OTP 29.0.1 Debian 12 manifest
`hexpm/erlang@sha256:d8c7836b5b2b3b90918fb504b9eac563814503957875658528d9ab4581bf1e6b`
at its native platform. The helper requires and records glibc 2.36 and forces
Exqlite's supported source-build path so the bundled ERTS, Exqlite, Erlexec,
and other native payloads share one explicit builder floor. It also proves the
packaged OTP crypto NIF has exactly one `libcrypto.so.3` edge and records an
`OpenSSL 3.*` runtime value in both toolchain and smoke evidence. The earlier
Debian 11 candidate was rejected when no-build qualification showed its OTP
runtime linked `libcrypto.so.1.1`: builder-local smoke masked a dependency that
current Linux hosts do not provide. Bundling that library is forbidden because
OpenSSL 1.1.1 is upstream-EOL and uses the older dual license; Linux continues
to use the host's OpenSSL 3 rather than adding a second packaged crypto runtime
or license-management branch.

The same clean-host qualification exposed a different class of native edge:
OTP's socket NIF attempts to load `libsctp.so.1` dynamically when ERTS was built
with SCTP, so the dependency is absent from ordinary `ldd`/ELF `NEEDED` output.
When the library was absent, ERTS still exited successfully but wrote an
`=ESOCK` loader warning to stdout before `allbert licenses --json`, violating
the machine-readable CLI contract. Builder-local and Serenity packages had
masked the omission. Linux artifacts therefore own only Debian Bookworm
`libsctp1 1.0.19+dfsg-2`'s `libsctp.so.1.0.19` plus its `libsctp.so.1` link in
`native/lib`; the generated launcher prepends that directory only when it
exists. The existing final-artifact/license phase verifies the exact package
version, regular-file source, SONAME, destination bytes, target exclusion, LGPL
text, and immutable source/build provenance before sealing. This is one
catalogued late-loaded runtime edge, not a general dependency scanner or new
license-management branch. Artifact smoke must parse unfiltered license JSON
and clean-host qualification must pass without installing `libsctp` on the
qualifier.

A downloaded,
checksum-pinned Node 22 runtime and apt Chromium exist only for build/smoke;
the browser boundary proves neither enters the archive. The candidate row
records the image digest, libc floor, source-built-NIF policy, and resolved
Node, Playwright, and browser versions. Absolute host paths are not evidence
and are not recorded.
On macOS the finalizer gives the Exqlite NIF and bundled
`libcrypto.3.dylib` loader-relative install IDs, ad-hoc signs and re-verifies
them, and only then generates the package license manifest. The M9.a2 shadow
rehearsal against Homebrew 6 showed that a non-bottle formula still undergoes
Homebrew's unconditional `fix_dynamic_linkage` pass before `post_install`, even
when those IDs are already loader-relative. The formula therefore preserves
and restores exactly those two known manifest-managed Mach-O payloads after
relocation. Installed `allbert licenses --json` and byte comparison must pass.
This is a bounded packaging compatibility seam, not a runtime license manager,
generic manifest interpreter, or permission to restore arbitrary files.

Primary-source constraints for this amendment:

- Homebrew's formula installer runs `fix_dynamic_linkage` whenever the install
  is not a poured bottle, before the formula `post_install` hook; the current
  tap workflow uses `brew tap-new` rather than arbitrary local formula paths
  ([Homebrew installer source](https://github.com/Homebrew/brew/blob/e8cf16d0901fcdaafb531b22664fdef4d7ceca98/Library/Homebrew/formula_installer.rb#L995-L1007),
  [tap creation](https://docs.brew.sh/How-to-Create-and-Maintain-a-Tap)).
- Docker Desktop runs containers inside a Linux VM, and Docker recommends
  native arm64 images on Apple Silicon rather than best-effort Intel emulation
  ([Docker Desktop networking](https://docs.docker.com/desktop/features/networking/),
  [multi-platform builds](https://docs.docker.com/build/building/multi-platform/)).
- Hex's maintained Elixir/Erlang images encode exact language/runtime and OS
  versions, while Exqlite documents `force_build: true` as the supported way
  to opt out of precompiled NIFs
  ([Hex image tags](https://hub.docker.com/r/hexpm/erlang/tags),
  [Exqlite build configuration](https://github.com/elixir-sqlite/exqlite/blob/v0.39.0/README.md#configuration)).
- GitHub recommends creating a draft, attaching all assets, then publishing;
  when immutable releases are enabled, tag and asset immutability begins at
  publication while draft state remains editable. Only identities with push
  access receive draft releases from the releases API, while release-asset GET
  endpoints otherwise require `contents: read`
  ([immutable releases](https://docs.github.com/en/code-security/concepts/supply-chain-security/immutable-releases),
  [releases API](https://docs.github.com/en/rest/releases/releases),
  [release assets API](https://docs.github.com/en/rest/releases/assets)).

### Per-target toolchain evidence

Release builds pin exact OTP and Elixir versions and immutable full-SHA
third-party build actions, use strict version resolution, and record the
resolved tool/action versions, native linkage, and artifact hashes per target.
The final binary must runtime-smoke native capabilities such as the loaded
SQLite version and compile options. Equal logical tool versions across macOS
and Linux do **not** imply byte-identical artifacts.

Primary-source constraints:

- Mix releases copy application code plus `ebin`, `priv`, and `include`;
  dependency-root license files need explicit staging
  ([Mix release docs](https://mix.hexdocs.pm/Mix.Tasks.Release.html),
  [Elixir 1.19.5 source](https://github.com/elixir-lang/elixir/blob/v1.19.5/lib/mix/lib/mix/release.ex)).
- Exact setup-beam versions with strict matching are the supported pinning
  posture, and a full commit SHA is the immutable Actions reference
  ([setup-beam](https://github.com/erlef/setup-beam#input-versioning),
  [GitHub Actions secure use](https://docs.github.com/en/actions/reference/security/secure-use)).
- `upload-artifact@v4` artifacts are immutable, a repeated name fails unless
  replacement is explicitly requested, and the action exposes the immutable
  artifact id; cross-run downloads require an explicit token and run id
  ([upload-artifact](https://github.com/actions/upload-artifact),
  [download-artifact](https://github.com/actions/download-artifact#download-artifacts-from-other-workflow-runs-or-repositories)).
- A rerun retains the workflow run id, ref, and SHA while incrementing the run
  attempt, and the Actions REST record exposes the source workflow/event/SHA/
  conclusion metadata that promotion authenticates
  ([rerun behavior](https://docs.github.com/en/actions/how-tos/manage-workflow-runs/re-run-workflows-and-jobs),
  [workflow-run REST API](https://docs.github.com/en/rest/actions/workflow-runs#get-a-workflow-run)).
- GitHub release assets can be listed and downloaded for byte comparison, while
  `gh release upload --clobber` explicitly replaces an existing asset; cosign
  bundle verification binds checksum bytes to the expected OIDC identity
  ([release-assets REST API](https://docs.github.com/en/rest/releases/assets),
  [`gh release upload`](https://cli.github.com/manual/gh_release_upload),
  [cosign blob verification](https://docs.sigstore.dev/cosign/verifying/verify_blob/)).
- GitHub Actions environments may require approval before a job starts, which
  supplies the qualification/promotion pause; environment and deployment-
  policy REST endpoints expose the pretag reviewer/tag-policy evidence
  ([deployment environments](https://docs.github.com/en/actions/concepts/workflows-and-actions/deployment-environments),
  [environment REST API](https://docs.github.com/en/rest/deployments/environments#get-an-environment),
  [branch-policy REST API](https://docs.github.com/en/rest/deployments/branch-policies#list-deployment-branch-policies)).
- OpenSSL 3.0+ is Apache-2.0 while earlier releases use the historical dual
  license, so classification is target/version-specific
  ([OpenSSL licensing](https://openssl-library.org/source/license/index.html)).
- OpenSSL 1.1.1 reached public end of life on 11 September 2023; the rejected
  Bullseye-linked runtime therefore must not be made portable by bundling it
  ([OpenSSL 1.1.1 EOL](https://mirror.openssl-library.org/post/2023-03-28-1.1.1-eol/)).
- Erlang/OTP recommends an up-to-date OpenSSL and exposes `--with-ssl` plus
  `--disable-dynamic-ssl-lib` when a custom/static crypto runtime is
  intentionally required. v1.3 does not add that second build path; it selects
  the pinned OpenSSL-3-linked image and verifies the resulting edge instead
  ([OTP secure coding](https://github.com/erlang/otp/blob/master/system/doc/design_principles/secure_coding.md)).
- OTP's Unix socket implementation dynamically loads SCTP support and emits the
  warning at that boundary
  ([OTP source](https://github.com/erlang/otp/blob/OTP-29.0.1/erts/emulator/nifs/unix/unix_socket_syncio.c));
  Debian Bookworm supplies the copied library from `lksctp-tools
  1.0.19+dfsg-2`, whose `src/lib/*` scope is LGPL-2.1-or-later
  ([Debian source package](https://packages.debian.org/bookworm/source/lksctp-tools),
  [Debian copyright](https://sources.debian.org/copyright/license/lksctp-tools/1.0.19%2Bdfsg-2/)).
- SQLite deliverable code is public domain; Mozilla-derived CA PEM data is
  MPL-2.0; and IANA tzdb has named BSD-3-Clause exceptions
  ([SQLite](https://www.sqlite.org/copyright.html),
  [curl CA extract](https://curl.se/docs/caextract.html),
  [MPL 2.0](https://www.mozilla.org/en-US/MPL/2.0/),
  [IANA tzdb license](https://data.iana.org/time-zones/tzdb/LICENSE)).

## Amendment (v1.4 M14, 2026-08-13) — `macos-x64` is non-blocking compatibility

The M0/S2 sign-off obligation above — "explicitly promote `macos-x64` or record
it as non-blocking compatibility" — was never discharged in writing. The
decision was taken in practice and not recorded, which is the shape M14 exists
to catch.

**Operator decision 2026-08-13: `macos-x64` is recorded as non-blocking
compatibility.** It is not promoted to a freeze-blocking target.

The evidence is the shipped matrix rather than an intention. Every artifact path
names exactly three triples — `macos-arm64`, `linux-x64`, `linux-arm64` — in the
release build script, the qualification matrix, and the Homebrew formula's three
`url`/`sha256` pairs. No `macos-x64` asset has ever been built, signed,
qualified, or published, from v0.62 through v1.3. Intel Macs remain served by
the `macos-arm64` build under Rosetta 2, which is the same posture the tap and
the curl installer have carried since v0.62.

This closes the obligation rather than restating it. Promoting `macos-x64` later
is a packaging workstream in its own right — a target to build, smoke, sign,
qualify, and add to the formula — and would need its own milestone under a
release that intends it.
