# ADR 0100: Kernel splits into kernel-core and kernel-services without changing public API

Date: 2026-04-26
Status: Accepted

## Context

The vision document's first principle is "Kernel first… stay compact, auditable, and secure." [ADR 0001](0001-kernel-is-runtime-core-frontends-are-adapters.md) frames the kernel as the runtime core with thin frontend adapters.

Through v0.14, the `allbert-kernel` crate has grown to ~40,000 LOC across 28 public modules, with [`lib.rs`](../../crates/allbert-kernel/src/lib.rs) alone at 9,864 LOC. Module distribution by size:

| Module | LOC |
| --- | --- |
| `lib.rs` | 9,864 |
| `memory/curated.rs` | 4,242 |
| `config.rs` | 2,855 |
| `settings.rs` | 2,571 |
| `replay.rs` | 2,090 |
| `self_diagnosis.rs` | 1,532 |
| `tools/mod.rs` | 1,462 |
| `self_improvement.rs` | 1,242 |
| `local_utilities.rs` | 1,223 |
| `skills/mod.rs` | 1,206 |
| `adapters/job.rs` | 918 |
| `learning.rs` | 712 |
| ... | ... |

There is no internal boundary between "kernel core" (agent loop, hooks, policy envelope, memory contracts, provider seam) and "kernel-owned services" (adapters, self-diagnosis, local utilities, replay, scripting, self-improvement). Every release added a new `pub mod` to `lib.rs`. The kernel has gradually become a kitchen sink that the origin warned against ("the runtime should not be bloated").

v0.15 will add ingestion ([growth loop](../plans/v0.15-growth-loop.md)) and v0.16+ will add more services. Without a structural split, the trend continues.

## Decision

v0.14.1 splits the kernel along the internal boundary it already has implicitly. A new sibling crate `allbert-kernel-services` holds owned services. `allbert-kernel` retains the runtime core.

### Module relocation

Moves to `allbert-kernel-services`:

- `adapters/` (8 files, ~3500 LOC)
- `self_diagnosis.rs`
- `self_improvement.rs`
- `local_utilities.rs`
- `replay.rs`
- `scripting/`

Stays in `allbert-kernel`:

- agent loop (`agent.rs`)
- hooks (`hooks.rs`)
- policy envelope (`security/`)
- memory contracts (`memory/`)
- intent classification (`intent.rs`)
- identity (`identity.rs`)
- provider seam (`llm/`)
- tools registry (`tools/`)
- skills loader (`skills/`)
- session management (`heartbeat.rs`, paths, etc.)

### Trait seams

`allbert-kernel` defines narrow traits for each owned service:

```rust
pub trait DiagnosisService: Send + Sync {
    fn run_diagnosis(&self, ...) -> Result<DiagnosisReportArtifact, KernelError>;
    fn list_reports(&self, ...) -> Result<Vec<DiagnosisListEntry>, KernelError>;
    fn read_report(&self, ...) -> Result<DiagnosisReportArtifact, KernelError>;
}

pub trait AdapterService: Send + Sync {
    fn list(&self) -> Result<Vec<AdapterManifest>, KernelError>;
    fn show(&self, id: &str) -> Result<AdapterManifest, KernelError>;
    // ...
}

pub trait LocalUtilitiesService: Send + Sync { ... }
pub trait ReplayService: Send + Sync { ... }
pub trait ScriptingService: Send + Sync { ... }
pub trait SelfImprovementService: Send + Sync { ... }
```

`allbert-kernel-services` implements these traits against the same paths and config the kernel already uses. No new disk format, no new event kinds.

### Public API preservation

`allbert-kernel/src/lib.rs` re-exports the moved public types:

```rust
pub use allbert_kernel_services::adapters::{AdapterStore, AdapterManifest, ...};
pub use allbert_kernel_services::self_diagnosis::{
    SelfDiagnosisConfig, DiagnosisReportArtifact, ...,
};
// ...
```

External consumers (`allbert-daemon`, `allbert-cli`, `allbert-channels`, `allbert-jobs`, downstream crates if any) keep using `allbert_kernel::SelfDiagnosisConfig`, `allbert_kernel::AdapterStore`, etc. without changing imports. The split is invisible to operators.

### Dependency direction

`allbert-kernel` does not depend on `allbert-kernel-services`. The dependency goes the other way. Frontend crates (`allbert-daemon`, `allbert-cli`, `allbert-channels`, `allbert-jobs`) depend on both crates.

The kernel core can be built and tested without the services crate, which keeps the core auditable independently. This also enables future deployments (embedded, restricted-feature builds) that omit services.

### Size targets

After the split:

- `crates/allbert-kernel/src/lib.rs` < 4,000 LOC.
- `crates/allbert-kernel/src/` total < 20,000 LOC.
- `crates/allbert-kernel-services/src/` < 20,000 LOC.

These are tested via a `tools/check_kernel_size.sh` script wired into `cargo test` (alongside the [ADR 0095](0095-doc-reality-reconciliation-gates-are-ci-checks.md) doc-reality gate). New `pub mod` additions to the kernel core require explicit reviewer signoff; the size check fails the build if the targets regress.

## Consequences

- The kernel core stays inspectable by a contributor in an afternoon, matching the origin's "compact, auditable" principle.
- Adding new services (v0.15 ingestion, v0.16+ adapters) lands in `allbert-kernel-services` without growing the core.
- Public API surface for daemon/CLI/channels/jobs is unchanged. Existing tests continue to pass with no source changes outside the moved files and trait seams.
- Build times marginally improve because changes to a service no longer recompile the kernel core.
- ADR 0001's framing ("kernel is runtime core") is reaffirmed structurally, not just narratively.

## Alternatives considered

- **Multiple per-service crates.** Considered; rejected for v0.14.1 because creating six new crates at once is a large surface to review. The single `allbert-kernel-services` crate can be split further later if any service grows large enough to warrant its own crate.
- **In-place refactor of `lib.rs` without a new crate.** Considered; rejected because the size target (lib.rs < 4000) cannot be met without moving substantial code, and moving to a sibling crate is the cleanest way to preserve public API.
- **Feature-gate services within `allbert-kernel`.** Considered; rejected because feature gates create N×M test matrices and obscure which surfaces are present at runtime. Crate boundaries are clearer.
- **Defer the split to v0.15.** Rejected because v0.15 will add new services; doing the split first prevents the new ingestion module from being added to the wrong crate.
