# Simplification Opportunities: Tests That Earn Nothing

Survey date: 2026-07-29. Baseline commit: `c7ee5a29`.

This is a findings document, not a milestone plan. It records which tests carry no
regression value and what removing or strengthening them would target. Nothing
here is scheduled; scope decisions belong in the roadmap and the active version
plan.

Companion document: `docs/plans/simplification-opportunity-abstractions.md`
(duplicate and near-duplicate abstractions in production code).

Method: an ExUnit block parser over all 533 `*_test.exs` files, extracting 3,395
test blocks with their bodies, then classifying each by assertion content
(assertion-free, tautological, shape-only, wildcard-only), by whether the body
touches any production module, and by cross-file body duplication. Assertion
detection matches any identifier beginning with `assert`/`refute`, so
project-local helpers such as `assert_denied!` and `assert_cli` count.

Caveat: this is static analysis. The suite was not executed for this survey, so
there is no timing data on what these tests cost in wall-clock and no coverage
data confirming the overlap figures represent genuinely redundant paths.

## Summary

The suite is healthy on every crude marker of a worthless test. The dead weight
is concentrated in a single family.

| Crude marker | Count |
| --- | ---: |
| Test blocks parsed | 3,395 |
| Zero assertions of any kind | **3** |
| `assert true` / `assert false` | **1** |
| `assert x == x` | 0 |
| `assert <literal> == <literal>` | 0 |
| `assert is_type(<literal>)` | 0 |
| Identical test bodies | 2 pairs (4 tests) |
| Blanket tag exclusions in any lane | none |

There is no pile of junk tests. Findings 1 and 2 below are where the value is.

---

## 1. Eval-inventory self-check tests

53 tests, 421 LOC. **51 of them touch no production module at all.**

These assert that `apps/allbert_assist/test/support/security_fixtures/eval_inventory.ex`
— a 7,307-line compile-time literal — is well-formed.

Representative body, `test/security/v064_sweep_eval_test.exs:120`:

```elixir
test "v0.64 rows encode concrete pass criteria" do
  for row <- EvalInventory.rows_for_milestone(:v064) do
    assert is_atom(row.boundary)
    assert is_list(row.assert) and row.assert != []
    assert is_binary(row.scenario) and byte_size(row.scenario) > 12
  end
end
```

This asserts that atoms are atoms and that strings exceed 12 bytes, inside a
hardcoded list. It can only fail if a developer hand-edits the fixture and
mistypes a literal.

**11 near-identical copies** exist:

| File | Line |
| --- | ---: |
| `test/security/v059_sweep_eval_test.exs` | 70 |
| `test/security/v060_sweep_eval_test.exs` | 71 |
| `test/security/v060b_sweep_eval_test.exs` | 53 |
| `test/security/v061_sweep_eval_test.exs` | 80 |
| `test/security/v061b_sweep_eval_test.exs` | 61 |
| `test/security/v062_sweep_eval_test.exs` | 118 |
| `test/security/v063_sweep_eval_test.exs` | 74 |
| `test/security/v064_sweep_eval_test.exs` | 120 |
| `test/security/v065_sweep_eval_test.exs` | 120 |
| `test/security/v066_sweep_eval_test.exs` | 74 |
| `test/security/v1_sweep_eval_test.exs` | 59 |

The paired "inventory rows are complete" tests are literal-against-literal as
well. `@owners` in the test file is a map of row id to test-module *name string*,
compared against the `test_module` *string* stored in the fixture
(`v064_sweep_eval_test.exs:36` and `:113`). Neither side is checked against a
module that exists or a test that actually runs.

### The real cost: false release evidence

Each of these tests is followed by an unconditional evidence row:

```elixir
IO.puts("v064-inventory-complete status=pass rows=13 owners=routed")
```

There are **110 such `IO.puts` rows** across the eval suite. A shape-only
assertion that then prints `status=pass` reports a proved security boundary to
the release gate. That is negative value, not zero — the row is indistinguishable
in gate output from a row backed by a real behavioral assertion.

### Not uniformly worthless

Two members of the family do earn something and should be kept:

- `v064_sweep_eval_test.exs:237` reads the owner test *files as source text* and
  matches row ids against them. That is a real binding check — it catches an eval
  row declared but never referenced by any test file.
- `v11`, `v12`, and `v121` sweep tests additionally assert distinctness of
  assertion sets across rows (`v11_sweep_eval_test.exs:66`), which catches
  copy-paste rows.

The `is_atom` / `byte_size > 12` half is what earns nothing.

### This was already noticed once

There is a test named, verbatim:

> `test/security/v058_surface_consistency_eval_test.exs:94` —
> *"M13.1C renderer and rejection audit behaviors are asserted, **not
> inventory-only**"*

That is a corrective test written because the inventory tests were not proving
anything. The correction was applied to one milestone and not to the other
twenty.

---

## 2. Frozen-doc string assertions — v0.60 and v0.60b

535 LOC across two files that assert Markdown content rather than behavior.

| File | LOC | doc reads | `assert_contains!` | production calls |
| --- | ---: | ---: | ---: | ---: |
| `test/security/v060_sweep_eval_test.exs` | 328 | 17 | 12 | **5** |
| `test/security/v060b_sweep_eval_test.exs` | 207 | 15 | 12 | **4** |

Actual content, `v060b_sweep_eval_test.exs:63`:

```elixir
research = read!("docs/design/visual-language-research.md")

assert_contains!(research, [
  "## Reference Survey",
  "## Extracted Visual & Interaction Principles",
  "## Mood / Direction Inventory",
  "trust-first"
])
```

This asserts that a Markdown heading exists in a design document belonging to a
release that closed in June 2026. It protects nothing about the running system
and fails only if someone edits an archived doc.

**This is localized, not systemic.** Across the whole 49-file eval suite there are
880 production-module calls against only 57 doc reads. The rest of the eval suite
is doing real behavioral work; these two files are the outliers.

---

## 3. Individually weak tests

| Location | Problem |
| --- | --- |
| `test/allbert_assist/dynamic_plugins/staging_and_sandbox_bridge_test.exs:366` | test named `"generated fixture"`; only assertion is `assert true` |
| `test/allbert_assist/confirmations_test.exs:187` | only assertion is `assert raw_sites` — bare truthy on a list, passes on any non-empty result including a wrong one |
| `test/allbert_assist/workflows/schema_test.exs:27` | only assertion is `assert {:ok, _} = ...`; discards the entire validated structure |
| `test/allbert_assist/sandbox_test.exs:932` | body is literally `:ok` |
| `test/allbert_assist/sandbox_test.exs:1004` | body is literally `:ok` |

The two `sandbox_test.exs` entries are `@tag skip:` placeholder stubs for
env-gated Docker smokes (`ALLBERT_DOCKER_SANDBOX_TEST`,
`ALLBERT_DOCKER_FULL_GATE_TEST`). Defensible as documentation of a deliberate
gap, but they register as passing tests that execute nothing.

---

## 4. Redundant coverage

### Exact duplicates

| Pair | Note |
| --- | --- |
| `test/allbert_assist/intent/router_disambiguator_test.exs:76` and `test/security/v054_intent_router_eval_test.exs:94` | eval test is a verbatim copy of the unit test |
| `test/allbert_assist/channels/discord_test.exs:783` and `test/allbert_assist/channels/slack_test.exs:717` | identical bodies, differing only in test name |

### Eval-suite overlap with the unit suite

1,129 of 17,613 non-blank eval-suite lines (**6.4%**) appear verbatim in non-eval
tests. Highest-overlap files:

| File | Overlapping lines | Share |
| --- | ---: | ---: |
| `v047b_self_improvement_eval_test.exs` | 76 / 278 | 27.3% |
| `v056_intent_eval_test.exs` | 93 / 490 | 19.0% |
| `v0551_operator_console_eval_test.exs` | 62 / 341 | 18.2% |
| `v046_research_delegate_eval_test.exs` | 48 / 286 | 16.8% |
| `v12_sweep_eval_test.exs` | 49 / 359 | 13.6% |
| `v051_public_protocol_eval_test.exs` | 52 / 398 | 13.1% |

Modest overall, but it is the same mechanism as the exact duplicate above:
copying a unit test into an eval file to satisfy a row.

---

## 5. Dead selector surface — 31 one-shot tags

31 `@tag` / `@moduletag` values are used exactly once, nearly all from closed
milestones:

`:v061_visual_tokens`, `:v061_screens`, `:v061_motion`, `:v061_brand`,
`:v061_dark_mode`, `:v061_hierarchy`, `:v061_ia_navigation`,
`:topbar_retirement`, `:sidebar_ownership`, `:sidebar_consolidation`,
`:sidebar_collapse`, `:status_chip`, `:docked_pane`, `:chat_type`,
`:clear_session`, `:complete_thread`, `:approval_media_write`,
`:sweep_expired_sessions`, `:tui_convergence`, `:serve_daemon`, `:install_path`,
`:first_model_path`, `:onboarding_wizard`, `:dark_tokens`, `:perf_csp_baseline`,
`:param_contract`, `:rc_substrate`, `:rc_design_handoff`,
`:v060_persona_seed_preaudit`, `:v060_cross_doc_coherence`, `:v060b_handoff`.

The tests themselves may be sound. The per-milestone selector vocabulary is dead
once the gate that invoked `--only <tag>` retired. Note that the lane tags
(`:app_env_serial` 122, `:pure_async` 64, `:external_runtime_serial` 56,
`:global_process_serial` 36, `:home_fs_serial` 24, `:db_serial` 8) are the
load-bearing taxonomy from `docs/developer/test-strategy.md` and are unaffected.

---

## Explicit non-findings

Recorded so review effort is not spent here.

- **No blanket exclusions.** Neither `test_helper.exs` excludes tags suite-wide.
  Both set up hermetic state (provider env keys cleared, vault pinned to
  `encrypted_file`, pid-qualified temp home) with documented reasons.
- **Assertion-free tests are effectively nonexistent** — 3 of 3,395, and 2 of
  those are deliberate skip stubs.
- **Tautologies are effectively nonexistent** — 1 `assert true` in the entire
  suite; zero self-comparisons, literal comparisons, or shape checks on literals.
- **The eval suite is mostly real.** 880 production-module calls across 49 files.
  Findings 1 and 2 are specific subsets, not a verdict on the eval approach.
- **Change-detector count assertions** (`assert length(...) == <literal>`) number
  63 suite-wide, 14 in the eval suite. Low enough not to be a systemic problem.

---

## Sequencing note

The highest-value cleanup is small: the **11 `rows encode concrete pass criteria`
tests and their accompanying `IO.puts` evidence rows**. They are cheap to delete
and are currently reporting `status=pass` for boundaries they never exercise —
the only finding here with negative rather than zero value.

Second, the v0.60 and v0.60b doc sweeps (535 LOC) can be deleted outright, or
converted to a single docs-staleness check. `mix allbert.test docs` already owns
doc-staleness and index verification as of v0.66 M10, so the capability exists;
these two files predate it and duplicate its purpose badly.

Before acting on either, confirm against a real run whether any inventory test
has ever caught a fixture error, and whether the v0.60/v0.60b sweeps are still
wired into an executing gate.

The remaining findings (items 3 through 5) are individually small and are best
folded into whatever milestone next touches the surrounding files, rather than
driving their own cleanup pass.
