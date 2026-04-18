# ADR 0009: v0.1 tool-surface expansion and its policy envelope

Date: 2026-04-18
Status: Proposed

## Context

The original v0.1 plan drew its tool set from the project's origin note: process execution, input gathering, skills, and memory. During the rev-3 architecture study the skill self-creation seam was explicitly *reserved* rather than exposed, and networked tools were not in scope. Subsequent planning work promoted several additional tools into the MVP:

- `request_input` (frontend-mediated user prompts)
- `create_skill` (agent-authored skills written to disk)
- `web_search` and `fetch_url` (clear-web egress)
- `invoke_skill.args` (structured guidance carried with a skill activation)
- `write_memory.summary` (explicit index summary for tier-1 entries)

Each of these is individually defensible. Collectively they expand the MVP's surface noticeably: more tools, a new frontend seam, network egress, and on-disk artifacts written by the agent itself. The origin note and [docs/vision.md](../vision.md) name the first three tool families only; network egress and agent-authored skills are additions to that stated set. The expansion is therefore a deliberate decision, not an implementation detail, and it must be recorded with a matching policy envelope so the security story keeps its "one choke point" shape.

The alternative — deferring some of these to v0.2 — would keep the MVP smaller. That was considered and rejected: `request_input` is already implied by "input gathering" in the vision, `invoke_skill.args` and `write_memory.summary` are small tactical refinements, and the network + self-creation tools are judged materially useful for early agent behavior provided they are fenced properly.

## Decision

v0.1's tool set is expanded from the origin-note list to include `request_input`, `create_skill`, `web_search`, and `fetch_url`, along with the tactical refinements `invoke_skill.args` and `write_memory.summary`. The expansion is coupled to an explicit policy envelope so that the expanded surface does not weaken the central-policy claim established by [ADR 0001](0001-kernel-is-runtime-core-frontends-are-adapters.md), [ADR 0004](0004-process-exec-uses-direct-spawn-and-central-policy.md), [ADR 0006](0006-hook-api-is-public-from-day-one.md), and [ADR 0008](0008-skill-allowed-tools-is-a-fence-not-a-sandbox.md).

### Policy envelope

1. **`request_input`** is frontend-mediated via the kernel's `InputPrompter` seam. Non-interactive frontends may return `Cancelled`. The tool is included in the small always-permitted set enforced by the skill fence because it only *asks* the user for text and performs no privileged action.

2. **`create_skill`** writes under `~/.allbert/skills/<name>/SKILL.md` only; the skills root is part of the sandboxed filesystem roots and is enforced by the same `sandbox::check` used by the fs tools. Overwrites trigger the same confirm path as `write_file`. `create_skill` is **not** in the always-permitted set — a skill must declare `create_skill` in its `allowed-tools` to invoke it from an active-skill context. A newly created skill still passes through the activation gate defined by [ADR 0002](0002-skill-bodies-require-explicit-activation.md): its body enters the prompt only after an explicit `invoke_skill` call, even if the creating turn also activates it.

3. **`web_search` and `fetch_url`** go through a centralized `web_policy(url) → Deny | AutoAllow | NeedsConfirm` check on `HookPoint::BeforeTool`, parallel in spirit to `exec_policy`. Defaults:
   - deny `file://`, `data:`, and non-`http(s)` schemes;
   - deny resolved addresses in RFC1918, loopback, link-local, and unique-local ranges (SSRF guard);
   - require DNS resolution before dispatch; reject unresolvable hosts;
   - apply a per-request timeout and cap output by `limits.max_tool_output_bytes_per_call`;
   - log every fetched URL through `tracing` at INFO.
   Allow/deny host patterns live under a new `[security.web]` config block so the envelope is user-tunable without a code change.

4. **`invoke_skill.args`** are stored with the active skill and rendered on later prompts as a small `Invocation arguments (JSON)` block immediately before that skill's body. To bound prompt bloat and injection surface, a new runtime limit `limits.max_skill_args_bytes` caps the serialized args payload; oversized args are rejected by the tool with a model-visible error.

5. **`write_memory.summary`** is a string hint for the `MEMORY.md` index. Derivation on first insert falls back to the first markdown heading or first non-empty line, truncated. Later writes without `summary` preserve the existing index text. The summary field does not change memory sandboxing or path rules.

6. **Bootstrap-file writes** (`SOUL.md`, `USER.md`, `IDENTITY.md`, `TOOLS.md`, `BOOTSTRAP.md`) are treated as durable prompt-surface mutations, not casual file edits. Even though they live under the normal Allbert root, writes or overwrites to them must follow the same explicit confirm path as other sensitive durable-state mutations. This protects the always-on prompt surface defined by [ADR 0010](0010-bootstrap-personality-files-are-first-class-runtime-context.md).

All of the above policy is enforced inside the existing central hooks (`SecurityHook` on `BeforeTool`) and the existing `sandbox::check`, keeping the single-choke-point property intact.

## Consequences

**Positive**
- The MVP's tool surface matches the agent behavior the project actually wants (ask the user for input, extend itself, touch the web) without waiting for v0.2.
- Every added tool has a documented policy path rather than an implicit one.
- Web egress gets SSRF guards and host-pattern config from day one instead of being retrofitted after an incident.
- `create_skill` cannot bypass the activation gate, so the prompt-injection model remains the one established in [ADR 0002](0002-skill-bodies-require-explicit-activation.md).
- Durable prompt-surface mutation gets explicit guardrails instead of piggybacking silently on generic file-write policy.

**Negative**
- Larger MVP surface to implement, test, and verify. M4 in particular grows to cover input, web, SSRF guards, and bootstrap-file write policy.
- More config surface (`[security.web]`, `limits.max_skill_args_bytes`).
- Each new tool is a new attack surface; the policy envelope mitigates but does not eliminate risk.

**Neutral**
- The expansion is explicit and recorded; later retractions or extensions can be represented as new ADRs without rewriting history.
- Host allow/deny policy is deliberately user-tunable rather than hardcoded, which means end users own part of the web-egress policy from the start.

## References

- [docs/plans/v0.1-mvp.md](../plans/v0.1-mvp.md)
- [docs/vision.md](../vision.md)
- [ADR 0001](0001-kernel-is-runtime-core-frontends-are-adapters.md)
- [ADR 0002](0002-skill-bodies-require-explicit-activation.md)
- [ADR 0004](0004-process-exec-uses-direct-spawn-and-central-policy.md)
- [ADR 0006](0006-hook-api-is-public-from-day-one.md)
- [ADR 0008](0008-skill-allowed-tools-is-a-fence-not-a-sandbox.md)
