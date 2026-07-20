# Release & Install Rehearsal (packaged releases)

This is the operator runbook for cutting a packaged Allbert release and
validating the packaged `allbert` on Tier-1 OS paths before announcing it.
Two automated layers precede the manual/operator layer: the permanent 1.x public-
contract gate (`mix allbert.test release.v1`) plus the active plan's point-release gate
(for example `mix allbert.test release.v101`), and the CI artifact smoke. This doc
covers the steps that need a published release, a package manager, a TTY, Docker,
or real host services.

v0.62 introduced the packaged release path; v0.64.3 established the trusted-install/
first-run substrate and v0.65.0 the local-knowledge launch path that later lines build
on (see the [CHANGELOG](../../CHANGELOG.md) and [roadmap](../plans/roadmap.md) for the
current packaged release line). This runbook
covers Homebrew tap fill, package-manager install, curl trust, packaged TUI, and Linux
rehearsal evidence for the packaged path.
Binary release is the post-1.0 default. `[skip-artifacts]` remains only for an
explicitly approved docs/source point tag that is not a product release; it does not
replace the binary-release obligation of a versioned feature plan.

Set this once from the release checkout; every active command below consumes it:

```sh
export VERSION="${VERSION:?set VERSION, for example v1.0.3}"
export EXPECTED_VERSION="${VERSION#v}"
export REPO="${REPO:-lexlapax/allbert-assist}"
export EVIDENCE_ROOT="${EVIDENCE_ROOT:-$(mktemp -d /tmp/allbert-release-evidence.XXXXXX)}"
export ALLBERT_HOME="${ALLBERT_HOME:-$(mktemp -d /tmp/allbert-release-home.XXXXXX)}"
```

## 1. Publish the release

For every 1.x product release, the tag is operator-held. Push the reviewed release
commit, prove branch parity, then cut the annotated tag on that exact commit:

```sh
git push origin main
HEAD_SHA="$(git rev-parse HEAD)"
REMOTE_SHA="$(git ls-remote origin refs/heads/main | awk '{print $1}')"
test "$HEAD_SHA" = "$REMOTE_SHA"
git tag -a "$VERSION" -m "Allbert ${VERSION#v}"
git push origin "$VERSION"
TAG_SHA="$(git rev-parse "$VERSION^{}")"
REMOTE_TAG_SHA="$(git ls-remote origin "refs/tags/$VERSION^{}" | awk '{print $1}')"
test "$HEAD_SHA" = "$TAG_SHA"
test "$TAG_SHA" = "$REMOTE_TAG_SHA"
echo "PASS: HEAD, origin/main, and peeled $VERSION tag agree"
```

The tag push fires `.github/workflows/release-artifacts.yml`:

- **gate**: reads the annotated tag message. A **product-release** tag (no marker)
  proceeds to build + publish. A **docs/source point-release** tag whose message
  contains `[skip-artifacts]` short-circuits here — build/publish are skipped so no
  packaged GitHub Release is created and GitHub "Latest" is not moved.
- **build** (macos-arm64, linux-x64, linux-arm64): builds the OTP release and runs
  `scripts/smoke/artifact_smoke.sh` per target - boot, version, plugin
  registration, `/health`, a genuine attach round-trip, no-Mix-modules, and ERTS
  crypto linkage, all through an operator-style symlink.
- **publish** (tag only, gated on the Linux rehearsal): collects the per-target
  tarballs, adds version-less aliases (`allbert-<target>.tar.gz` for the `latest`
  install path), writes `SHA256SUMS`, creates the release (`--prerelease` for a
  hyphen tag such as `v0.62.0-rc1`) plus the mandatory
  `SHA256SUMS.cosign.bundle`, and uploads everything to the GitHub release.

### Exceptional docs/source point tag (no packaged artifacts)

An explicitly approved point tag that ships only source/docs/script fixes must
NOT create packaged artifacts or steal `Latest` from the product release that owns the
tarballs + `latest` aliases. Mark its annotated tag `[skip-artifacts]` so
the `gate` job skips the packaged pipeline:

```sh
DOC_VERSION="${DOC_VERSION:?set the exceptional docs/source tag}"
PACKAGED_VERSION="${PACKAGED_VERSION:?set the current packaged release tag}"
git tag -a "$DOC_VERSION" -m "Allbert ${DOC_VERSION#v} - release-doc closeout [skip-artifacts]"
git push origin "$DOC_VERSION"
# Verify: no DOC_VERSION release exists and PACKAGED_VERSION stays Latest.
test "$(gh release view --repo "$REPO" --json tagName --jq .tagName)" = "$PACKAGED_VERSION"
if gh release view "$DOC_VERSION" --repo "$REPO"; then exit 1; fi
```

Verify release and tag state after publish:

```sh
gh release view "$PACKAGED_VERSION" --repo "$REPO" \
  --json tagName,publishedAt,url
git ls-remote --tags origin "$DOC_VERSION" "$PACKAGED_VERSION"
git rev-parse "$PACKAGED_VERSION^{}"
```

**Trust model note.** v0.62/v0.63 used SHA256 verification over the same HTTPS release
origin, with `SHA256SUMS.cosign.bundle` available only for out-of-band verification.
v0.64 changes the curl installer path: `install.sh` now requires `cosign`, verifies the
signed checksum bundle against the GitHub Actions workflow identity, and refuses to
install if signature verification cannot complete. The Homebrew path remains a
package-manager path: the trusted tap formula pins release URLs and SHA256 values, and
Homebrew verifies the artifact against those formula values. To verify a release by hand:

```sh
mkdir -p "/tmp/allbert-${VERSION}"
gh release download "$VERSION" --repo "$REPO" \
  --pattern 'SHA256SUMS*' --dir "/tmp/allbert-${VERSION}"
cosign verify-blob --bundle "/tmp/allbert-${VERSION}/SHA256SUMS.cosign.bundle" \
  "/tmp/allbert-${VERSION}/SHA256SUMS" \
  --certificate-identity-regexp 'https://github.com/lexlapax/allbert-assist/.github/workflows/release-artifacts.yml@refs/tags/.*' \
  --certificate-oidc-issuer 'https://token.actions.githubusercontent.com'
```

You can dry-run build+smoke without publishing:

```sh
gh workflow run release-artifacts.yml --ref main
gh run watch
```

## 2. Fill The Homebrew Tap

The tap lives at [`lexlapax/homebrew-allbert`](https://github.com/lexlapax/homebrew-allbert)
(`Formula/allbert.rb`). Fill the formula from the published release, not by hand. The
helper updates version, per-target URLs, and SHA256 rows together:

```sh
ALLBERT_ASSIST_CHECKOUT="${ALLBERT_ASSIST_CHECKOUT:-$(pwd)}"  # run from allbert-assist checkout
TAP_CHECKOUT="$(mktemp -d /tmp/homebrew-allbert.XXXXXX)"
mkdir -p "/tmp/allbert-${VERSION}"
gh release download "$VERSION" --repo "$REPO" \
  --pattern SHA256SUMS --dir "/tmp/allbert-${VERSION}"
git clone https://github.com/lexlapax/homebrew-allbert "$TAP_CHECKOUT"
sh "$ALLBERT_ASSIST_CHECKOUT/homebrew/fill-sha256.sh" \
  "/tmp/allbert-${VERSION}/SHA256SUMS" \
  "$TAP_CHECKOUT/Formula/allbert.rb"
```

Audit and publish from the tap checkout:

```sh
cd "$TAP_CHECKOUT"
git diff -- Formula/allbert.rb
rg -n 'PLACEHOLDER|TODO|sha256' Formula/allbert.rb
brew tap lexlapax/allbert "$TAP_CHECKOUT" --custom-remote
brew trust --formula lexlapax/allbert/allbert
brew audit --strict --online --formula allbert
git add Formula/allbert.rb
git commit -m "allbert ${VERSION#v}"
git push origin main
```

Evidence to record: tap commit hash, audit output, `brew info lexlapax/allbert/allbert`
showing the current version, the three formula SHA256 rows, and confirmation that no
placeholder checksum or old release URL remains.

Homebrew 6 note: path-based `brew audit [path ...]` is disabled, and untrusted
third-party taps are refused. Audit by tapped formula name after trusting the tap.

## 3. Per-OS Install Rehearsal

Do this on each Tier-1 OS path that is in scope. Install/uninstall must not touch
the operator's real Allbert Home (`~/.allbert`) unless `--purge` is explicitly
requested; set a disposable `ALLBERT_HOME` for rehearsal.

For v1.0.3 catch-up, the required ledger is macOS; linux-x64 and linux-arm64
container artifacts; a real-host Linux service/vault row (PASS or
policy-owned SKIP); and WSL2 using the Linux tarball (PASS or operator-owned
SKIP). Record CI run id, tag/release URL, asset inventory, cosign transcript,
tap commit/audit, install transcript, TUI, channel-send, ACP, browser,
service/vault, and preserved-Home uninstall evidence under `EVIDENCE_ROOT`.

### Windows / WSL2 Tier-2 catch-up (v1.0.3)

Inside WSL2, use a disposable Home and install the published linux-x64
tarball through the same verified installer path:

```sh
export VERSION="${VERSION:-v1.0.3}"
export EXPECTED_VERSION="${VERSION#v}"
export ALLBERT_HOME="$(mktemp -d /tmp/allbert-wsl2-home.XXXXXX)"
export ALLBERT_VERSION="$VERSION"
curl -fsSL https://raw.githubusercontent.com/lexlapax/allbert-assist/main/scripts/install/install.sh | sh
export PATH="$HOME/.local/bin:$PATH"
test "$(allbert --version)" = "allbert $EXPECTED_VERSION"
allbert admin status
allbert admin vault
```

Then attest first chat against a real configured local model, one warm TUI
session, and service install/status/uninstall basics. PASS requires the
published Linux artifact, not a source checkout. A SKIP requires an owner,
policy reason, and follow-up location; absence of a WSL2 host is not silently
treated as PASS.

### curl installer (macOS + Linux)

```sh
export ALLBERT_VERSION="$VERSION"
curl -fsSL https://raw.githubusercontent.com/lexlapax/allbert-assist/main/scripts/install/install.sh | sh
#   omit ALLBERT_VERSION to exercise the latest alias
#   ALLBERT_PREFIX=~/.local   install prefix
export PATH="$HOME/.local/bin:$PATH"
test "$(allbert --version)" = "allbert $EXPECTED_VERSION"
allbert admin status              # renders operator status through the spine
```

### Homebrew (macOS + Linux)

```sh
brew tap lexlapax/allbert
brew trust --formula lexlapax/allbert/allbert   # if Homebrew requires tap trust
brew install lexlapax/allbert/allbert
test "$(allbert --version)" = "allbert $EXPECTED_VERSION"
allbert admin status
brew test allbert
```

Before the tap commit is pushed, validate the local formula path instead:

```sh
brew install "$TAP_CHECKOUT/Formula/allbert.rb"
```

### serve + health + attach

```sh
allbert serve &
ALLBERT_DAEMON_PID=$!
trap 'kill "$ALLBERT_DAEMON_PID" 2>/dev/null || true' EXIT INT TERM
curl -fsS http://localhost:4000/health
allbert admin status              # attaches to the running daemon; no second writer
kill "$ALLBERT_DAEMON_PID"
trap - EXIT INT TERM
```

Attach and health checks require host socket/port access. If running inside a
filesystem/network sandbox, rerun this block outside that sandbox before judging
the release; an attach-listener `:eperm` is a validation-environment failure, not
a product pass.

### service (launchd / systemd, confirmation-gated)

```sh
allbert admin service install --dry-run           # preview exact launchctl/systemctl commands
allbert admin service install                     # -> needs_confirmation
allbert admin confirmations approve <ID>          # installs the per-user service
# macOS: ~/Library/LaunchAgents/...; Linux: systemctl --user (linger for boot-start)
allbert admin service uninstall                   # confirmation-gated; removes the unit
```

### v0.64+ readiness overlay

For v0.64 and later rehearsals, the primary non-developer path starts with the
persistent service and browser workspace, not foreground `allbert serve`.
Foreground `serve` remains a diagnostic fallback. The rehearsal must additionally
prove:

- installer-side cosign verification succeeds before artifact install;
- missing verifier tooling follows the guided verifier setup path and still
  fails closed if verification cannot complete;
- Homebrew resolves to the current release formula, not an older tap commit, and
  `brew test allbert` passes;
- concurrent fresh-Home first commands serialize startup migration and avoid raw
  duplicate-table migration errors;
- consumer-default onboarding guides local runtime setup if needed, then pulls
  the curated local model with web-visible progress;
- the operator never has to run the `ollama` CLI or provide an API key on the
  consumer-default path.

### secret vault (macOS Keychain / Linux Secret Service)

```sh
allbert admin vault                               # shows the resolved tier
# On macOS the OS Keychain tier needs NO settings master key (v0.63 M8.3):
allbert admin settings providers set-key openai   # stores in the Keychain, writes the api_key_ref
allbert admin settings providers list             # confirm the provider shows configured
# Migrating pre-existing encrypted-store keys into the OS vault stays confirmation-gated:
allbert admin secrets migrate                     # -> needs_confirmation
allbert admin confirmations approve <ID>          # moves encrypted-store secrets into the OS vault
```

Headless Linux without a D-Bus keyring resolves to the encrypted-file tier with a
surfaced notice (that tier needs `ALLBERT_SETTINGS_MASTER_KEY` in a packaged prod
release); see [security-hardening.md](security-hardening.md).

### v0.63 M8.8 — bare/first-run + hosted-doctor through the packaged `eval` path

These two paths were unexercised before v0.63 M8.8 and let the packaged `unknown
registry: Req.Finch` (M8.1) and castore/CA (M8.2) blockers reach an operator. The Linux
rehearsal script now covers them (steps `first-run-eval`, `castore-bundled`,
`hosted-doctor-eval`); rehearse the same on macOS:

```sh
# Bare / first-run command through the eval dispatch (no daemon): with a completed-
# onboarding Home this runs the localhost first-model probe — it must NOT crash with
# `unknown registry: Req.Finch`.
allbert                                           # or any pure command; expect no Req.Finch crash

# The release bundles a CA trust store (offline-safe fallback):
ls "$REL_ROOT"/lib/castore-*/priv/cacerts.pem     # must exist

# Hosted-provider doctor must not raise the castore/CA-trust error; SSL_CERT_FILE is
# honored. A 401/403 (no key) still proves TLS/CA succeeded.
allbert admin models doctor openai                # expect no "castore"/"default CA trust store" error
SSL_CERT_FILE=/etc/ssl/cert.pem allbert admin models doctor openai   # override lever works
```

### uninstall (Home preserved)

```sh
sh scripts/install/uninstall.sh                   # removes installed files; Allbert Home preserved
sh scripts/install/uninstall.sh --purge           # also removes Allbert Home
brew uninstall allbert                            # if installed via Homebrew
test -d "$ALLBERT_HOME"                           # expected unless --purge was used
```

## 4. Packaged TUI Rehearsal

The TUI proof must run from the packaged binary (`allbert tui`), not from
`mix allbert.tui`.

```sh
export ALLBERT_HOME="$(mktemp -d /tmp/allbert-release-tui.XXXXXX)"
allbert admin settings set channels.tui.identity_map \
  '[{"external_user_id":"default","user_id":"local","enabled":true}]'
allbert admin settings set channels.tui.enabled true
script "$EVIDENCE_ROOT/${VERSION}-tui-transcript.txt" allbert tui
```

Inside the session:

```text
/help
/status
/channels
/settings get channels.tui.enabled
/quit
```

Record the redacted transcript path and whether every slash read rendered
in-session without using cold Mix inspection tasks.

## 5. Docker Linux Package Rehearsals

Docker package rehearsals are **containerized package smokes**, not complete
real-host Linux validation. They prove Linux artifact unpack/install/startup,
health, attach, and uninstall behavior. Mark Secret Service and user systemd rows
PASS only when those services are actually present and exercised inside the
container; otherwise mark SKIP with the reason. Install container prerequisites
as root, but run `scripts/smoke/linux_rehearsal.sh` as a non-root user: the
packaged runtime uses `erlexec`, which refuses root startup without an explicit
effective user.

Start/check Docker Desktop before running the containers:

```sh
docker desktop status || docker desktop start
docker info
```

Prepare the Linux artifacts:

```sh
ALLBERT_ASSIST_CHECKOUT="${ALLBERT_ASSIST_CHECKOUT:-$(pwd)}"  # run from allbert-assist checkout
WORK="/tmp/allbert-${VERSION}"
mkdir -p "$WORK/artifacts"
gh release download "$VERSION" --repo "$REPO" \
  --pattern "allbert-${VERSION}-linux-*.tar.gz" \
  --pattern SHA256SUMS \
  --dir "$WORK/artifacts"
```

Run both Linux targets:

```sh
docker run --rm --platform linux/arm64 \
  --mount type=bind,source="$WORK",target=/work,readonly \
  --mount type=bind,source="$ALLBERT_ASSIST_CHECKOUT",target=/repo,readonly \
  --env VERSION="$VERSION" \
  --workdir /tmp \
  ubuntu:22.04 \
  bash -lc 'set -euo pipefail
    apt-get update
    apt-get install -y ca-certificates curl tar gzip libstdc++6 openssl
    useradd -m -u 1000 allbert
    mkdir -p /tmp/rehearsal
    cp -R /work/artifacts /tmp/rehearsal/artifacts
    chown -R allbert:allbert /tmp/rehearsal
    su -s /bin/bash allbert -c "set -euo pipefail
    cd /tmp/rehearsal
    export LANG=C.UTF-8 LC_ALL=C.UTF-8
    (cd artifacts && sha256sum -c SHA256SUMS --ignore-missing)
    mkdir -p extract-arm64
    tar -xzf artifacts/allbert-${VERSION}-linux-arm64.tar.gz -C extract-arm64
    /repo/scripts/smoke/linux_rehearsal.sh /tmp/rehearsal/extract-arm64/allbert"'

docker run --rm --platform linux/amd64 \
  --mount type=bind,source="$WORK",target=/work,readonly \
  --mount type=bind,source="$ALLBERT_ASSIST_CHECKOUT",target=/repo,readonly \
  --env VERSION="$VERSION" \
  --workdir /tmp \
  ubuntu:22.04 \
  bash -lc 'set -euo pipefail
    apt-get update
    apt-get install -y ca-certificates curl tar gzip libstdc++6 openssl
    useradd -m -u 1000 allbert
    mkdir -p /tmp/rehearsal
    cp -R /work/artifacts /tmp/rehearsal/artifacts
    chown -R allbert:allbert /tmp/rehearsal
    su -s /bin/bash allbert -c "set -euo pipefail
    cd /tmp/rehearsal
    export LANG=C.UTF-8 LC_ALL=C.UTF-8 ERL_AFLAGS=\"+JMsingle true\"
    (cd artifacts && sha256sum -c SHA256SUMS --ignore-missing)
    mkdir -p extract-x64
    tar -xzf artifacts/allbert-${VERSION}-linux-x64.tar.gz -C extract-x64
    /repo/scripts/smoke/linux_rehearsal.sh /tmp/rehearsal/extract-x64/allbert"'
```

On Apple Silicon Docker Desktop, the `linux/amd64` rehearsal runs under
emulation. Use `ERL_AFLAGS="+JMsingle true"` there so the x64 BEAM JIT uses a
single mapped executable memory region. Omit that flag for native x64 Linux
hosts unless the local emulator requires it. If Docker Hub credential helpers
hang or fail while pulling public Ubuntu images, rerun the rehearsal with a
throwaway Docker client config such as
`DOCKER_CONFIG="$(mktemp -d /tmp/allbert-docker-config.XXXXXX)"`.

If `scripts/smoke/linux_rehearsal.sh` needs to be bypassed for diagnosis, run the
equivalent manual checks inside the container and record the commands: checksum
verification, tar extraction, symlink/install, `allbert --version`,
`allbert admin status`, `allbert serve`, `/health`, attach, uninstall, and
Allbert Home preservation.

## 6. Evidence Ledger

Use one ledger for the release rather than splitting proof across terminal
scrollback:

Store transcripts and downloaded metadata under `$EVIDENCE_ROOT`. Every row
records owner, release commit/tag, CI run URL/id or host/architecture, exact
artifact checksum, command/transcript path, outcome, redaction review, and any
policy-accepted SKIP reason. A current 1.x binary release requires: CI artifact
matrix PASS for macOS arm64, Linux x64, and Linux arm64; local macOS
package-manager/TUI/browser PASS; both Linux container artifacts PASS; and the
real-host Linux service/vault row explicitly PASS or explicitly SKIP under the
active release plan. Uninstall evidence must prove the disposable Allbert Home
and representative data remain without `--purge`.

| Evidence class | What it proves | Typical command/source | Owner |
| --- | --- | --- | --- |
| Source gate | frozen 1.0 contracts and release-specific checks pass on the release commit | `mix allbert.test release.v1` + active point gate (for example `release.v101`) | current line |
| Artifact matrix | published artifacts boot and pass binary smoke | `.github/workflows/release-artifacts.yml` | current line |
| Tap fill | formula version, URLs, and checksums match release checksums | `homebrew/fill-sha256.sh`; `brew audit --strict --online --formula` | current packaged line |
| Package-manager install | package installs and invokes packaged binary | `brew install`; `brew test`; uninstall | current line |
| Packaged TUI | installed binary runs the warm console in a TTY | `script ... allbert tui` | current line |
| Docker Linux package smoke | both Linux artifacts install/start/attach/uninstall in containers | `docker run --platform linux/arm64`; `docker run --platform linux/amd64` | current line |
| Real-host service/vault | launchd/systemd and OS keychain integration on actual hosts | host service/vault commands | operator closeout |

Also record the cosign verification transcript, GitHub Release asset listing,
Homebrew tap commit/audit, packaged channel-send trace, ACP transcript, and
browser-research transcript/screenshot references when the active release owns
those surfaces.

## 7. Historical v0.62 Evidence

- **Historical CI artifact matrix** (`release-artifacts.yml`, run
  `28806671962`, commit `e200eaff`, 2026-07-06): macos-arm64, linux-x64,
  linux-arm64 build + smoke green (7/7 checks each, through the operator-style
  symlink). Job ids: linux-x64 `85423862478`, linux-arm64 `85423862494`,
  macos-arm64 `85423862527`.
- **Historical CI Linux rehearsal** (`linux-rehearsal` job `85424584885`,
  ubuntu-22.04, same run): install (symlink) -> `--version` / `admin status` /
  `/health` / attach served by the daemon -> Secret Service vault ->
  systemd `--user` dry-run -> uninstall with Home preserved.
- **macOS local rehearsal (2026-07-06, macos-arm64):** `install.sh` checksum
  verified; symlinked `allbert --version`, `admin status`, and `admin vault`
  passed with Keychain `os` tier; `allbert serve` exposed `/health status:ok`;
  attach round-trip was served by the running daemon; `admin secrets migrate` was
  confirmation-gated; service install dry-run previewed without executing;
  uninstall removed the binary and preserved Allbert Home. This rehearsal caught
  and fixed a real symlink-resolution bug in the dispatcher (M8.12).

These records remain useful history, but future closeout should use the ledger
above and record current release ids, commits, and evidence paths.

## 8. Remaining Operator Follow-Ups

- Fill/push the Homebrew tap for the current release and record tap audit/install/test
  evidence.
- Run the packaged TUI transcript.
- Run both Docker Linux package rehearsals (`linux-arm64` and `linux-x64`).
- Run a real-host Linux service/vault rehearsal when a suitable host is
  available; Docker skips for Secret Service or user systemd are not equivalent
  to a real-host PASS.
- Run the full secret-migrate -> Keychain/Secret-Service round-trip with a real
  settings master key configured (`ALLBERT_SETTINGS_MASTER_KEY`, valid format).
