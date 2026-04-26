# ADR 0100: Kernel facade splits into core and services without crate cycles

Date: 2026-04-26
Status: Accepted
Amends: [ADR 0001](0001-kernel-is-runtime-core-frontends-are-adapters.md), [ADR 0019](0019-v0-2-services-are-supervised-in-process-tasks-with-future-subprocess-seams.md)

## Context

The vision document's first principle is "Kernel first": the runtime core should stay compact, auditable, and secure. [ADR 0001](0001-kernel-is-runtime-core-frontends-are-adapters.md) frames the kernel as runtime core with thin frontend adapters.

Through v0.14, the `allbert-kernel` crate has grown to roughly 40,000 LOC across many public modules, with [`lib.rs`](../../crates/allbert-kernel/src/lib.rs) alone near 10,000 LOC. Large service-like modules now sit next to core runtime contracts:

| Module | Role |
| --- | --- |
| `lib.rs` | agent loop, turn orchestration, parser helpers, exported API |
| `memory/` | durable memory contracts and implementation |
| `config.rs`, `settings.rs`, `paths.rs` | runtime/profile contracts |
| `replay.rs` | trace replay service |
| `self_diagnosis.rs` | diagnosis/remediation service |
| `self_improvement.rs` | source patch proposal service |
| `local_utilities.rs` | utility discovery/enablement service |
| `scripting/` | embedded script service |
| `adapters/` | personalization adapter service |

v0.14.1 deliberately stays focused on truth repair and does not perform a broad structural refactor. v0.14.2 is the dedicated structural release between v0.14.1 and v0.15. v0.15 adds growth-loop ingestion; it needs a service home that does not make the runtime core larger again.

## Decision

v0.14.2 splits the current kernel crate into three crates with an acyclic dependency graph:

```text
allbert-kernel-core      # bottom layer: runtime contracts and core types
        ^
        |
allbert-kernel-services  # owned service implementations
        ^
        |
allbert-kernel           # compatibility facade preserving allbert_kernel::* imports
```

Dependency rules:

- `allbert-kernel-core` depends on neither `allbert-kernel-services` nor `allbert-kernel`.
- `allbert-kernel-services` depends on `allbert-kernel-core`.
- `allbert-kernel` depends on both `allbert-kernel-core` and `allbert-kernel-services`.
- Services must never depend on the facade crate.
- Frontends continue to depend on `allbert-kernel` unless they need a narrow internal core/service crate during migration.

This fixes the crate-cycle problem: the facade can re-export service APIs because it depends on services, and services can consume core contracts because they depend only on core.

## Crate responsibilities

### `allbert-kernel-core`

Owns runtime contracts, shared types, and low-level policies:

- config, settings descriptors, setup/version constants, and path types;
- kernel error type and result aliases;
- provider seam (`LlmProvider`, completion request/response, tool declaration types);
- tool contracts, tool registry traits, tool invocation/output types, and security policy;
- memory contracts and frontmatter schemas used by multiple services;
- hooks, activity/event types, cost accounting contracts, identity/session ids;
- protocol-neutral DTOs shared by daemon, CLI, and services;
- small utility helpers that are genuinely cross-cutting.

The core crate should not know about concrete adapter training, self-diagnosis, self-improvement, replay rendering, local utility catalogs, scripting runtimes, or ingestion.

### `allbert-kernel-services`

Owns behavior modules that are not required for the minimal turn core:

- `adapters/`;
- self-diagnosis and remediation;
- self-improvement;
- local utilities;
- trace replay;
- scripting;
- future v0.15 ingestion service.

Services use `allbert-kernel-core` contracts and paths. They may expose concrete structs, service traits, and helper functions. They do not re-export through the facade themselves.

### `allbert-kernel`

Becomes the compatibility facade:

- re-exports public API from core and services so existing `allbert_kernel::*` imports keep compiling;
- holds compatibility wrappers only where needed to preserve old paths;
- owns no substantial service implementation after the split;
- remains the default crate for frontends and downstream code.

The facade is allowed to depend on both lower crates. Lower crates are not allowed to depend on the facade.

## Public API preservation

Existing public imports remain valid through facade re-exports:

```rust
pub use allbert_kernel_core::{
    AllbertPaths, Config, KernelError, LlmProvider, ToolInvocation, ToolOutput,
};

pub use allbert_kernel_services::adapters::{
    AdapterStore, AdapterManifest, PersonalityAdapterJob,
};

pub use allbert_kernel_services::self_diagnosis::{
    DiagnosisReportArtifact, DiagnosisRunRequest,
};
```

This is a compatibility requirement, not a best-effort goal. v0.14.2 is not allowed to force broad import rewrites in daemon, CLI, jobs, channels, or tests merely because files moved.

## Size and dependency gates

v0.14.2 adds validation scripts wired into the standard local validation path:

- `tools/check_kernel_size.sh`:
  - `crates/allbert-kernel/src/lib.rs` facade < 1,500 LOC;
  - `crates/allbert-kernel-core/src/lib.rs` < 4,000 LOC;
  - `crates/allbert-kernel-core/src/` total < 20,000 LOC;
  - `crates/allbert-kernel-services/src/` total < 25,000 LOC.
- `tools/check_kernel_crate_graph.sh`:
  - rejects any dependency from core to services or facade;
  - rejects any dependency from services to facade;
  - allows facade to depend on both core and services.

New `pub mod` additions to core require reviewer signoff. New service modules should land in services unless they are runtime contracts required by the turn core.

## Consequences

- The runtime core becomes inspectable independently from owned services.
- v0.15 ingestion lands in the services crate rather than growing the core or facade.
- Existing `allbert_kernel::*` imports remain stable through the facade.
- Build boundaries become clearer: most behavior changes touch services, while core changes are reserved for contracts and policy.
- v0.14.2 has no operator-visible behavior change; it is structural preparation.

## Alternatives considered

- **Split into one services crate while keeping `allbert-kernel` as core and also re-exporting services.** Rejected because Rust requires a crate to depend on anything it re-exports; services also need kernel contracts, creating a dependency cycle.
- **Only move files inside the same crate.** Rejected because it does not create enforceable crate boundaries and does not stop future services from growing the core.
- **Multiple per-service crates immediately.** Rejected because it creates too much review surface. One services crate is enough for v0.14.2 and can be split later.
- **Make frontends depend directly on core and services only.** Rejected because it would break the public `allbert_kernel::*` surface and create a large import churn release.
- **Defer the split to v0.15.** Rejected because v0.15 adds ingestion; the structural home should exist first.
