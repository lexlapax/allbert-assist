# ADR 0058: Key Custody And External Channel-Daemon Supervision

## Status

Proposed for v0.53 Channel Pack 2 + system-wide constructs
(`docs/plans/v0.53-plan.md`). Flips to Accepted at v0.53 M10 closeout after
release evidence.

This ADR adds two related system-wide constructs that v0.53 forces but that
benefit the whole runtime:

1. **Key Custody** — a single supervised in-BEAM process that decrypts the
   master-key-encrypted secret store once and serves secret material to in-VM
   callers, instead of re-decrypting on every read.
2. **External channel-daemon supervision** — the supervised lifecycle and
   key/socket custody for a long-running external process that holds a channel's
   credential material on disk (the `signal-cli` daemon; reusable for a future
   WhatsApp-web bridge or iMessage relay).

## Context

Allbert already encrypts user-supplied secrets at rest: `Settings.Secrets` uses
AES-256-GCM via raw `:crypto`, a master key resolved from
`ALLBERT_SETTINGS_MASTER_KEY` env → app config → a `0600` `.settings_key` file
under Allbert Home, a single `secrets.yml.enc` envelope, and `secret://...`
references. It **re-reads and re-decrypts the whole envelope on every
`get_secret/2`** — there is no in-memory cache and no single process that holds
decrypted material. `plug_crypto` is already in the dependency tree; `cloak`,
`enacl`, `libvault`, `erlexec`, and `muontrap` are not.

v0.53 adds Signal, whose only viable integration is to **supervise an external
`signal-cli` daemon** that holds a Signal account's E2EE key material on disk and
speaks JSON-RPC over a local socket. That raises two questions at once: where do
decrypted secrets live in the running app, and how does Allbert supervise an
external key-holding process under the AGENTS.md rule that bridge/daemon
processes need an explicit permission/confirmation/sandbox/trace story.

A library/pattern survey (2025-2026) was decisive for a single-operator,
local-first app:

- **In-BEAM custody is the right default.** A separate OS key-daemon does **not**
  improve the trust boundary when the BEAM is the secret consumer — the moment
  the BEAM asks for and receives plaintext, the material is back in BEAM memory
  with the same limitations. Vault/OpenBao are server overkill (a second daemon
  to unseal, back up, secure). OS keychains have no maintained Elixir binding and
  are headless-hostile; useful only as an optional master-key provider.
- **Locked/zeroed memory is not achievable on the BEAM** and must not be claimed.
  BEAM data is immutable, binaries are copied and not zeroed on free, and no
  maintained Elixir library exposes `sodium_malloc`/`mlock`. `enacl`'s
  `unsafe_memzero/1` cannot reach copies already made. Any claim of
  "keys in protected/locked memory, zeroed after use" is security theater.
- **External-process supervision** is best served by `MuonTrap` (Linux: cgroup
  kill + memory bounds, no orphans) with `erlexec` as the cross-platform/macOS
  development option. Raw `Port` orphans grandchildren on a BEAM crash.

## Decision

### Key Custody (in-BEAM, zero new mandatory deps)
- `AllbertAssist.Settings.KeyCustody` is a supervised GenServer under the
  Settings supervision tree. It resolves the master key via the existing
  `Settings.Secrets` master-key chain and decrypts `secrets.yml.enc` **once**,
  holding the decrypted secret map in process state and serving it to in-VM
  callers through a thin `fetch/1` API. `put_secret`/`delete_secret` invalidate
  or refresh the cache so it stays correct. Built on the existing `:crypto`
  AES-256-GCM scheme + `plug_crypto` — **no new mandatory dependency**.
- Hardening that is actually achievable and required:
  - `:erlang.process_flag(:sensitive, true)` in `init/1` — excludes the process
    heap/stack from `erl_crash.dump` and blocks `:sys.get_state`/`:observer`
    introspection. (Highest-value control.)
  - `format_status/1` masks state; a custom `Inspect` prints no secret material;
    each secret is held as a zero-arity closure so accidental `inspect`/exception
    renders `#Fun<...>`, never the value.
  - `Plug.Crypto.prune_args_from_stacktrace/1` around key-taking functions;
    `Plug.Crypto.secure_compare/2` for token comparison; every fetch audited
    through `Settings.Audit`; reads never logged un-redacted.
  - Secrets never placed in public ETS, never in signals/traces/`channel_events`
    (existing `Runtime.Redactor`/`Security.Redactor` gating preserved).
- **Honest scope (normative):** the plan and docs may claim only that secret
  material is decrypted once, held in one `:sensitive` supervised process,
  excluded from crash dumps and introspection, never logged, and redacted on
  inspect. They must **not** claim locked/protected/non-swappable/zeroed memory,
  or that an in-BEAM process is isolated from other in-VM modules (the BEAM has
  no in-VM capability boundary; in-process isolation is advisory). Master-key
  sourcing keeps env/config/`.settings_key` (0600); an OS-keychain master-key
  provider may be added as one optional branch, never required.

### External channel-daemon supervision
- A channel that needs an external key-holding daemon supervises it as a child of
  the channel's plugin supervisor using **`MuonTrap` (Linux deployments)** or
  **`erlexec` (macOS/dev)** — the single new dependency this ADR introduces. Raw
  `Port` is not used for a long-running daemon.
- The daemon's key material lives under Allbert Home (`<ALLBERT_HOME>/<channel>/`,
  directory `0700`, key files `0600`, enforced with `File.chmod`, mirroring the
  existing `.settings_key` pattern). The control channel is a **`0600` UNIX
  socket or `127.0.0.1`-only** endpoint — never a public bind.
- Starting/stopping/pairing the daemon is an explicit, audited operator action;
  the daemon grants no Allbert authority by existing — all effectful work still
  routes through registered actions, Security Central, confirmations, traces, and
  audits. The daemon is a delivery transport, not an authority path (ADR 0016).
- For Signal specifically: `signal-cli` in daemon mode exposing JSON-RPC over a
  `0600` local socket; account keys under `<ALLBERT_HOME>/signal/`; device
  linking (QR) is an audited operator action.

## Consequences
- Decrypted secrets stop being re-derived per read and live in one hardened,
  introspection-excluded process; the win is real and the limits are stated
  honestly rather than oversold.
- v0.53 adds exactly one new dependency for daemon supervision
  (`muontrap`, with `erlexec` for macOS/dev); KeyCustody adds none.
- The daemon-supervision construct is reusable: a future WhatsApp-web bridge,
  Signal, or iMessage relay inherit it rather than re-solving supervision/trust.
- The v0.53 eval set covers: KeyCustody never leaks via inspect/`:sys.get_state`/
  crash-dump fixtures, fetch is audited, the signal-cli socket is localhost/0600,
  and daemon credential files are 0600.

## Related
- ADR 0016 (channel boundary — daemon is transport, not authority), ADR 0006
  (Security Central), ADR 0009 (process/sandbox bounds), ADR 0046 (settings
  schema), ADR 0049 (development lanes), ADR 0050 (dependency/toolchain
  compatibility — `muontrap`/`erlexec`).
- ADR 0059 (channel trust-class — Signal is an `e2ee_origin` channel).
- `docs/plans/v0.53-plan.md`, `docs/plans/v0.53-request-flow.md`.
