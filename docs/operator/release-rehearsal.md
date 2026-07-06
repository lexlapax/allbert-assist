# Release & Install Rehearsal (v0.62)

The operator runbook for cutting a v0.62 release and validating the packaged
`allbert` on each Tier-1 OS before announcing it. Two automated layers precede
this (`mix allbert.test release.v062` and the CI artifact smoke); this doc covers
the steps that need a real host, a published release, or your credentials.

## 1. Publish the release (operator)

The tag is operator-held (Locked Decision 16). Cutting the release:

```sh
git tag v0.62.0            # on the reviewed commit
git push origin v0.62.0
```

The tag push fires `.github/workflows/release-artifacts.yml`:

- **build** (macos-arm64, linux-x64, linux-arm64): builds the OTP release and runs
  `scripts/smoke/artifact_smoke.sh` per target — boot, version, plugin
  registration, `/health`, a **genuine attach round-trip**, no-Mix-modules, and
  ERTS crypto linkage, all through an operator-style symlink.
- **publish** (tag only): collects the per-target tarballs, adds version-less
  aliases (`allbert-<target>.tar.gz` for the `latest` install path), writes and
  cosign-signs `SHA256SUMS`, and uploads everything to the GitHub release.

You can dry-run the build+smoke without publishing at any time:

```sh
gh workflow run release-artifacts.yml --ref main   # build + smoke, no publish
gh run watch
```

## 2. Fill the Homebrew tap (operator)

The tap lives at [`lexlapax/homebrew-allbert`](https://github.com/lexlapax/homebrew-allbert)
(`Formula/allbert.rb`, SHA256 placeholders). After the release publishes:

```sh
gh release download v0.62.0 --repo lexlapax/allbert-assist --pattern SHA256SUMS --dir /tmp
git clone https://github.com/lexlapax/homebrew-allbert && cd homebrew-allbert
# use the helper from an allbert-assist checkout:
sh ../allbert-assist/homebrew/fill-sha256.sh /tmp/SHA256SUMS Formula/allbert.rb
git commit -am "allbert v0.62.0" && git push
```

## 3. Per-OS install rehearsal

Do this on each Tier-1 OS. Your data (Allbert Home, `~/.allbert`) and the login
keychain are never touched by install/uninstall (absent `--purge`).

### curl installer (macOS + Linux)

```sh
curl -fsSL https://raw.githubusercontent.com/lexlapax/allbert-assist/main/scripts/install/install.sh | sh
#   ALLBERT_VERSION=v0.62.0   pin a version (default: latest)
#   ALLBERT_PREFIX=~/.local   install prefix
export PATH="$HOME/.local/bin:$PATH"
allbert --version                 # allbert 0.62.0
allbert admin status              # renders the operator status through the spine
```

### Homebrew (macOS + Linux)

```sh
brew tap lexlapax/allbert
brew install allbert
allbert --version
brew services start allbert       # or: allbert serve
```

### serve + health + attach

```sh
allbert serve &                                   # foreground daemon (holds the writer lock + attach listener)
curl -s http://localhost:4000/health              # {"status":"ok",...}
allbert admin status                              # attaches to the running daemon (no second writer)
```

### service (launchd / systemd, confirmation-gated)

```sh
allbert admin service install --dry-run           # preview the exact launchctl/systemctl commands
allbert admin service install                     # -> needs_confirmation
allbert admin confirmations approve <ID>          # installs the per-user service
# macOS: ~/Library/LaunchAgents/…; Linux: systemctl --user (linger for boot-start)
allbert admin service uninstall                   # (confirmation-gated) removes the unit
```

### secret vault (macOS Keychain / Linux Secret Service)

```sh
allbert admin vault                               # shows the resolved tier (os on a desktop)
# set a provider key (needs the settings master key configured), then:
allbert admin secrets migrate                     # -> needs_confirmation
allbert admin confirmations approve <ID>          # moves encrypted-store secrets into the OS vault
```

Headless Linux (no D-Bus keyring) resolves to the encrypted-file tier with a
surfaced notice — see [security-hardening.md](security-hardening.md).

### uninstall (Home preserved)

```sh
sh scripts/install/uninstall.sh                   # removes installed files; Allbert Home preserved
sh scripts/install/uninstall.sh --purge           # also removes Allbert Home
brew uninstall allbert                            # if installed via Homebrew
```

## 4. Verified evidence

- **CI artifact matrix** (`release-artifacts.yml`, run on the pushed commit):
  macos-arm64, linux-x64, linux-arm64 build + smoke green (7/7 checks each,
  through the operator-style symlink).
- **CI Linux rehearsal** (`linux-rehearsal` job, ubuntu-22.04, 2026-07-06): all
  checks green — install (symlink) → `--version`/`admin status`/`/health`/attach
  (*served by the daemon*) → **Secret Service vault**: `secret-tool` round-trip +
  `admin vault` reports the `os` tier → systemd `--user` service dry-run +
  **user systemd present** → uninstall (**Home preserved**).
- **macOS local rehearsal (2026-07-06, on macos-arm64):** `install.sh` (checksum
  verified) → symlinked `allbert --version` / `admin status` / `admin vault`
  (Keychain `os` tier) RC 0; `allbert serve` → `/health` `status:ok` → attach
  round-trip *served by the running daemon*; `admin secrets migrate`
  confirmation-gated with the CLI approve guidance; the tier-1 Keychain
  add/find/delete mechanism verified on the host; `admin service install
  --dry-run` previews without executing; `uninstall.sh` removes the binary and
  **preserves Allbert Home**. This rehearsal caught and fixed a real
  symlink-resolution bug in the dispatcher (M8.12).

### Scripted Linux rehearsal

`scripts/smoke/linux_rehearsal.sh <extracted-release-root>` runs the whole Linux
flow (install via symlink → CLI smoke → Secret Service vault → systemd `--user`
service surface → uninstall). It runs automatically as the `linux-rehearsal` CI
job on every workflow run; on a real host, run it inside a keyring session for
the vault step:

```sh
sudo apt-get install -y gnome-keyring libsecret-tools dbus-x11
dbus-run-session -- bash -c '
  echo pass | gnome-keyring-daemon --unlock --components=secrets
  bash scripts/smoke/linux_rehearsal.sh /path/to/allbert'
```

## 5. Remaining operator S-steps

- Live **Linux** install/serve/service/vault rehearsal on a real Linux host
  (CI covers Linux build+smoke; the interactive service/keychain steps need a
  host).
- The full **secret-migrate → Keychain/Secret-Service** round-trip with a real
  settings master key configured (`ALLBERT_SETTINGS_MASTER_KEY`, valid format).
- A live interactive `allbert tui` session (needs a TTY; not covered by CI smoke).
