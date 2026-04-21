# Repository AGENTS.md

This file is for contributors and coding agents working on the Allbert source tree.

It is **not** the same thing as the runtime-generated `~/.allbert/AGENTS.md` file that the product injects into prompt context. That runtime file is kernel-owned product state. This file is repository workflow guidance only.

## Default workflow

Use this validation order unless a task explicitly calls for something narrower:

```bash
cargo fmt --check
env -u RUSTC_WRAPPER cargo clippy --workspace --all-targets -- -D warnings
env -u RUSTC_WRAPPER cargo test -q
env -u RUSTC_WRAPPER cargo run -q -p allbert-cli -- --help
```

## Contributor rules

- Prefer provider-free validation first.
- Treat live-provider and Telegram checks as optional follow-up verification, not the default gate.
- Use a temporary `ALLBERT_HOME` for smokes. Do not rely on the contributor’s real `~/.allbert`.
- Keep docs and ADRs aligned with shipped code when a task changes roadmap or runtime behavior.
- When changing release sequencing, update:
  - `docs/plans/roadmap.md`
  - `docs/vision.md`
  - any affected plan docs
  - any ADRs that mention the moved release

## Environment assumptions

- Supported contributor platforms: macOS and Linux
- Toolchain manager: `rustup`
- Pinned Rust toolchain: see `rust-toolchain.toml`
- `RUSTC_WRAPPER` must not be assumed

## Smokes

Safe smoke checks should prefer:
- temp-profile CLI/daemon commands
- fake-provider-backed tests already in the workspace
- no dependence on live network or private credentials

## Commits

- Keep commits scoped to the milestone or doc pass when practical.
- If a task is docs-only, do not invent code changes.
- If a task changes repo workflow, make sure the repo-level docs are updated, not just end-user docs.
