# ADR 0004: Process execution uses direct spawn and centralized policy

Date: 2026-04-17
Status: Accepted

> **Amended in v0.14**: `unix_pipe` adds Unix-style composition without reintroducing shell-string execution. Each pipeline stage is still a normalized direct spawn, resolved from an operator-enabled local utility id, and checked by the same central exec policy. See [ADR 0093](0093-unix-pipe-is-a-structured-direct-spawn-tool-not-a-shell-runtime.md).

## Context

Early Allbert needs command execution. That is one of the smallest useful tools and one of the highest-risk ones. A naive shell-string contract such as `"run this command"` is attractive, but it creates ambiguity about quoting, redirection, pipes, glob expansion, and what exactly the security layer is approving.

It also makes policy weak. Approving a bare command name like `ls` says almost nothing about the actual behavior of a later shell string, and general-purpose interpreters can reintroduce shell semantics indirectly.

## Decision

The v0.1 execution tool will use a normalized process request such as `{program, args, cwd}` and spawn the process directly.

- No shell parsing is part of the tool contract.
- Security checks run in one place, a centralized hook before tool execution.
- Filesystem roots and confirmation policy remain global enforcement mechanisms, not skill-local ones.
- General shell entrypoints and broad interpreters are deny-by-default unless explicitly allowlisted.

The intent is to make both execution behavior and approval semantics auditable from day one.

## Consequences

**Positive**
- Fewer quoting and injection ambiguities.
- Security review is simpler because there is one policy choke point.
- Approval decisions can be reasoned about against a normalized request.

**Negative**
- Some shell-native workflows must be decomposed into multiple tool calls.
- The MVP will feel less flexible than a full shell agent.

**Neutral**
- Richer execution modes can be added later, but they need an explicit policy model. v0.14's `unix_pipe` is one such additive mode and preserves direct-spawn semantics per ADR 0093.
- Skills may request execution, but they do not own execution policy.

## References

- [docs/plans/v0.01-mvp.md](../plans/v0.01-mvp.md)
