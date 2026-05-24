# Elixir Sandbox And Gate Runner Operator Guide

Status: v0.36 implementation contract.

The v0.36 sandbox is a default-off local OS isolation boundary for generated
Elixir/OTP drafts and explicit gate commands. It produces bounded reports only.
A passing report does not load code, register actions, grant permissions,
enable skills, change routes, or set app routing context.

## Safety Defaults

- Keep `sandbox.elixir.enabled=false` unless actively testing generated
  Elixir/OTP drafts.
- Use a disposable `ALLBERT_HOME` for smoke testing and release verification.
- Do not point sandbox bundles at a real operator home, settings root, secrets,
  database, memory, or cache.
- Use only approved local images. The runner must never pull images from a
  registry during a sandbox run.
- Keep `sandbox.elixir.network=none`; v0.36 has no network-enabled profile.

## Settings

| Key | Default | Purpose |
|---|---:|---|
| `sandbox.elixir.enabled` | `false` | Master switch for v0.36 sandbox runs. |
| `sandbox.elixir.backend` | `auto` | OS-aware backend resolver or explicit backend pin. |
| `sandbox.elixir.image` | `allbert-elixir-otp:local` | Approved local Elixir/OTP image reference. |
| `sandbox.elixir.network` | `none` | Network policy. v0.36 accepts only `none`. |
| `sandbox.elixir.cpu_limit` | `1.0` | CPU quota passed to the backend within bounded limits. |
| `sandbox.elixir.memory_mb` | `1024` | Memory limit passed to the backend. |
| `sandbox.elixir.timeout_ms` | `120000` | Default wall-clock command timeout. |
| `sandbox.elixir.output_bytes` | `65536` | stdout/stderr report cap per command. |

Enable only in a disposable smoke home:

```sh
export SMOKE_HOME="$(mktemp -d /tmp/allbert-v036-smoke.XXXXXX)"
ALLBERT_HOME="$SMOKE_HOME" mix allbert.settings set sandbox.elixir.enabled true
ALLBERT_HOME="$SMOKE_HOME" mix allbert.sandbox doctor
```

## Backend Selection

`sandbox.elixir.backend=auto` resolves through an OS-aware chain:

- macOS on Apple silicon with macOS 26 or newer: `apple_container` when doctor
  verifies the host and CLI policy support, then `docker_runsc`, then `docker`.
- macOS on older versions or Intel: `docker_runsc`, then `docker`.
- Linux: `podman_rootless`, then `docker_runsc`, then `docker`.

Operators may pin `apple_container`, `podman_rootless`, `docker_runsc`, or
`docker`. A pinned backend fails closed when unavailable or unable to enforce
v0.36 policy.

## Doctor

Run:

```sh
ALLBERT_HOME="$SMOKE_HOME" mix allbert.sandbox doctor
```

Expected output includes:

- whether the sandbox is enabled;
- the configured backend and resolved backend;
- each candidate considered and its availability reason;
- image-local status;
- network and resource limits;
- report and bundle roots;
- fail-closed diagnostics when no supported backend is available.

Doctor must not run untrusted draft code.

## Bundle And Reports

Allbert creates these roots under Allbert Home:

```text
<ALLBERT_HOME>/sandbox/bundles
<ALLBERT_HOME>/sandbox/reports
<ALLBERT_HOME>/sandbox/cache
```

Each bundle receives a disposable sandbox home inside the bundle. The real
operator home is never mounted into the container. Reports are copied out to
the sandbox report root and surfaced read-only.

## Failure States

Treat these as expected fail-closed results:

- sandbox disabled;
- no backend on the current OS can enforce policy;
- pinned backend unavailable;
- configured image is missing or not approved locally;
- command is not `mix`, `elixir`, or `erl`;
- argv shape requests package installs, migrations, shell syntax, eval,
  daemon control, network, NIFs, ports, or core-node loading;
- source policy finds forbidden Elixir constructs;
- output exceeds the configured cap or command exceeds timeout.

## Emergency Posture

Disable immediately with:

```sh
mix allbert.settings set sandbox.elixir.enabled false
```

Then inspect:

```sh
mix allbert.sandbox doctor
mix allbert.security review --recent --limit 25
```

Sandbox reports are evidence. They are not trust grants.
