# Allbert Future Features Parking Lot

This file tracks work that is not assigned to a concrete roadmap milestone.
It is a strict parking lot, not release history and not a duplicate roadmap.

For planned work, use `docs/plans/roadmap.md` and the matching versioned plan.
When a parked item is partially promoted, keep only the unplanned remainder
here.

## Parked Future Features

### System Memory Distillation

Status: parked.

v0.39 plans deterministic Active Memory retrieval. v0.46 plans
operator-supervised trace-derived draft suggestions. Neither trains,
distills, or creates a learned system-memory authority.

Still parked:

- nightly memory/personality distillation;
- small local model training from operator history;
- learned system-memory models that influence runtime behavior;
- deletion, reproducibility, privacy, and eval policy for any trained memory
  artifact.

### Autonomous Skill Creation Beyond Supervised Drafts

Status: parked.

v0.46 plans operator-supervised, inert trace-to-skill and trace-to-workflow
draft suggestions. Drafts remain disabled/untrusted until reviewed and
confirmed.

Still parked:

- autonomous skill creation from traces;
- auto-enable, auto-publish, or marketplace submission;
- broad execution permissions derived from repeated use or model confidence;
- autonomous package install, remote plugin install, or arbitrary code loading.

### Dynamic Capability Expansion Beyond v0.46 Facades

Status: parked.

v0.36-v0.38 define the supervised dynamic capability path. v0.46 may add only
reviewed delegate facades for memory promotion/update drafts and
objective/workflow draft writes.

Still parked:

- settings, secrets, shell, package-install, confirmation-decision, trust, or
  live workspace/canvas write facades;
- broader generated-permission ceilings beyond the reviewed v0.46 memory and
  workflow draft paths;
- unsupervised self-recompilation, compiler-loop bootstrapping, or runtime
  mutation outside the v0.36/v0.37/v0.38 review path.

### SMS Channel Adapter

Status: parked.

Discord and Slack are planned for v0.43. WhatsApp, Signal, iMessage, and Matrix
are planned for v0.49. SMS remains parked.

Still parked:

- phone-number mapping and ownership recovery;
- short-message truncation and partial-output UX;
- cost, rate-limit, and abuse policy;
- provider delivery failure handling.

### Agent URI Execution And Broader Agent Endpoints

Status: parked.

v0.40 plans MCP client execution. Future `agent://` and `agent+https://`
endpoint execution remain parked.

Still parked:

- remote agent endpoint discovery and authentication;
- cross-scheme grant policy for agent resources;
- remote agent impersonation defenses;
- channel-native Approval Handoff for agent endpoints.

### MCP Apps Iframe Model

Status: parked.

v0.49 plans public API, ACP, MCP-server, and AG-UI/A2UI bridge exposure.
Allbert remains catalog-bound for UI surfaces.

Still parked:

- MCP Apps sandboxed iframe execution;
- third-party remote UI code trust policy;
- CSP expansion for iframe-hosted apps;
- compatibility between MCP Apps UI and Allbert's validated Surface DSL.

### Broad Office, Archive, And Unknown-Binary Extraction

Status: parked.

v0.42 plans bounded HTML, markdown, plain text, and PDF extraction for browser
and web research.

Still parked:

- Office document extraction;
- archive traversal;
- unknown-binary inspection;
- deeper extractor contracts, size caps, content-type mismatch handling, and
  prompt-injection/data-exfiltration evals for those formats.

### Code-Bearing Remote Plugin Distribution

Status: parked.

v0.45 plans marketplace-lite metadata and reviewed skill/template discovery.
It does not install arbitrary remote code.

Still parked:

- remote code-bearing plugin install;
- remote dependency resolution;
- binary/plugin package distribution;
- remote theme/snippet distribution;
- signing, provenance, versioning, rollback, and sandbox policy for
  third-party code.

### Hosted Multi-User Authorization

Status: parked.

Allbert's near-term identity model remains local `user_id`. Hosted accounts,
roles, teams, auth sessions, API keys, and cross-user authorization remain
future work.

### Remote Sync Service

Status: parked.

v0.50 plans local-first profile export/import dry runs. Broad remote sync
remains parked.

Still parked:

- continuous sync service;
- conflict resolution across machines;
- cloud storage/provider policy;
- shared profile authorization.

### Native Packaged UI

Status: parked.

The browser workspace remains the operator UI through v1.0.

Still parked:

- packaged macOS/Windows/Linux app;
- native notification and tray/menu behavior;
- local authentication/identity policy for a native shell;
- packaging and auto-update strategy.

### Deeper Sandbox Tiers

Status: parked.

v0.36 implements a narrow Elixir/OTP sandbox/gate path for generated drafts.

Still parked:

- broader local container sandboxing for arbitrary workflows;
- microVM or remote sandbox execution;
- untrusted scripts/package installs under stronger isolation;
- hosted or multi-user sandbox isolation.

### Scripting Engine Interface

Status: parked.

v0.09 runs trusted inventoried skill scripts through `run_skill_script`. No
general scripting engine is planned.

Still parked:

- Lua, Python, JavaScript, or other embedded scripting runtime;
- dependency bootstrap policy;
- untrusted-script execution model.

### Broader Distributed Operation

Status: parked.

v0.49 public protocol interop is local/public-surface exposure, not a
distributed runtime.

Still parked:

- complex multi-node operation;
- cluster state replication;
- hosted scheduler/worker coordination;
- distributed confirmation ownership.

## Review Cadence

Review this file when closing a roadmap release, adding a roadmap milestone,
or discovering repeated operator requests that are not covered by the current
roadmap.
