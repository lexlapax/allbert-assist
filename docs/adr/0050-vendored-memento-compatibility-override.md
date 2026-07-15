# ADR 0050: Vendored Memento Compatibility Override

## Status

Superseded — override removed at v1.0.1 M5.1 (2026-07-15). `jido_signal` 2.2.2
dropped its `:memento ~> 0.5.0` dependency entirely (the only consumer in the
tree), so the removal criteria below were met by upstream deletion rather than an
upstream fix: the Jido stack was bumped to `jido` 2.3.2 / `jido_action` 2.3.1 /
`jido_signal` 2.2.2, `vendor/memento` and the `apps/allbert_assist/mix.exs` path
override were deleted, `mix deps.tree` shows no `memento`, and
`mix compile --warnings-as-errors` plus the focused v1.0.1 gate files pass without
it. Criterion 2 (`mix deps.compile memento`) is moot — the package is no longer a
dependency. Historical benchmark references in `docs/developer/test-strategy.md`
and `docs/plans/archives/v0.41-plan.md` remain verbatim as shipped history.

Previously: Accepted for v0.41 M1 dependency compatibility unblock.

## Context

v0.41 measures and improves Allbert's developer workflow. The first M1 release
benchmark on 2026-05-29 could not reach Allbert tests on the current local
toolchain: Elixir 1.19.5 running on Erlang/OTP 29.0.1 failed while compiling
`:memento` 0.5.0.

The failure was a typespec collision. `Memento.Table` defined
`@type record :: struct()`, while Elixir 1.19 treats `record/0` as a built-in
type. The dependency failed before the v0.40 oracle or v0.41 baseline could be
measured.

Updating the Jido stack was still the right first probe. Current releases are:

- `:jido` 2.3.0
- `:jido_action` 2.3.0
- `:jido_signal` 2.2.0
- `:jido_ai` 2.2.0

However, `:jido_signal` 2.2.0 still depends on `:memento ~> 0.5.0`, and
`:memento` has no newer Hex release. A toolchain downgrade would make the old
dependency compile, but v0.41 is explicitly about improving the current
developer workflow. The operator accepted the dependency-compatibility path for
this unblock.

## Decision

Allbert carries a local path override for `:memento` until upstream publishes an
Elixir 1.19-safe release or Jido removes the dependency:

```elixir
{:memento, path: "../../vendor/memento", override: true}
```

The vendored source is a snapshot of Hex `:memento` 0.5.0 with only the
compile-time typespec collision renamed:

- `Memento.Table.record/0` becomes `Memento.Table.memento_record/0`
- internal specs and documentation references in the vendored copy are updated
  to the new type name
- runtime Mnesia/table/query behavior is unchanged

The override lives in `apps/allbert_assist/mix.exs`. The vendored patch note
lives in `vendor/memento/ALLBERT_PATCHES.md`.

## Consequences

- v0.41 can measure the release oracle and continue the developer-efficiency
  work on Elixir 1.19 / OTP 29 instead of silently downgrading the toolchain.
- Allbert owns this vendored dependency snapshot until the override is removed.
  Future dependency updates must check whether the override is still needed.
- `mix deps.unlock --unused` must not remove the override; `mix deps` should show
  `memento 0.5.0 (../../vendor/memento)`.
- This is not operator-facing functionality and grants no runtime authority.
  It is a reviewed dependency compatibility patch only.
- If another upstream Memento/Jido compile failure appears, it should be treated
  as dependency compatibility work, not as test-lane migration work.

## Removal Criteria

Remove the override only when all are true:

1. Upstream `:memento` or the Jido stack no longer fails on Elixir 1.19+.
2. `mix deps.compile memento --force` succeeds without the vendored path.
3. Focused Jido/signal compatibility tests pass.
4. The full release gate reproduces the v0.40 oracle.
5. This ADR, `docs/developer/test-strategy.md`, and `docs/plans/archives/v0.41-plan.md`
   are updated to record the removal.

## Validation

The v0.41 M1 unblock validated the override with:

- `mix compile --warnings-as-errors`
- focused Jido/signal tests: 54 core tests, 4 web signal-bridge tests, and 4
  StockSage supervisor tests, all passing
- full `mix precommit`: 1146 core tests with 2 skipped, 107 web tests, 197
  StockSage tests, and 2 channel/plugin tests, all passing

## Relates To

- ADR 0007 - Jido-native internal runtime boundaries.
- ADR 0049 - Development gates and test parallelization.
- `docs/plans/archives/v0.41-plan.md`.
- `docs/developer/test-strategy.md`.
- `vendor/memento/ALLBERT_PATCHES.md`.
