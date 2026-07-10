# Installing Allbert

Allbert ships as a self-contained binary with its own Erlang/OTP runtime — no
Elixir/OTP toolchain is required on your machine. Your data lives in **Allbert
Home** (`~/.allbert` by default) and is never touched by install, upgrade, or
uninstall unless you explicitly ask.

## Platform support tiers

- **Tier 1 (fully supported):** macOS (Apple Silicon) and Linux (x86-64,
  arm64). The binary, Homebrew + curl install, the `launchd`/`systemd` daemon,
  and OS-keychain credentials all work here.
- **Tier 2 (best-effort):** Windows via **WSL2** — install the Linux build
  inside WSL2. Native Windows packaging is not provided in the v0.64 release line.

## Homebrew (recommended on macOS and Linux)

```sh
brew install lexlapax/allbert/allbert
brew services start allbert
curl -fsS http://localhost:4000/health
allbert admin service status
```

The formula ships prebuilt per-platform binaries and registers an `allbert
serve` service, so `brew services start allbert` runs Allbert in the
background. Foreground `allbert serve` is a diagnostic or repair fallback, not
the normal first-run path for a packaged install.

The public tap installs directly with the command above. A newer Homebrew may
prompt once to trust a third-party tap on first install; approve the prompt if it
appears — no separate trust command is required for a normal install.

## curl installer

```sh
curl -fsSL https://raw.githubusercontent.com/lexlapax/allbert-assist/main/scripts/install/install.sh | sh
```

Prefer download-then-inspect if you don't want to pipe to a shell:

```sh
curl -fsSLO https://raw.githubusercontent.com/lexlapax/allbert-assist/main/scripts/install/install.sh
less install.sh
sh install.sh
```

The installer downloads the artifact for your platform, verifies the release
`SHA256SUMS` with the published cosign bundle, then verifies the artifact SHA256
against that signed checksum file. `cosign` is required; the installer refuses to
install without signature verification. It installs to `~/.local` by default
(`ALLBERT_PREFIX` to override), writes an uninstall manifest, and never writes to
Allbert Home.

After a curl install, use the confirmation-gated service setup when a user
service manager is available:

```sh
export PATH="$HOME/.local/bin:$PATH"
allbert admin service install
allbert admin confirmations approve <ID>
curl -fsS http://localhost:4000/health
allbert admin service status
```

On platforms without a reachable user service manager, Allbert reports the
service-manager blocker and falls back to foreground `allbert serve`.

## Verifying artifacts yourself

Every release publishes `SHA256SUMS` and `SHA256SUMS.cosign.bundle`. To check a
download by hand:

```sh
cosign verify-blob \
  --bundle SHA256SUMS.cosign.bundle \
  --certificate-identity-regexp 'https://github.com/lexlapax/allbert-assist/.github/workflows/release-artifacts.yml@refs/tags/.*' \
  --certificate-oidc-issuer https://token.actions.githubusercontent.com \
  SHA256SUMS
sha256sum -c SHA256SUMS   # or: shasum -a 256 -c SHA256SUMS on macOS
```

## Uninstall

```sh
# Homebrew:
brew uninstall allbert         # add: brew services stop allbert  (if running)

# curl install:
sh scripts/install/uninstall.sh          # removes the binary; keeps your data
sh scripts/install/uninstall.sh --purge  # also removes Allbert Home
```

Uninstall removes only what the install manifest recorded. **Allbert Home is
preserved** unless you pass `--purge`.

## Packaged layout

The OTP release bundles its own ERTS and all runtime code, so no Elixir/Erlang
toolchain is needed on the target. Two roots matter at runtime:

- **Release root** — where the artifact is unpacked (Homebrew Cellar, or the
  curl installer's prefix). `RELEASE_ROOT` points here; the bundled plugins live
  under `RELEASE_ROOT/plugins` (each plugin's `allbert_plugin.json` + `priv`),
  which is how the packaged binary registers them. `ALLBERT_PLUGINS_ROOT`
  overrides this for advanced/dev use.
- **Allbert Home** (`~/.allbert` by default, or `ALLBERT_HOME`) — all operator
  data: the SQLite database, settings, the encrypted secret store, memory, and
  artifacts. Install, upgrade, and uninstall never write here (absent
  `--purge`). Secret values held in the tier-1 OS vault live in the OS keychain,
  outside both roots — see the Secret Vault section of
  [security-hardening.md](security-hardening.md).

## Upgrades

Upgrading (`brew upgrade allbert`, or re-running the curl installer) replaces
the binary in place. On the first boot of a new version, Allbert **backs up its
database** (a copy under `<Allbert Home>/db/backups/`) before running any schema
migrations, and logs the migrations it applies. If the backup cannot be written,
the boot refuses to migrate rather than proceed unprotected. Recovery is exposed
through the package-safe admin path:

```sh
allbert admin db list-backups
allbert admin db restore latest --dry-run
allbert admin db restore latest
allbert admin confirmations approve <ID>
```

## Running alongside a development checkout

A packaged install and a `mix`-based dev checkout both default to Allbert Home
`~/.allbert` and port 4000. **Do not run both against the same Home at once** —
two runtimes on one SQLite database is a known failure mode. For a dev checkout
beside a packaged install, point the checkout at a separate Home and port:

```sh
ALLBERT_HOME=~/.allbert-dev PORT=4100 mix phx.server
```

## Distribution trust

The install and first run touch the network in exactly these ways, and no
others: the install-script/Homebrew artifact fetch, and (only if you opt into
the guided local-model setup) the Ollama installer fetch and model pull, each
behind an explicit confirmation. The binary itself performs **no telemetry, no
phone-home, and no auto-update check**.

**Current trust model (v0.64.3 packaged release).** The curl installer is fail-closed on the signed
checksum bundle: it downloads `SHA256SUMS.cosign.bundle`, requires `cosign`, verifies
the checksum file against the GitHub Actions OIDC identity, then verifies the artifact
SHA256 before installing. If `cosign` is missing or verification fails, nothing is
installed.

The Homebrew path uses Homebrew's package-manager contract: the trusted formula in
`lexlapax/homebrew-allbert` pins the release URL and SHA256 for each platform, and
Homebrew verifies the downloaded artifact against that formula. It does not run the
curl installer's cosign step inside `brew install`; use the curl installer or the
manual verification block above when you need the GitHub Actions OIDC signature check
at install time.

See `docs/adr/0076-packaging-distribution-and-unified-cli.md` (Distribution
Trust) for the full posture.
