# Development

This guide describes the repository development contract for Allbert itself.

It is for contributors and coding agents working on the source tree.
It is not the end-user operator guide for running Allbert as a personal assistant.

For end-user/runtime usage, see:
- [README.md](README.md)
- [docs/onboarding-and-operations.md](docs/onboarding-and-operations.md)

## Platform support

Supported contributor platforms in v0.10:
- macOS
- Linux

Out of scope through v0.10:
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

## Canonical smoke recipes

Local macOS/Linux smoke:

```bash
tmpdir="$(mktemp -d)"
ALLBERT_HOME="$tmpdir" env -u RUSTC_WRAPPER cargo run -q -p allbert-cli -- daemon status
rm -rf "$tmpdir"
```

Codex Web / ephemeral workspace smoke:

```bash
mkdir -p .tmp/allbert-smoke-home
ALLBERT_HOME="$PWD/.tmp/allbert-smoke-home" env -u RUSTC_WRAPPER cargo run -q -p allbert-cli -- daemon status
rm -rf .tmp/allbert-smoke-home
```

These recipes are intentionally:
- provider-free
- safe against a real profile
- compatible with the documented Tier A contributor posture

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
- live hosted-provider verification
- local Ollama/Gemma4 verification
- Telegram bot/channel verification
- any checks that require secrets or network

Tier B is not required for routine development or Codex Web work.

Optional Tier B examples:

```bash
env -u RUSTC_WRAPPER cargo test -q -- --ignored
```

Run those only when you intentionally want live verification and the required secrets/network are available.

More targeted provider checks:

```bash
env -u RUSTC_WRAPPER cargo test -q -p allbert-kernel anthropic_release_smoke -- --ignored --exact
env -u RUSTC_WRAPPER cargo test -q -p allbert-kernel openrouter_release_smoke -- --ignored --exact
env -u RUSTC_WRAPPER cargo test -q -p allbert-kernel openai_release_smoke -- --ignored --exact
env -u RUSTC_WRAPPER cargo test -q -p allbert-kernel gemini_release_smoke -- --ignored --exact
env -u RUSTC_WRAPPER cargo test -q -p allbert-kernel ollama_release_smoke -- --ignored --exact
```

## Environment variables

Most contributor work requires no secrets.

Optional live-check variables are documented in [.env.example](.env.example).

Common optional variables:
- `ANTHROPIC_API_KEY`
- `OPENROUTER_API_KEY`
- `OPENROUTER_API_KEY_BOOTSTRAP`
- `OPENAI_API_KEY`
- `GEMINI_API_KEY`
- `OLLAMA_BASE_URL`
- `ALLBERT_HOME` for temp-profile isolation

Telegram testing is also optional and uses filesystem-backed secrets/config under `~/.allbert/`.

Optional Telegram prerequisites:
- `~/.allbert/secrets/telegram/bot_token`
- `~/.allbert/config/channels.telegram.allowed_chats`

If you want a local env file for optional live checks, copy `.env.example` and fill values locally. Do not commit real secrets.

## Codex Web expectations

Codex Web support means the repo’s development cycle works in an ephemeral remote workspace.

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

Suggested Codex Web checklist:

1. Confirm the pinned toolchain is active.
2. Run Tier A validation before and after meaningful changes.
3. Use a workspace-local temp `ALLBERT_HOME` for any smoke that touches daemon/profile state.
4. Do not depend on a long-lived daemon surviving across Codex workspace lifetimes.
5. Treat live-provider and Telegram checks as optional follow-up work, not the default gate.
6. Prefer small, milestone-scoped commits so interrupted remote sessions do not strand large uncommitted changes.

Features tied to long-lived local integration, real Telegram channels, or private API keys are better exercised from a real macOS/Linux workstation when needed.
