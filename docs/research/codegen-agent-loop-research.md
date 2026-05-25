# Codegen Agent Loop Research

Date: 2026-05-25

This note informs the v0.37.2 dynamic-codegen correction. It focuses on whether
the codegen committee should be a single LLM author call with deterministic
wrappers, or a bounded multi-role loop with tests, critic feedback, and repair.

## Sources Reviewed

- SWE-agent: Agent-Computer Interfaces Enable Automated Software Engineering
  https://arxiv.org/abs/2405.15793
- Agentless: Demystifying LLM-based Software Engineering Agents
  https://arxiv.org/abs/2407.01489
- AgentCoder: Multi-Agent-based Code Generation with Iterative Testing and
  Optimisation
  https://arxiv.org/abs/2312.13010
- Self-Refine: Iterative Refinement with Self-Feedback
  https://arxiv.org/abs/2303.17651
- Reflexion: Language Agents with Verbal Reinforcement Learning
  https://arxiv.org/abs/2303.11366
- Agents in Software Engineering: Survey, Landscape, and Vision
  https://arxiv.org/abs/2409.09030
- Survey on Evaluation of LLM-based Agents
  https://arxiv.org/abs/2503.16416
- A Survey of LLM-based Automated Program Repair: Taxonomies, Design
  Paradigms, and Applications
  https://arxiv.org/abs/2506.23749
- AgentDevel: Reframing Self-Evolving LLM Agents as Release Engineering
  https://arxiv.org/abs/2601.04620

## Findings

Single-shot code generation is the wrong default for generated runtime
capabilities. The strongest systems use either a simple but explicit software
engineering pipeline or a bounded agent loop. In both forms, tests, execution
feedback, and non-regression checks are central.

AgentCoder is the closest match to Allbert's planned role vocabulary: it
separates a programming role, a test-design role, and a test-execution role,
then feeds execution feedback back into code refinement. That argues against a
v0.37.2 shape where only `Codegen.Author` calls the LLM and
`Codegen.TrialAuthor`, `Codegen.Critic`, and `Codegen.Repair` are shallow
deterministic wrappers.

SWE-agent and the software-engineering-agent surveys emphasize tool interaction
and repository feedback. For Allbert, the equivalent is not arbitrary shell
access; it is the v0.36 sandbox facade, generated focused tests, trusted
validator reports, and warning-gate diagnostics. Those observations should be
converted into bounded repair inputs.

Agentless is a useful caution: complex free-form autonomy is not required for
good software-engineering results. Its lesson for Allbert is to keep the
workflow structured and inspectable: plan, author, test, validate, repair, and
select. The LLM should not decide what privileged tool to call next.

Self-Refine and Reflexion support iterative feedback and refinement, including
coding tasks. The important Allbert adaptation is that feedback should be
grounded in external evidence where available, not only self-critique.

AgentDevel is especially aligned with Allbert's authority model. It treats agent
improvement as release engineering: external diagnostics, auditable specs, and
regression-aware gates promote a candidate. For v0.37.2, this maps to single
canonical draft revision lines, sandbox/gate reports as evidence, and explicit
operator confirmation as the only trust grant.

## Recommendation

v0.37.2 should require a bounded model-backed codegen committee, not only a
model-backed Author role.

The minimum useful loop is:

1. `Planner` LLM turns the capability gap into a generation spec with
   acceptance criteria, constraints, target shape, and test strategy.
2. `Author` LLM writes the read-only action source from the spec.
3. `TrialAuthor` LLM writes focused generated tests from the same spec and
   source constraints.
4. Deterministic validators check schema, placeholders, source shape, target
   limits, and forbidden constructs before sandboxing.
5. The v0.36 sandbox runs compile, focused tests, and the warning gate.
6. `Critic` LLM reviews the plan/source/tests and, after trial, summarizes
   sandbox/gate failures. Its output can veto or request repair, but cannot
   accept, trust, or integrate a draft.
7. `Repair` LLM receives bounded diagnostics and produces a new full
   source/test packet or patch packet for the next draft revision.
8. The loop stops when deterministic acceptance passes, or when
   `dynamic_codegen.max_repair_iterations`, provider-call budget, provider
   usage budget, repeated-identical failure detection, or wall-clock timeout is
   reached.

`good enough` must mean deterministic evidence, not a model's confidence:

- source and test packets satisfy structured schemas;
- trusted source prechecks pass;
- generated focused tests compile and pass in the v0.36 sandbox;
- warning gate and selected security evals pass;
- trusted validator passes immediately before loader compile;
- the operator explicitly confirms live integration.

The LLM critic is advisory. It may explain, veto, prioritize, or propose repair,
but it must never be the authority that marks a draft trusted or integrated.

## v0.37.2 Scope Implication

If v0.37.2 is meant to prove "Allbert can actually use LLMs to create code,"
the current single-call producer is insufficient. It can remain as an early
implementation checkpoint, but the release-blocking plan should add a
model-backed Planner, TrialAuthor, Critic, and Repair packet contract plus the
bounded repair loop over sandbox/gate evidence.
