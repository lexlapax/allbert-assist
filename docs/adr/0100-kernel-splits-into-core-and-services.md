# ADR 0100: Kernel splits into core and services without a compatibility facade

Date: 2026-04-26
Status: Accepted
Amends: [ADR 0001](0001-kernel-is-runtime-core-frontends-are-adapters.md), [ADR 0019](0019-v0-2-services-are-supervised-in-process-tasks-with-future-subprocess-seams.md)

## Context

The vision document's first principle is "Kernel first": the runtime core should stay compact, auditable, and secure. [ADR 0001](0001-kernel-is-runtime-core-frontends-are-adapters.md) frames the kernel as runtime core with thin frontend adapters.

Through v0.14, the `allbert-kernel` crate has grown to roughly 40,000 LOC across many public modules, with [`lib.rs`](../../crates/allbert-kernel/src/lib.rs) alone near 10,000 LOC. It now mixes the turn runtime shell, runtime contracts, and concrete service implementations:

| Module | Current role |
| --- | --- |
| `lib.rs` | agent loop, turn orchestration, parser helpers, exported API |
| `config.rs`, `settings.rs`, `paths.rs`, `error.rs` | runtime/profile contracts |
| `llm/provider.rs` | provider contracts |
| `llm/{anthropic,gemini,ollama,openai,openrouter}.rs` | concrete provider clients |
| `tools/`, `tool_call_parser.rs`, `security/` | tool and policy contracts plus runtime helpers |
| `memory/` | memory DTOs plus durable memory/indexing implementation |
| `skills/` | skill validation, store, and prompt rendering |
| `replay.rs`, `trace.rs` | trace contracts plus concrete storage/export/setup |
| `self_diagnosis.rs` | diagnosis/remediation service |
| `self_improvement.rs` | source patch proposal service |
| `local_utilities.rs` | utility discovery/enablement service |
| `scripting/` | embedded Lua script service |
| `adapters/`, `learning.rs` | personalization adapter and learning services |
| `heartbeat.rs` | heartbeat implementation |

v0.14.1 deliberately stayed focused on truth repair and did not perform a broad structural refactor. v0.14.2 is the dedicated structural release between v0.14.1 and v0.15. v0.15 adds growth-loop ingestion; it needs a service home that does not make the runtime core larger again.

The project does not need Rust crate backward compatibility for `allbert-kernel` at this stage. Preserving the old `allbert_kernel` import surface would add a compatibility facade whose only purpose is API stability. Without that requirement, the facade would hide ownership, keep old paths alive, and create one more crate boundary to police.

## Decision

v0.14.2 retires the monolithic `allbert-kernel` crate and replaces it with two final crates:

```text
allbert-kernel-core      # runtime shell, contracts, shared policy, DTOs
        ^
        |
allbert-kernel-services  # concrete service implementations and default runtime wiring
```

Dependency rules:

- `allbert-kernel-core` depends on neither `allbert-kernel-services` nor the retired `allbert-kernel` package.
- `allbert-kernel-services` depends on `allbert-kernel-core`.
- CLI, daemon, jobs, and tests import directly from core and services.
- No workspace crate depends on `allbert-kernel` at v0.14.2 release exit.
- The old `allbert-kernel` crate may exist only as a temporary migration holding crate while modules are moved. It must not become a facade or re-export moved APIs.

This keeps the final crate graph acyclic without preserving a compatibility layer.

## Crate responsibilities

### `allbert-kernel-core`

Owns runtime contracts, shared types, low-level policies, and the generic turn runtime shell:

- config, settings descriptors, setup/version constants, and path types;
- kernel error type and result aliases;
- provider seam (`LlmProvider`, completion request/response, tool declaration types);
- tool contracts, tool registry traits, tool invocation/output types, and security policy;
- memory DTOs and frontmatter schemas used by multiple services;
- hooks, activity/event types, cost accounting contracts, identity/session ids;
- protocol-neutral DTOs shared by daemon, CLI, and services;
- `KernelRuntime`, session/turn state, prompt assembly contracts, and tool-dispatch shell;
- service traits used by `KernelRuntime` to call concrete behavior;
- small utility helpers that are genuinely cross-cutting.

The core crate must not know about concrete adapter training, concrete provider HTTP clients, Tantivy indexing, self-diagnosis, self-improvement, replay rendering/storage, local utility catalogs, Lua scripting runtime, heartbeat file logic, or ingestion.

### `allbert-kernel-services`

Owns behavior modules and default runtime wiring:

- `DefaultKernelServices`;
- concrete runtime entrypoint, such as `Kernel = KernelRuntime<DefaultKernelServices>`;
- concrete LLM providers;
- concrete memory storage, staging, and indexing;
- skill store, validation, and prompt rendering;
- adapters and learning/personality digest;
- self-diagnosis and remediation;
- self-improvement;
- local utilities;
- trace replay and concrete trace storage/export/setup;
- scripting and Lua runtime;
- heartbeat implementation;
- future v0.15 ingestion service.

Services use `allbert-kernel-core` contracts and paths. They may expose concrete structs, service traits, and helper functions. They must not depend on the retired `allbert-kernel` crate.

## Import migration

v0.14.2 intentionally changes Rust import paths. Examples:

```rust
use allbert_kernel_core::{AllbertPaths, Config, KernelError};
use allbert_kernel_core::llm::{CompletionRequest, CompletionResponse, LlmProvider};
use allbert_kernel_core::tools::{ToolInvocation, ToolOutput};

use allbert_kernel_services::Kernel;
use allbert_kernel_services::adapters::{AdapterStore, PersonalityAdapterJob};
use allbert_kernel_services::memory::list_staged_memory;
use allbert_kernel_services::skills::{validate_skill_path, SkillProvenance};
use allbert_kernel_services::self_diagnosis::{
    DiagnosisReportArtifact, DiagnosisRemediationRequest,
};
```

The implementation must add a checked-in migration inventory generated from the current `pub mod` and `pub use` surface. The inventory maps each old symbol or module to its new core/services path.

Release exit fails if workspace Rust source or Cargo manifests still depend on or import `allbert-kernel` / `allbert_kernel`, except for historical docs and explicit migration notes.

## Size, graph, and dependency gates

v0.14.2 adds validation scripts wired into the standard local validation path:

- `tools/check_kernel_size.sh`:
  - `crates/allbert-kernel-core/src/lib.rs` < 4,000 LOC;
  - `crates/allbert-kernel-core/src/` total < 20,000 LOC;
  - `crates/allbert-kernel-services/src/` total < 30,000 LOC;
  - `crates/allbert-kernel/` is not a workspace member at release exit.
- `tools/check_kernel_crate_graph.sh`:
  - rejects any dependency from core to services or the retired monolith;
  - rejects any dependency from services to the retired monolith;
  - rejects any workspace dependency on `allbert-kernel`;
  - allows CLI, daemon, jobs, and tests to depend directly on core and services.
- Dependency compactness check:
  - core may own contract-level dependencies such as `allbert-proto`, `serde`, `serde_json`, `toml`, `toml_edit`, `thiserror`, `async-trait`, `time`, `chrono`, `chrono-tz`, `uuid`, `dirs`, `fs2`, `sha2`, and `regex`;
  - core must not own concrete service/runtime-heavy dependencies such as `reqwest`, `tantivy`, `mlua`, `tracing-subscriber`, `tracing-appender`, `pulldown-cmark`, `serde_yaml`, `flate2`, `base64`, `tempfile`, or trainer subprocess implementation dependencies as normal dependencies;
  - services owns concrete provider HTTP clients, memory indexing, Lua, trace subscriber/appender setup, markdown/YAML parsing, compression/export helpers, local utility runtime, adapter trainer implementations, and self-improvement process helpers.

New core modules require reviewer signoff. New concrete behavior modules land in services unless they are runtime contracts required by the turn shell.

## Consequences

- The runtime core becomes inspectable independently from owned services.
- v0.15 ingestion lands in services rather than growing core.
- CLI, daemon, jobs, and tests get explicit import churn in v0.14.2.
- The final crate graph is simpler than the facade design: core below services, with no third compatibility layer.
- The release remains operator-invisible: no protocol bump, storage migration, command change, or behavior change is required by the split.

## Alternatives considered

- **Keep `allbert-kernel` as a compatibility facade.** Rejected because backward compatibility is not required and a facade would preserve obsolete paths, hide ownership, and add gates that exist only to maintain old imports.
- **Split into one services crate while keeping `allbert-kernel` as core and also re-exporting services.** Rejected because Rust requires a crate to depend on anything it re-exports; services also need core contracts, creating a dependency cycle.
- **Only move files inside the same crate.** Rejected because it does not create enforceable crate boundaries and does not stop future services from growing the core.
- **Multiple per-service crates immediately.** Rejected because it creates too much review surface. One services crate is enough for v0.14.2 and can be split later.
- **Defer the split to v0.15.** Rejected because v0.15 adds ingestion; the structural home should exist first.
