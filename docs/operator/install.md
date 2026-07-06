# Installing Allbert (v0.62)

Allbert ships as a self-contained binary with its own Erlang/OTP runtime — no
Elixir/OTP toolchain is required on your machine. Your data lives in **Allbert
Home** (`~/.allbert` by default) and is never touched by install, upgrade, or
uninstall unless you explicitly ask.

## Platform support tiers

- **Tier 1 (fully supported):** macOS (Apple Silicon) and Linux (x86-64,
  arm64). The binary, Homebrew + curl install, the `launchd`/`systemd` daemon,
  and OS-keychain credentials all work here.
- **Tier 2 (best-effort):** Windows via **WSL2** — install the Linux build
  inside WSL2. Native Windows packaging is not provided in v0.62.

## Homebrew (recommended on macOS and Linux)

```sh
brew install lexlapax/allbert/allbert
allbert serve
```

The formula ships prebuilt per-platform binaries and registers an `allbert
serve` service, so `brew services start allbert` runs Allbert in the
background.

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

The installer downloads the artifact for your platform, **verifies its SHA256
against the release's `SHA256SUMS`** (refusing to install on a mismatch),
installs to `~/.local` by default (`ALLBERT_PREFIX` to override), and writes an
uninstall manifest. It never writes to Allbert Home.

## Verifying artifacts yourself

Every release publishes `SHA256SUMS` (and a cosign bundle
`SHA256SUMS.cosign.bundle`). To check a download by hand:

```sh
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

## Upgrades

Upgrading (`brew upgrade allbert`, or re-running the curl installer) replaces
the binary in place. On the first boot of a new version, Allbert **backs up its
database** (a copy under `<Allbert Home>/db/backups/`) before running any schema
migrations, and logs the migrations it applies. If the backup cannot be written,
the boot refuses to migrate rather than proceed unprotected. Automated rollback
is a later (v0.64) capability; the backup is your manual recovery point.

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
phone-home, and no auto-update check**. See
`docs/adr/0076-packaging-distribution-and-unified-cli.md` (Distribution Trust)
for the full posture.
