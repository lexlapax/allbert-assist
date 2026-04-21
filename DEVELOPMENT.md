# Development

This guide describes the repository development contract for Allbert itself.

It is for contributors and coding agents working on the source tree.
It is not the end-user operator guide for running Allbert as a personal assistant.

For end-user/runtime usage, see:
- [README.md](/Users/spuri/projects/lexlapax/allbert-assist/README.md)
- [docs/onboarding-and-operations.md](/Users/spuri/projects/lexlapax/allbert-assist/docs/onboarding-and-operations.md)

## Platform support

Supported contributor platforms in v0.9:
- macOS
- Linux

Out of scope through v0.9:
- Windows native

## Toolchain

Allbert uses a pinned Rust toolchain via `rust-toolchain.toml`.

Required:
- `rustup`
- the pinned Rust toolchain
- `rustfmt`
- `clippy`

The workspace does not require Node, Python, a database service, or OpenSSL for the default build/test path.

Quick setup on macOS/Linux:

```bash
rustup toolchain install 1.94.0 --component rustfmt --component clippy
rustup override set 1.94.0
```

## Canonical validation

The standard contributor green path is:

```bash
cargo fmt --check
env -u RUSTC_WRAPPER cargo clippy --workspace --all-targets -- -D warnings
env -u RUSTC_WRAPPER cargo test -q
env -u RUSTC_WRAPPER cargo run -q -p allbert-cli -- --help
```

Notes:
- `RUSTC_WRAPPER` may be set locally, often to `sccache`, but it must not be assumed.
- Default contributor validation is provider-free and network-optional.
- Passing the commands above is the normal baseline before commit.
- The default `cargo test -q` path intentionally excludes ignored live-provider smokes.

## Temp profile discipline

Contributor smokes should not use your real `~/.allbert` profile.

Use a temporary `ALLBERT_HOME` instead.

Example on macOS/Linux:

```bash
tmpdir="$(mktemp -d)"
ALLBERT_HOME="$tmpdir" env -u RUSTC_WRAPPER cargo run -q -p allbert-cli -- daemon status
rm -rf "$tmpdir"
```

If `mktemp` is awkward in an ephemeral environment such as Codex Web, use a workspace-local temp path instead:

```bash
mkdir -p .tmp/allbert-dev-home
ALLBERT_HOME="$PWD/.tmp/allbert-dev-home" env -u RUSTC_WRAPPER cargo run -q -p allbert-cli -- daemon status
rm -rf .tmp/allbert-dev-home
```

## Validation tiers

### Tier A — required

These are required for normal contributor green status:
- `cargo fmt --check`
- clippy with zero warnings
- full test suite
- CLI help smoke
- temp-home smoke without live providers

### Tier B — optional

These are optional/manual:
- live Anthropic verification
- live OpenRouter verification
- Telegram bot/channel verification
- any checks that require secrets or network

Tier B is not required for routine development or Codex Web work.

Optional Tier B examples:

```bash
env -u RUSTC_WRAPPER cargo test -q -- --ignored
```

Run those only when you intentionally want live verification and the required secrets/network are available.

## Environment variables

Most contributor work requires no secrets.

Optional live-check variables are documented in [.env.example](/Users/spuri/projects/lexlapax/allbert-assist/.env.example).

Common optional variables:
- `ANTHROPIC_API_KEY`
- `OPENROUTER_API_KEY`
- `OPENROUTER_API_KEY_BOOTSTRAP`
- `ALLBERT_HOME` for temp-profile isolation

Telegram testing is also optional and uses filesystem-backed secrets/config under `~/.allbert/`.

If you want a local env file for optional live checks, copy `.env.example` and fill values locally. Do not commit real secrets.

## Codex Web expectations

Codex Web support in v0.9 means the repo’s development cycle works in an ephemeral remote workspace.

It does not mean:
- hosted daemon deployment
- persistent daemon state across browser sessions
- always-available live secrets

Expected Codex Web workflow:
- use the pinned Rust toolchain
- run Tier A validation
- use temp `ALLBERT_HOME`
- treat live-provider checks as optional
- avoid assuming your shell environment matches a personal workstation

Features tied to long-lived local integration, real Telegram channels, or private API keys are better exercised from a real macOS/Linux workstation when needed.
