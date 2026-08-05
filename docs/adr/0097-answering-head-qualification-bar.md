# ADR 0097: Answering-Head Qualification Bar

## Status

Proposed (v1.3.1). Binding on `docs/plans/v1.3.1-plan.md` M1–M4 and
`docs/plans/v1.3.1-request-flow.md`.

Sourced from v1.3 M9.b.8, deferred by operator decision on 2026-08-02. v1.3.0
ships the default answering head unchanged, discloses two recorded failure modes
in `docs/operator/model-recommendations.md`, and documents an opt-in seam for
selecting another head. The live setting is
`model_preferences.tasks.direct_answer`; `intent.direct_answer_model_profile`,
which v1.3.0's disclosure names, is an accepted write-alias for it. v1.3.1
guidance names the live key. This ADR decides what that opt-in is supposed to be selected *against*.

Related: ADR 0021 (intent/objective capability and the advisory boundary,
including its deliberate no-regex/no-domain-oracle constraint), ADR 0072
(recommended model profiles per purpose), ADR 0088 (model catalog, chooser, and
fallback policy), ADR 0061/0051 (model substrate and closed capability
preferences).

## Context

Allbert's answering head is a local model chosen by profile. v1.3 attended
validation recorded it failing twice, in different families, on ordinary
requests:

A factual error. Asked which children an OTP supervisor restarts under
`rest_for_one`, the shipped `qwen2.5:7b` described `one_for_one` behavior.
Retesting found `llama3.1:8b` and `mistral-small3.1:24b` wrong the same way and
`gemma4:31b` correct. Parameter count did not predict accuracy, so "use a bigger
model" is not a rule an operator can act on.

A rule-following error. Asked to acknowledge a stated preference, the head
answered that status summaries "will be provided" starting on a date. Allbert's
own DirectAnswer catalog carries `:acknowledgments_are_not_commitments` for
exactly this, and the head violated it while the rule was in its prompt. Thirty-
six subsequent trials across four conditions — including the exact production
request path — reproduced nothing. It then reappeared on the first attempt of a
later independent session. The failure is real, recurring, and its rate is
unknown.

Neither is an orchestration defect. Neither is fixable by prompt work we can
demonstrate, since the rule was already present and the correction cannot be
shown to work against a failure that will not reproduce.

What v1.3 could not answer is the question underneath both: **is a given head
good enough to be Allbert's answering head, and how would an operator know?**
Today an operator who reads the disclosure and wants to do better has one lever —
point the setting at a different model — and no way to tell whether they improved
anything. The recommendation reduces to "select a larger model and hope", which
the `mistral-small3.1:24b` result already falsifies.

Three constraints bound any answer.

Runtime enforcement is out. A deterministic future-tense detector in the request
path is a domain oracle deciding product behavior, which ADR 0021 forbids on
purpose; the constraint is not an oversight to route around.

Model-judges-model is out. v1.3 M9.b.6 deleted the fan-out critic topology for
recorded reasons — a second model's verdict about a first model's output is not
evidence, and shipping one here would reintroduce exactly what was removed.

Single-shot pass/fail is out. Thirty-six consecutive passes between independent
failures show that one observation can easily miss the acknowledgment mode. Any
bar over a nondeterministic generator has to record repeated-trial counts.

## Decision

Ship a **frozen, deterministically scored, offline qualification corpus** that an
operator runs against a candidate answering head and reads as a pass rate.

1. **It qualifies a head; it does not change a default.** The bar produces
   evidence. Whether to raise Allbert's shipped default profile is a separate
   operator decision that consumes this evidence. v1.3.1 ships no new default and
   no automatic head selection.

2. **It lives outside the request path.** The bar is an opt-in development gate
   in the existing `mix allbert.test` family. It never runs during a turn, never
   gates an answer, and never inspects operator content. This is what keeps it
   clear of ADR 0021: a frozen offline corpus with recorded expected values is
   evidence *about a model*, not an oracle *inside Allbert*.

3. **It covers both failure families.** Factual rows and instruction-following
   rows, scored separately. This is load-bearing, not thoroughness: a facts-only
   corpus would have passed the head on the acknowledgment row, which is the
   failure the operator actually cared about.

4. **Scoring is closed and deterministic.** Each row records the exact
   discriminating fact or the exact closed criterion, and scoring is a predicate
   over that recorded value. No model grades another model's output. No
   heuristic quality score.

5. **Reliability is measured, not asserted.** The v1.3.1 release record runs
   five trials per row against one resolved profile and requires 5/5 on every
   row. Results are per-row pass counts and a per-class pass rate against that
   minimum, frozen before any head is measured — so no head is qualified against
   a bar chosen after seeing its score. This small screen is not a statistical
   population-rate claim; later plans may version a larger corpus/budget.

6. **Requests go through the production path.** Same DirectAnswer assembly, same
   rule catalog, same `temperature: 0.0`. A bar with its own prompt assembly
   measures a head Allbert does not ship.

   One deliberate pin: the bar sets `max_retries: 0`. Ordinary DirectAnswer
   inherits Req's default of three retries and only fan-out children pin zero, so
   this is a stated choice rather than a copy of the answering path. It does not
   change what is measured — Req retries only transient transport and 5xx
   conditions, never a successful response whose content is wrong — and it keeps
   one scored trial equal to exactly one request, which the trial counts in
   decision 5 depend on.

7. **Failures are recorded as failures.** Provider unavailability, empty
   responses, and refusals score as fails and the run says so. There is no
   unscored bucket, because an unscored bucket is where a failing head hides.

8. **Evidence is content-free.** Recorded rows carry digests, counts, rates, and
   the resolved profile/provider/model/endpoint — never prompts, answers, or
   operator data. Any row is reproducible from the corpus digest plus the row id.

## Consequences

An operator considering a different answering head gets a number instead of an
intuition, and the number is comparable across heads because the corpus and the
minimum are frozen. The `mistral-small3.1:24b` result stops being a surprising
anecdote and becomes a recorded row.

Allbert gains a place to put the next observed failure. The acknowledgment case
enters as a row rather than as a paragraph in a validation log, so a future head
is tested against it automatically instead of being trusted not to repeat it.

The bar is a floor, not a warrant. It says a head cleared a small frozen corpus at
some rate; it does not say the head is correct, and it says nothing about the
operator's own domain. The operator documentation must state this plainly or the
bar will be read as a guarantee it cannot support.

Corpus maintenance is a real cost. Rows drawn from stable technical semantics —
OTP supervision, event-sourcing replay, SQLite durability — age slowly, which is
why the corpus draws from there rather than from anything current.

The measurement is expensive. Five trials for each of six rows per required
local head is minutes, not seconds, which is why the bar is opt-in and in no
aggregate, precommit, or CI path.

Passing the bar and being unreliable in practice remain compatible. A rare
failure mode nobody has observed yet is not in the corpus, and this ADR does not
claim otherwise.

## Alternatives Considered

**Raise the default head to `gemma4:31b`.** Correct on the recorded factual row,
but roughly 20 GB — unusable on the 16 GB machines Allbert targets — and
untested on the instruction-following row. It would trade a disclosed limit for
an undisclosed one and an install most operators cannot run.

**Detect future-tense commitments in the request path.** Directly addresses the
observed instruction failure and is deterministic. Rejected: it is the domain
oracle ADR 0021 forbids, it would fire on legitimately future-tense answers, and
it treats one observation as a pattern.

**A second model reviewing DirectAnswer output.** Rejected on the same grounds
v1.3 M9.b.6 deleted the critic topology. It doubles cost and latency to obtain
another unverified generation.

**Publish the failures and stop there.** This is what v1.3 ships, and it is
honest. Rejected as an endpoint because it leaves the operator's one lever
unmeasurable — the disclosure names a problem and hands over no way to tell
whether any action fixed it.
