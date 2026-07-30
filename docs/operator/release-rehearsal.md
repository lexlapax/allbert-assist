# Release & Install Rehearsal (packaged releases)

This is a release-maintainer runbook, not a first-run guide. Operators trying
Allbert should use [Quickstart: Install, Open, Chat](quickstart.md). The active
release request flow remains authoritative when its commands differ from this
cross-release reference.

This is the operator runbook for cutting a packaged Allbert release and
validating the packaged `allbert` on Tier-1 OS paths before announcing it.
The active release plan controls gate timing. Versioned gate definitions preserve
the permanent 1.x public-contract prefix, but a plan may prove that composition
structurally and defer aggregate execution; the v1.3 train does so until its final
M9.b rejoin. CI artifact smoke and exact-artifact qualification remain separate
from source gates. This doc covers the steps that need a protected environment,
native artifact, package manager, TTY, Docker, or real host service.

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
export VERSION="${VERSION:?set VERSION, for example v1.2.0}"
export EXPECTED_VERSION="${EXPECTED_VERSION:?set product version, for example 1.2.0}"
export REPO="${REPO:-lexlapax/allbert-assist}"
export PLAYWRIGHT_VERSION="${PLAYWRIGHT_VERSION:-1.58.2}"
export EVIDENCE_ROOT="${EVIDENCE_ROOT:-$(mktemp -d /tmp/allbert-release-evidence.XXXXXX)}"
export ALLBERT_HOME="${ALLBERT_HOME:-$(mktemp -d /tmp/allbert-release-home.XXXXXX)}"
```

## 1. Stage, qualify, and promote the release

### One-time protected-promotion setup

Before any product tag, `release-promotion` must already exist with at least one
required reviewer and a custom product-tag policy. Merely naming an absent
environment in workflow YAML auto-creates an unprotected environment and is a
release blocker. An administrator performs this setup once (or updates the
reviewer deliberately):

```sh
export RELEASE_REVIEWER_LOGIN="${RELEASE_REVIEWER_LOGIN:?set the required GitHub reviewer}"
REVIEWER_ID="$(gh api "users/$RELEASE_REVIEWER_LOGIN" --jq .id)"
jq -n --argjson reviewer_id "$REVIEWER_ID" '{
  wait_timer: 0,
  prevent_self_review: false,
  reviewers: [{type: "User", id: $reviewer_id}],
  deployment_branch_policy: {
    protected_branches: false,
    custom_branch_policies: true
  }
}' > "$EVIDENCE_ROOT/release-promotion-request.json"
gh api --method PUT \
  -H 'X-GitHub-Api-Version: 2026-03-10' \
  "repos/$REPO/environments/release-promotion" \
  --input "$EVIDENCE_ROOT/release-promotion-request.json"
if ! gh api -H 'X-GitHub-Api-Version: 2026-03-10' \
  "repos/$REPO/environments/release-promotion/deployment-branch-policies" \
  --jq '.branch_policies[] | select(.type == "tag" and .name == "v*")' \
  | grep -q .; then
  gh api --method POST \
    -H 'X-GitHub-Api-Version: 2026-03-10' \
    "repos/$REPO/environments/release-promotion/deployment-branch-policies" \
    -f name='v*' -f type='tag'
fi
```

Capture the read-only pretag proof every release:

```sh
gh api -H 'X-GitHub-Api-Version: 2026-03-10' \
  "repos/$REPO/environments/release-promotion" \
  > "$EVIDENCE_ROOT/release-promotion-environment.json"
gh api -H 'X-GitHub-Api-Version: 2026-03-10' \
  "repos/$REPO/environments/release-promotion/deployment-branch-policies" \
  > "$EVIDENCE_ROOT/release-promotion-tag-policies.json"
if command -v sha256sum >/dev/null 2>&1; then
  sha256sum \
    "$EVIDENCE_ROOT/release-promotion-environment.json" \
    "$EVIDENCE_ROOT/release-promotion-tag-policies.json"
else
  shasum -a 256 \
    "$EVIDENCE_ROOT/release-promotion-environment.json" \
    "$EVIDENCE_ROOT/release-promotion-tag-policies.json"
fi > "$EVIDENCE_ROOT/release-promotion-responses.sha256"
test "$(wc -l < "$EVIDENCE_ROOT/release-promotion-responses.sha256" | tr -d ' ')" -eq 2
jq -e '
  any(.protection_rules[]; .type == "required_reviewers" and
    (.reviewers | length) > 0) and
  .deployment_branch_policy.custom_branch_policies == true
' "$EVIDENCE_ROOT/release-promotion-environment.json" >/dev/null
jq -e 'any(.branch_policies[]; .type == "tag" and .name == "v*")' \
  "$EVIDENCE_ROOT/release-promotion-tag-policies.json" >/dev/null
echo 'PASS: release-promotion has a required reviewer, v* tag policy, and response digests'
```

An API/authentication failure, empty reviewer set, absent tag rule, or implicit
unprotected environment is FAIL. Do not create the tag.

### Immutable source tag and staging

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
  proceeds to build + stage. A **docs/source point-release** tag whose message
  contains `[skip-artifacts]` short-circuits here — build/staging are skipped so
  no packaged GitHub Release is created and GitHub "Latest" is not moved.
- **build** (macos-arm64, linux-x64, linux-arm64): builds the OTP release and runs
  `scripts/smoke/artifact_smoke.sh` per target - boot, version, plugin
  registration, `/health`, a genuine attach round-trip, no-Mix-modules, and ERTS
  crypto linkage, all through an operator-style symlink. Exact BEAM inputs are
  recorded per target. A rerun reuses one prior successful immutable archive;
  missing, expired, or duplicate successful producer evidence stops instead of
  rebuilding that tag.
- **linux-rehearsal**: consumes the accepted Linux x64 artifact by numeric ID and
  exercises the checksum-bound preverified install layout without OIDC/signing.
- **stage-digest-manifest**: collects numeric artifact IDs, upload-container and
  inner archive digests, producer attempts, target toolchains, tag/ref, and source
  SHA into an immutable attempt-qualified manifest. The source graph has no
  signing or publication permission.
- **M0.a3/M0.c3 qualification jobs**: consume
  those same IDs and bytes without building, then upload the final immutable
  qualification manifest. These job definitions must be committed before the
  tag; a rerun cannot acquire jobs missing from the tagged workflow.

The source run ends before publication. Record its exact ID, latest successful
attempt, and the digest/qualification artifact IDs plus upload SHA-256 values
from its content-free summaries. Then dispatch the **same workflow at the exact
tag ref**, supplying all seven bindings:

> **HARD STOP — operator TUI sign-off.** Before dispatching promotion or
> approving its protected environment, the operator must personally complete
> the exact-artifact command sequence in [§4](#4-packaged-tui-rehearsal) and
> return to this point. Automated PTY/CI evidence does not replace seeing the
> packaged client attach and work. Do not continue unless the content-free
> operator receipt exists and these bindings still match the selected artifact:

```sh
: "${V121_TUI_OPERATOR_RECEIPT:?complete section 4 operator TUI validation first}"
test -f "$V121_TUI_OPERATOR_RECEIPT"
grep -Fx 'kind=v121_tui_operator_observation' "$V121_TUI_OPERATOR_RECEIPT"
grep -Fx "candidate_sha=$V121_EXPECTED_SOURCE_SHA" "$V121_TUI_OPERATOR_RECEIPT"
grep -Fx "artifact_sha256=$V121_EXPECTED_SHA256" "$V121_TUI_OPERATOR_RECEIPT"
grep -Fx "target=$V121_TARGET" "$V121_TUI_OPERATOR_RECEIPT"
grep -Fx 'surface=tui' "$V121_TUI_OPERATOR_RECEIPT"
grep -Fx 'operator_attended=true' "$V121_TUI_OPERATOR_RECEIPT"
grep -Fx 'attach_status_provider_quit=pass' "$V121_TUI_OPERATOR_RECEIPT"
grep -Fx 'terminal_exact_restore=pass' "$V121_TUI_OPERATOR_RECEIPT"
grep -Fx 'post_tui_daemon_health=pass' "$V121_TUI_OPERATOR_RECEIPT"
echo 'PASS: operator exact-artifact TUI receipt is bound and reviewed'
```

```sh
export SOURCE_RUN_ID="${SOURCE_RUN_ID:?set successful tag-push run ID}"
export SOURCE_RUN_ATTEMPT="${SOURCE_RUN_ATTEMPT:?set latest successful attempt}"
export DIGEST_MANIFEST_ARTIFACT_ID="${DIGEST_MANIFEST_ARTIFACT_ID:?set numeric artifact ID}"
export DIGEST_MANIFEST_SHA256="${DIGEST_MANIFEST_SHA256:?set upload-artifact SHA-256}"
export QUALIFICATION_MANIFEST_ARTIFACT_ID="${QUALIFICATION_MANIFEST_ARTIFACT_ID:?set numeric artifact ID}"
export QUALIFICATION_MANIFEST_SHA256="${QUALIFICATION_MANIFEST_SHA256:?set upload-artifact SHA-256}"
gh workflow run release-artifacts.yml --ref "$VERSION" \
  -f tag="$VERSION" \
  -f source_run_id="$SOURCE_RUN_ID" \
  -f source_run_attempt="$SOURCE_RUN_ATTEMPT" \
  -f digest_manifest_artifact_id="$DIGEST_MANIFEST_ARTIFACT_ID" \
  -f digest_manifest_sha256="$DIGEST_MANIFEST_SHA256" \
  -f qualification_manifest_artifact_id="$QUALIFICATION_MANIFEST_ARTIFACT_ID" \
  -f qualification_manifest_sha256="$QUALIFICATION_MANIFEST_SHA256"
```

Approve only the deployment whose ref and seven values match reviewed evidence.
After approval, promotion authenticates the source run/tag/SHA/workflow and the
21-day artifact window, rehashes the unchanged archives, creates or resumes a
draft, uploads only missing assets, verifies the exact-tag cosign bundle, and
publishes. It never checks out/builds, selects `latest`, or uses `--clobber`.

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
  --certificate-identity "https://github.com/lexlapax/allbert-assist/.github/workflows/release-artifacts.yml@refs/tags/$VERSION" \
  --certificate-oidc-issuer 'https://token.actions.githubusercontent.com'
```

There is no branch `workflow_dispatch` build: dispatch is the protected publish
path and must run at an exact tag. Before tagging, exercise only deterministic
fixture/local-tree contracts:

```sh
MIX_ENV=test mix test \
  apps/allbert_assist/test/allbert_assist/release/licenses_final_artifact_test.exs \
  apps/allbert_assist/test/allbert_assist/release/promotion_workflow_contract_test.exs
```

## 2. Fill The Homebrew Tap

The tap lives at [`lexlapax/homebrew-allbert`](https://github.com/lexlapax/homebrew-allbert)
(`Formula/allbert.rb`). Fill the formula from the published release, not by hand. The
helper updates per-target URLs and SHA256 rows together; Homebrew derives the
version from those URLs:

```sh
ALLBERT_ASSIST_CHECKOUT="${ALLBERT_ASSIST_CHECKOUT:-$(pwd)}"  # run from allbert-assist checkout
TAP_CHECKOUT="$(mktemp -d /tmp/homebrew-allbert.XXXXXX)"
mkdir -p "/tmp/allbert-${VERSION}"
gh release download "$VERSION" --repo "$REPO" \
  --pattern SHA256SUMS --dir "/tmp/allbert-${VERSION}"
git clone https://github.com/lexlapax/homebrew-allbert "$TAP_CHECKOUT"
# The repository formula is the source of truth for dependencies and service
# declarations; the fill helper owns only release URLs and checksums.
cp "$ALLBERT_ASSIST_CHECKOUT/homebrew/allbert.rb" \
  "$TAP_CHECKOUT/Formula/allbert.rb"
sh "$ALLBERT_ASSIST_CHECKOUT/homebrew/fill-sha256.sh" \
  "/tmp/allbert-${VERSION}/SHA256SUMS" \
  "$TAP_CHECKOUT/Formula/allbert.rb"
```

Audit and publish from the tap checkout:

```sh
cd "$TAP_CHECKOUT"
git diff -- Formula/allbert.rb
rg -n 'PLACEHOLDER|TODO|sha256' Formula/allbert.rb
git add Formula/allbert.rb
git commit -m "${EXPECTED_VERSION} M0.c3 fill release formula"
if brew tap | rg -qx 'lexlapax/allbert'; then
  brew untap --force lexlapax/allbert
fi
brew tap lexlapax/allbert "$TAP_CHECKOUT" --custom-remote
brew trust --formula lexlapax/allbert/allbert
brew audit --strict --online --formula allbert
git push origin main
```

Evidence to record: tap commit hash, audit output, `brew info lexlapax/allbert/allbert`
showing the current version, the three formula SHA256 rows, and confirmation that no
placeholder checksum or old release URL remains.

The explicit untap/retap above is required when auditing a freshly cloned tap.
`brew tap` against an already-registered custom remote can leave Homebrew reading
an older local worktree even after the upstream tap was pushed.

The repository copy is the formula source of truth. After every required platform
row is PASS or has an operator-approved policy SKIP, sync the filled tap formula back
into the release repository before archival:

```sh
cp "$TAP_CHECKOUT/Formula/allbert.rb" "$ALLBERT_ASSIST_CHECKOUT/homebrew/allbert.rb"
cd "$ALLBERT_ASSIST_CHECKOUT"
test -z "$(sed -n 's/^  version "\([^"]*\)"/\1/p' homebrew/allbert.rb)"
rg -n 'PLACEHOLDER|REPLACE_' homebrew/allbert.rb && exit 1 || true
test "$(rg -c "releases/download/$VERSION" homebrew/allbert.rb)" -eq 3
```

PASS: repository and tap formulae are byte-identical, derive `$EXPECTED_VERSION`
from all three release URLs, contain the three published checksums, have no
redundant explicit version, and have no placeholder or old-release URL. Commit this
with the post-tag documentation/roadmap archival; never move the product tag.

Homebrew 6 note: path-based `brew audit [path ...]` is disabled, and untrusted
third-party taps are refused. Audit by tapped formula name after trusting the tap.

The formula preserves regular `LICENSE`/`NOTICE` evidence in `libexec` while
exposing conventional prefix links. Since v1.3 M9.a2, release assembly rewrites
the Exqlite NIF's absolute build-time Mach-O install name to the stable
`@loader_path/sqlite3_nif.so` form and signs it before the license manifest is
sealed. The formula must remain copy-only for that managed NIF: PASS includes an
unchanged pre/post-Homebrew NIF SHA-256 and `allbert licenses --json`, not only
`eval`. Do not restore the v1.2.6 compressed-NIF/post-install workaround or
weaken manifest validation.

## 3. Per-OS Install Rehearsal

Do this on each Tier-1 OS path that is in scope. Install/uninstall must not touch
the operator's real Allbert Home (`~/.allbert`) unless `--purge` is explicitly
requested; set a disposable `ALLBERT_HOME` for rehearsal.

The active release plan defines the exact platform ledger. The completed v1.0.5
recovery required macOS; linux-x64 and linux-arm64 container artifacts; a
real-host Linux service/vault/browser row; and WSL2 using the Linux tarball.
Record CI run id,
tag/release URL, asset inventory, cosign transcript, tap commit/audit, install
transcript, TUI, channel-send, ACP, browser, service/vault, and preserved-Home
uninstall evidence under `EVIDENCE_ROOT`.

### Windows / WSL2 Tier-2 validation

Inside WSL2, use a disposable Home and install the published linux-x64
tarball through the same verified installer path. A prerelease tag and the
binary's product version are distinct (for example an RC tag may report the
eventual stable product version), so set
both variables explicitly. The active release request-flow is authoritative for
the exact Windows-host Ollama endpoint, focused doctor, onboarding/TUI, service,
evidence-hash, and uninstall commands; do not substitute a second WSL Ollama for
that topology.

```sh
export VERSION="${VERSION:?set the exact release or RC tag}"
export EXPECTED_VERSION="${EXPECTED_VERSION:?set the binary product version}"
export ALLBERT_HOME="$(mktemp -d /tmp/allbert-wsl2-home.XXXXXX)"
export ALLBERT_PREFIX="$(mktemp -d /tmp/allbert-wsl2-prefix.XXXXXX)"
export ALLBERT_VERSION="$VERSION"
curl -fsSL \
  "https://raw.githubusercontent.com/lexlapax/allbert-assist/$VERSION/scripts/install/install.sh" \
  | ALLBERT_PREFIX="$ALLBERT_PREFIX" ALLBERT_HOME="$ALLBERT_HOME" \
      ALLBERT_VERSION="$VERSION" sh
export PATH="$ALLBERT_PREFIX/bin:$PATH"
test "$(allbert --version)" = "allbert $EXPECTED_VERSION"
allbert admin status
allbert admin vault
command -v node
allbert admin settings set browser.enabled true
allbert eval 'Application.ensure_all_started(:allbert_assist); case AllbertAssist.Actions.Runner.run("browser_doctor", %{}, %{actor: "release", channel: :cli}) do {:ok, %{doctor: doctor}} -> IO.inspect(doctor, limit: :infinity, pretty: true); other -> IO.inspect(other, limit: :infinity, pretty: true) end'
```

Then attest first chat against a real configured local model, one warm thin-TUI
session attached to the running daemon, and service install/status/uninstall
basics.
PASS requires the published Linux artifact, a live browser doctor reporting
`ok`, and not a source checkout. A SKIP requires an owner, policy reason, and
follow-up location; absence of a WSL2 host is not silently treated as PASS.

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

The browser plugin has an explicit Node host prerequisite. The Homebrew formula
declares it; standalone/curl hosts must install a supported `node` before
running browser doctor. Allbert never invokes a package manager to install it.

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
allbert admin service install --dry-run
allbert admin settings set permissions.command_execute needs_confirmation

INSTALL_OUTPUT="$(allbert admin service install)"
printf '%s\n' "$INSTALL_OUTPUT"
INSTALL_ID="$(
  printf '%s\n' "$INSTALL_OUTPUT" \
    | sed -n 's/.*Confirmation request: \(conf_[0-9][0-9_]*\).*/\1/p' \
    | tail -n 1
)"
test -n "$INSTALL_ID"
allbert admin confirmations approve "$INSTALL_ID"

# Use the active request-flow's bounded manager/health poll here. Only after it
# passes, request uninstall; underscore is valid in every confirmation id.
UNINSTALL_OUTPUT="$(allbert admin service uninstall)"
printf '%s\n' "$UNINSTALL_OUTPUT"
UNINSTALL_ID="$(
  printf '%s\n' "$UNINSTALL_OUTPUT" \
    | sed -n 's/.*Confirmation request: \(conf_[0-9][0-9_]*\).*/\1/p' \
    | tail -n 1
)"
test -n "$UNINSTALL_ID"
allbert admin confirmations approve "$UNINSTALL_ID"
allbert admin confirmations list
allbert admin settings set permissions.command_execute denied
allbert admin settings get permissions.command_execute
```

PASS: both confirmation IDs resolve `approved`; manager state reaches the
active/healthy then absent/inactive conditions named by the active request-flow;
the unit is removed; and `permissions.command_execute` is restored to `denied`.
A queued manager command, a disconnected self-stop, or an approved operator
decision with `target_status: error` is inspected rather than rewritten as
denial or called healthy.

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
MIGRATE_OUTPUT="$(allbert admin secrets migrate)"
printf '%s\n' "$MIGRATE_OUTPUT"
MIGRATE_ID="$(
  printf '%s\n' "$MIGRATE_OUTPUT" \
    | sed -n 's/.*Confirmation request: \(conf_[0-9][0-9_]*\).*/\1/p' \
    | tail -n 1
)"
test -n "$MIGRATE_ID"
allbert admin confirmations approve "$MIGRATE_ID"
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

The product proof runs the packaged thin client (`allbert tui`), not the Mix
twin. The daemon must own the disposable Home before the client attaches; the
client must never start Repo, migrations, providers, or an embedded writer.
The exact-artifact CI row uses the bounded standard-library PTY harness:

```sh
scripts/smoke/v121_tui_qualification.sh \
  /absolute/path/to/extracted/allbert TARGET "$EVIDENCE_ROOT/fv-result.json"
```

`TARGET` is `macos-arm64`, `linux-x64`, or `linux-arm64`. The release workflow
passes the already extracted immutable archive and requires the helper's strict
content-free JSON row. The harness proves actionable no-daemon behavior with no
Home mutation, one-session occupancy, resize and pressure bounds, Ctrl-C/EOF,
daemon loss/restart, terminal restoration, and continued Web health. It retains
no raw TUI/provider transcript. Linux x64 additionally consumes the protected,
harness-only configured-provider inputs defined by the active request-flow;
other targets report provider `not_required`.

Automation supports but cannot replace seeing the exact packaged client attach
and work. This human row is a documented command sequence, not an attended
mode in the automation harness. Prepare a disposable Home physically below
`TMPDIR` or `/tmp` with a real provider/model through the packaged interactive
vault path. Start a disposable Bash subshell with `bash --noprofile --norc`;
set the required inputs there (or export them before starting it), then paste
each block below into that same shell. Fail-fast and the `EXIT` trap prevent a
failed check from publishing a receipt or leaving the daemon running:

```sh
set -Eeuo pipefail
umask 077
command -v awk curl grep jq script tee >/dev/null
V121_TUI_DAEMON_PID=
trap 'if test -n "${V121_TUI_DAEMON_PID:-}"; then kill "$V121_TUI_DAEMON_PID" 2>/dev/null || true; wait "$V121_TUI_DAEMON_PID" 2>/dev/null || true; fi' EXIT

: "${V121_TARGET:?macos-arm64, linux-x64, or linux-arm64}"
: "${V121_ARTIFACT:?absolute path to the selected target archive}"
: "${V121_DIGEST_MANIFEST:?path to the authenticated immutable digest manifest}"
: "${V121_TUI_HOME:?prepared disposable Home with the real provider/profile}"
: "${V121_TUI_PROVIDER_PROFILE:?set the prepared real profile}"
test -f "$V121_ARTIFACT"
test -r "$V121_DIGEST_MANIFEST"
case "$V121_ARTIFACT" in
  /*) ;;
  *) echo 'V121_ARTIFACT must be an absolute path' >&2; exit 1 ;;
esac

V121_HOST_OS=$(uname -s)
V121_HOST_ARCH=$(uname -m)
case "$V121_HOST_OS:$V121_HOST_ARCH" in
  Darwin:arm64) V121_HOST_TARGET=macos-arm64 ;;
  Linux:x86_64|Linux:amd64) V121_HOST_TARGET=linux-x64 ;;
  Linux:aarch64|Linux:arm64) V121_HOST_TARGET=linux-arm64 ;;
  *) echo "unsupported operator host: $V121_HOST_OS/$V121_HOST_ARCH" >&2; exit 1 ;;
esac
test "$V121_TARGET" = "$V121_HOST_TARGET"

V121_EXPECTED_SHA256=$(jq -er --arg target "$V121_TARGET" \
  '.archives[] | select(.target == $target) | .sha256' "$V121_DIGEST_MANIFEST")
[[ "$V121_EXPECTED_SHA256" =~ ^[0-9a-f]{64}$ ]]
V121_EXPECTED_SOURCE_SHA=$(jq -er '.source_sha' "$V121_DIGEST_MANIFEST")
[[ "$V121_EXPECTED_SOURCE_SHA" =~ ^[0-9a-f]{40}$ ]]
export V121_TARGET V121_ARTIFACT V121_DIGEST_MANIFEST
export V121_EXPECTED_SHA256 V121_EXPECTED_SOURCE_SHA

V121_TUI_HOME=$(cd -P -- "$V121_TUI_HOME" && pwd -P)
V121_TMP_ROOT=$(cd -P -- "${TMPDIR:-/tmp}" && pwd -P)
V121_SYSTEM_TMP_ROOT=$(cd -P -- /tmp && pwd -P)
V121_USER_HOME=$(cd -P -- "${HOME:?HOME must be set}" && pwd -P)
case "$V121_TUI_HOME" in
  "$V121_TMP_ROOT"/*|"$V121_SYSTEM_TMP_ROOT"/*) ;;
  *) echo 'V121_TUI_HOME must be physically below TMPDIR or /tmp' >&2; exit 1 ;;
esac
if test -d "$V121_USER_HOME/.allbert"; then
  V121_DEFAULT_ALLBERT_HOME=$(cd -P -- "$V121_USER_HOME/.allbert" && pwd -P)
  test "$V121_TUI_HOME" != "$V121_DEFAULT_ALLBERT_HOME"
else
  test "$V121_TUI_HOME" != "$V121_USER_HOME/.allbert"
fi

V121_TUI_EVIDENCE_DIR=$(mktemp -d "$V121_TMP_ROOT/allbert-v121-artifact-operator.XXXXXX")
V121_TUI_EXTRACT_PARENT=$(mktemp -d "$V121_TMP_ROOT/allbert-v121-artifact-extract.XXXXXX")
V121_TUI_EXTRACT_DIR="$V121_TUI_EXTRACT_PARENT/release"
V121_TUI_PORT="${V121_TUI_PORT:-$((49152 + RANDOM % 16384))}"
[[ "$V121_TUI_PORT" =~ ^[0-9]+$ ]]
(( V121_TUI_PORT >= 1024 && V121_TUI_PORT <= 65535 ))
if (exec 3<>"/dev/tcp/127.0.0.1/$V121_TUI_PORT") 2>/dev/null; then
  echo "localhost port $V121_TUI_PORT is already in use; choose another" >&2
  exit 1
fi
export V121_TUI_HOME V121_TUI_PROVIDER_PROFILE V121_TUI_EVIDENCE_DIR
export V121_TUI_EXTRACT_PARENT V121_TUI_EXTRACT_DIR V121_TUI_PORT

if command -v sha256sum >/dev/null 2>&1; then
  V121_ACTUAL_SHA256=$(sha256sum "$V121_ARTIFACT" | awk '{print $1}')
else
  command -v shasum >/dev/null
  V121_ACTUAL_SHA256=$(shasum -a 256 "$V121_ARTIFACT" | awk '{print $1}')
fi
test "$V121_ACTUAL_SHA256" = "$V121_EXPECTED_SHA256"
bash scripts/release/stage_artifacts.sh extract-release \
  "$V121_ARTIFACT" "$V121_TUI_EXTRACT_DIR"
V121_ALLBERT="$V121_TUI_EXTRACT_DIR/allbert/bin/allbert"
test -x "$V121_ALLBERT"
export V121_ALLBERT
export ALLBERT_HOME="$V121_TUI_HOME"

"$V121_ALLBERT" admin models use \
  "$V121_TUI_PROVIDER_PROFILE" --enable-assist
"$V121_ALLBERT" admin settings set \
  intent.direct_answer_model_profile "$V121_TUI_PROVIDER_PROFILE"
"$V121_ALLBERT" admin settings set \
  intent.direct_answer_model_enabled true
"$V121_ALLBERT" admin models list \
  2>&1 \
  | tee "$V121_TUI_EVIDENCE_DIR/model-list.txt"
"$V121_ALLBERT" admin models doctor "$V121_TUI_PROVIDER_PROFILE" \
  2>&1 \
  | tee "$V121_TUI_EVIDENCE_DIR/provider-doctor.txt"

PORT="$V121_TUI_PORT" "$V121_ALLBERT" serve \
  >"$V121_TUI_EVIDENCE_DIR/daemon.log" 2>&1 &
V121_TUI_DAEMON_PID=$!
V121_TUI_DAEMON_READY=false
V121_TUI_HEALTH_JSON=
for ((V121_READY_ATTEMPT=1; V121_READY_ATTEMPT<=90; V121_READY_ATTEMPT++)); do
  if ! kill -0 "$V121_TUI_DAEMON_PID" 2>/dev/null; then
    tail -n 80 "$V121_TUI_EVIDENCE_DIR/daemon.log" >&2 || true
    exit 1
  fi
  if V121_TUI_HEALTH_JSON=$(curl -fsS --max-time 2 \
      "http://127.0.0.1:$V121_TUI_PORT/health" 2>/dev/null) && \
      printf '%s\n' "$V121_TUI_HEALTH_JSON" \
        | grep -Eq '"status"[[:space:]]*:[[:space:]]*"ok"'; then
    V121_TUI_DAEMON_READY=true
    break
  fi
  sleep 1
done
if test "$V121_TUI_DAEMON_READY" != true; then
  tail -n 80 "$V121_TUI_EVIDENCE_DIR/daemon.log" >&2 || true
  exit 1
fi
kill -0 "$V121_TUI_DAEMON_PID"
printf '%s\n' "$V121_TUI_HEALTH_JSON" \
  | tee "$V121_TUI_EVIDENCE_DIR/pre-tui-health.json"
V121_STTY_BEFORE=$(stty -g)
V121_TUI_TRANSCRIPT="$V121_TUI_EVIDENCE_DIR/tui-${V121_TARGET}.txt"
export V121_TUI_TRANSCRIPT
```

Expected before opening the TUI: the model list names the selected active
profile with model-assisted intent enabled; the redacted doctor reports that
provider/model ready for an actual turn; and pre-TUI health contains
`"status":"ok"`. Exit status alone is not enough—read the doctor output. The
bounded readiness loop also proves that the daemon process stayed alive while
reaching that state.

In that same Bash shell, capture one normal packaged-client session; the daemon
continues in the background:

```sh
if test "$V121_HOST_OS" = Darwin; then
  script -q "$V121_TUI_TRANSCRIPT" "$V121_ALLBERT" tui
else
  printf -v V121_TUI_COMMAND '%q tui' "$V121_ALLBERT"
  script -q -e -c "$V121_TUI_COMMAND" "$V121_TUI_TRANSCRIPT"
fi
```

Inside the one client:

1. Confirm the initial `Allbert TUI - daemon attached` banner and the
   intentionally profile-neutral `allbert>` prompt render normally.
2. Enter `/status`. Expected: the report includes `channel: tui`,
   `operator_id: local`, `external_user_id: default`, and
   `Channels.Supervisor: running`. Pre/post `/health` commands, not `/status`,
   prove daemon health.
3. Enter `what is 2+2?`. Expected: the selected real provider answers `4`.
4. Enter `/quit`. Expected: normal detach to a usable, visually intact shell.

After `/quit`, prove continuity, stop the daemon, and write the content-free
receipt only after every observation above passed:

```sh
V121_STTY_AFTER=$(stty -g)
test "$V121_STTY_BEFORE" = "$V121_STTY_AFTER"
kill -0 "$V121_TUI_DAEMON_PID"
V121_TUI_POST_HEALTH_JSON=$(curl -fsS --max-time 5 \
  "http://127.0.0.1:$V121_TUI_PORT/health")
printf '%s\n' "$V121_TUI_POST_HEALTH_JSON" \
  | tee "$V121_TUI_EVIDENCE_DIR/post-tui-health.json"
printf '%s\n' "$V121_TUI_POST_HEALTH_JSON" \
  | grep -Eq '"status"[[:space:]]*:[[:space:]]*"ok"'
if command -v sha256sum >/dev/null 2>&1; then
  V121_ACTUAL_SHA256=$(sha256sum "$V121_ARTIFACT" | awk '{print $1}')
else
  V121_ACTUAL_SHA256=$(shasum -a 256 "$V121_ARTIFACT" | awk '{print $1}')
fi
test "$V121_ACTUAL_SHA256" = "$V121_EXPECTED_SHA256"
kill "$V121_TUI_DAEMON_PID"
wait "$V121_TUI_DAEMON_PID" || true
V121_TUI_DAEMON_PID=

V121_TUI_OPERATOR_RECEIPT="$V121_TUI_EVIDENCE_DIR/v121-tui-${V121_TARGET}-${V121_EXPECTED_SHA256}.txt"
export V121_TUI_OPERATOR_RECEIPT
test ! -e "$V121_TUI_OPERATOR_RECEIPT"
(
  set -o noclobber
  printf '%s\n' \
    'kind=v121_tui_operator_observation' \
    "candidate_sha=$V121_EXPECTED_SOURCE_SHA" \
    "artifact_sha256=$V121_EXPECTED_SHA256" \
    "target=$V121_TARGET" \
    'surface=tui' \
    'operator_attended=true' \
    'attach_status_provider_quit=pass' \
    'terminal_exact_restore=pass' \
    'post_tui_daemon_health=pass' \
    >"$V121_TUI_OPERATOR_RECEIPT"
)
chmod 600 "$V121_TUI_OPERATOR_RECEIPT"
```

The transcript and command output stay in the private operator directory; do
not commit or upload the raw transcript. Review and archive the content-free
receipt, then return to the promotion hard stop:

```sh
test -f "$V121_TUI_OPERATOR_RECEIPT"
grep -Fx 'kind=v121_tui_operator_observation' "$V121_TUI_OPERATOR_RECEIPT"
grep -Fx "candidate_sha=$V121_EXPECTED_SOURCE_SHA" "$V121_TUI_OPERATOR_RECEIPT"
grep -Fx "artifact_sha256=$V121_EXPECTED_SHA256" "$V121_TUI_OPERATOR_RECEIPT"
grep -Fx "target=$V121_TARGET" "$V121_TUI_OPERATOR_RECEIPT"
grep -Fx 'surface=tui' "$V121_TUI_OPERATOR_RECEIPT"
grep -Fx 'operator_attended=true' "$V121_TUI_OPERATOR_RECEIPT"
grep -Fx 'attach_status_provider_quit=pass' "$V121_TUI_OPERATOR_RECEIPT"
grep -Fx 'terminal_exact_restore=pass' "$V121_TUI_OPERATOR_RECEIPT"
grep -Fx 'post_tui_daemon_health=pass' "$V121_TUI_OPERATOR_RECEIPT"
trap - EXIT
echo 'PASS: operator TUI receipt reviewed; return to section 1 hard stop'
```

On a raw-absent Home, the authenticated daemon session still performs the one
atomic `channels.tui.enabled=true` plus `default → local` bootstrap. The TUI
mapping grants no Web authorization. Web may remain open during the session and
must stay healthy because both surfaces use the same daemon. A second TUI is
refused without disrupting the first.

Normal exit, handled Ctrl-C/EOF, decoder failure, daemon shutdown, and socket
loss must restore cooked input and leave the alternate screen. SIGKILL, power
loss, or terminal-emulator failure cannot run cleanup. Recover after only those
uncatchable failures with:

```sh
stty sane
reset  # only if the display/alternate screen is still damaged
```

A handled exit that needs either recovery command fails the release row. Do not
claim that cleanup ran after SIGKILL.

### Packaged browser doctor and workspace

Use the packaged binary, an explicit browser/research setting, and the
`localhost` origin accepted by the endpoint configuration:

```sh
command -v node
export PLAYWRIGHT_VERSION="${PLAYWRIGHT_VERSION:?set the active plan's exact Playwright version}"
export ALLBERT_PLAYWRIGHT_ROOT="$(mktemp -d /tmp/allbert-release-playwright.XXXXXX)"
export BROWSER_BINARY_PATH="${BROWSER_BINARY_PATH:?set an absolute OS-managed Chromium/Chrome executable}"
test -x "$BROWSER_BINARY_PATH"
PLAYWRIGHT_SKIP_BROWSER_DOWNLOAD=1 npm install \
  --prefix "$ALLBERT_PLAYWRIGHT_ROOT" \
  --ignore-scripts --no-audit --no-fund --no-save \
  "playwright@$PLAYWRIGHT_VERSION"
test "$(node -e 'process.stdout.write(require(process.argv[1]).version)' \
  "$ALLBERT_PLAYWRIGHT_ROOT/node_modules/playwright/package.json")" = \
  "$PLAYWRIGHT_VERSION"
allbert admin settings set browser.enabled true
allbert admin settings set research.enabled true
allbert admin settings set browser.driver.node_path "$(command -v node)"
allbert admin settings set browser.driver.node_module_path \
  "$ALLBERT_PLAYWRIGHT_ROOT/node_modules"
allbert admin settings set browser.driver.version_pin "$PLAYWRIGHT_VERSION"
allbert admin settings set browser.driver.binary_path "$BROWSER_BINARY_PATH"
allbert eval 'Application.ensure_all_started(:allbert_assist); case AllbertAssist.Actions.Runner.run("browser_doctor", %{}, %{actor: "release", channel: :cli}) do {:ok, %{doctor: doctor}} -> IO.inspect(doctor, limit: :infinity, pretty: true); other -> IO.inspect(other, limit: :infinity, pretty: true) end' \
  | tee "$EVIDENCE_ROOT/${VERSION}-browser-doctor.log"
rg 'live_check_status: :ok|"live_check_status":"ok"' \
  "$EVIDENCE_ROOT/${VERSION}-browser-doctor.log"
allbert serve > "$EVIDENCE_ROOT/${VERSION}-browser-serve.log" 2>&1 &
BROWSER_DAEMON_PID=$!
trap 'kill "$BROWSER_DAEMON_PID" 2>/dev/null || true' EXIT INT TERM
for _ in $(seq 1 30); do
  curl -fsS http://localhost:4000/health && break
  sleep 1
done
open http://localhost:4000/workspace  # macOS; use the host browser on Linux
# Run the active plan's real configured-provider browser-research prompt and
# record its redacted transcript and screenshot reference.
kill "$BROWSER_DAEMON_PID"
wait "$BROWSER_DAEMON_PID" 2>/dev/null || true
trap - EXIT INT TERM
```

PASS: the doctor resolves the pinned host Playwright package, launches the
explicit OS-managed Chromium/Chrome executable, and reports `ok`; the workspace is
served at `localhost`; research navigates/extracts through the real configured
provider; the same daemon remains healthy for any subsequent thin-TUI run.

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
  --pattern SHA256SUMS.cosign.bundle \
  --dir "$WORK/artifacts"
cosign verify-blob --bundle "$WORK/artifacts/SHA256SUMS.cosign.bundle" \
  "$WORK/artifacts/SHA256SUMS" \
  --certificate-identity "https://github.com/lexlapax/allbert-assist/.github/workflows/release-artifacts.yml@refs/tags/$VERSION" \
  --certificate-oidc-issuer 'https://token.actions.githubusercontent.com'
```

Run both Linux targets:

```sh
docker run --rm --platform linux/arm64 \
  --mount type=bind,source="$WORK",target=/work,readonly \
  --mount type=bind,source="$ALLBERT_ASSIST_CHECKOUT",target=/repo,readonly \
  --env VERSION="$VERSION" \
  --env PLAYWRIGHT_VERSION="$PLAYWRIGHT_VERSION" \
  --workdir /tmp \
  node:22-bookworm \
  bash -lc 'set -euo pipefail
    apt-get update
    apt-get install -y ca-certificates chromium curl tar gzip libstdc++6 openssl
    mkdir -p /tmp/rehearsal
    cp -R /work/artifacts /tmp/rehearsal/artifacts
    mkdir -p /tmp/rehearsal/extract-arm64 /tmp/rehearsal/playwright-host
    tar -xzf /tmp/rehearsal/artifacts/allbert-${VERSION}-linux-arm64.tar.gz \
      -C /tmp/rehearsal/extract-arm64
    PLAYWRIGHT_SKIP_BROWSER_DOWNLOAD=1 npm install \
      --prefix /tmp/rehearsal/playwright-host \
      --ignore-scripts --no-audit --no-fund --no-save \
      playwright@${PLAYWRIGHT_VERSION}
    test "$(node -e '\''process.stdout.write(require(process.argv[1]).version)'\'' \
      /tmp/rehearsal/playwright-host/node_modules/playwright/package.json)" = \
      "${PLAYWRIGHT_VERSION}"
    test -x /usr/bin/chromium
    chown -R node:node /tmp/rehearsal
    su -s /bin/bash node -c "set -euo pipefail
    cd /tmp/rehearsal
    export LANG=C.UTF-8 LC_ALL=C.UTF-8
    export PLAYWRIGHT_NODE_PATH=/tmp/rehearsal/playwright-host/node_modules
    export BROWSER_BINARY_PATH=/usr/bin/chromium
    (cd artifacts && sha256sum -c SHA256SUMS --ignore-missing)
    ALLBERT_REHEARSAL_PREVERIFIED_STAGE=/tmp/rehearsal/artifacts \
      ALLBERT_REHEARSAL_VERSION=${VERSION} \
      /repo/scripts/smoke/linux_rehearsal.sh /tmp/rehearsal/extract-arm64/allbert"'

docker run --rm --platform linux/amd64 \
  --mount type=bind,source="$WORK",target=/work,readonly \
  --mount type=bind,source="$ALLBERT_ASSIST_CHECKOUT",target=/repo,readonly \
  --env VERSION="$VERSION" \
  --env PLAYWRIGHT_VERSION="$PLAYWRIGHT_VERSION" \
  --workdir /tmp \
  node:22-bookworm \
  bash -lc 'set -euo pipefail
    apt-get update
    apt-get install -y ca-certificates chromium curl tar gzip libstdc++6 openssl
    mkdir -p /tmp/rehearsal
    cp -R /work/artifacts /tmp/rehearsal/artifacts
    mkdir -p /tmp/rehearsal/extract-x64 /tmp/rehearsal/playwright-host
    tar -xzf /tmp/rehearsal/artifacts/allbert-${VERSION}-linux-x64.tar.gz \
      -C /tmp/rehearsal/extract-x64
    PLAYWRIGHT_SKIP_BROWSER_DOWNLOAD=1 npm install \
      --prefix /tmp/rehearsal/playwright-host \
      --ignore-scripts --no-audit --no-fund --no-save \
      playwright@${PLAYWRIGHT_VERSION}
    test "$(node -e '\''process.stdout.write(require(process.argv[1]).version)'\'' \
      /tmp/rehearsal/playwright-host/node_modules/playwright/package.json)" = \
      "${PLAYWRIGHT_VERSION}"
    test -x /usr/bin/chromium
    chown -R node:node /tmp/rehearsal
    su -s /bin/bash node -c "set -euo pipefail
    cd /tmp/rehearsal
    export LANG=C.UTF-8 LC_ALL=C.UTF-8 ERL_AFLAGS=\"+JMsingle true\"
    export PLAYWRIGHT_NODE_PATH=/tmp/rehearsal/playwright-host/node_modules
    export BROWSER_BINARY_PATH=/usr/bin/chromium
    (cd artifacts && sha256sum -c SHA256SUMS --ignore-missing)
    ALLBERT_REHEARSAL_PREVERIFIED_STAGE=/tmp/rehearsal/artifacts \
      ALLBERT_REHEARSAL_VERSION=${VERSION} \
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
| Tap fill | URL-derived formula version and checksums match the release | `homebrew/fill-sha256.sh`; `brew audit --strict --online --formula` | current packaged line |
| Package-manager install | package installs and invokes packaged binary | `brew install`; `brew test`; uninstall | current line |
| Packaged TUI | exact thin client attaches to the one daemon, passes bounded protocol/TTY rows, answers from a ready real provider, restores the terminal, and preserves concurrent Web continuity | automated `scripts/smoke/v121_tui_qualification.sh`; §4 operator command sequence | current line |
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
