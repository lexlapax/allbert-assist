# Adaptive memory operator guide

Allbert keeps memory markdown-first and review-first, while making memory easy to reach during ordinary work.

## Routing

The default routing mode is `always_eligible`, not `always_active`:

```toml
[memory.routing]
mode = "always_eligible"
always_eligible_skills = ["memory-curator"]
auto_activate_intents = ["memory_query"]
auto_activate_cues = ["remember", "recall", "what do you remember", "review staged", "promote that", "forget"]
```

`memory-curator` is surfaced as a nearby option on root turns. Its full skill body is loaded only when policy activates it, such as for the `memory_query` intent or configured memory-review cues. Automatic activation is current-turn scoped: after an ordinary auto-routed memory turn finishes, telemetry returns to no active skill unless the operator explicitly activated one for the session. Auto-routed memory activation is not intended to become durable session state or restore from a saved session as an active skill.

Explicit skill activation is different: when the operator intentionally activates a skill for the session, that skill may remain active and narrow the available tools according to its `allowed-tools` fence. If telemetry shows `memory-curator` after an unrelated ordinary turn, such as a web-search or provider smoke, treat that as the v0.15.1 M11 stale active-skill finding rather than expected adaptive-memory behavior.

Inspect or adjust routing without editing code:

```bash
cargo run -p allbert-cli -- memory routing show
cargo run -p allbert-cli -- memory routing set --mode always-eligible --skill memory-curator
cargo run -p allbert-cli -- memory routing set --auto-activate-intent memory_query
```

The generated `~/.allbert/AGENTS.md` reflects the active routing policy, but config remains the source of truth.

## Search Tiers

`memory search` now supports explicit tiers:

```bash
cargo run -p allbert-cli -- memory search "postgres" --tier durable
cargo run -p allbert-cli -- memory search "debugging decision" --tier episode
cargo run -p allbert-cli -- memory search "project storage" --tier fact
cargo run -p allbert-cli -- memory search "anything" --tier all
```

Tier meanings:

- `durable`: approved markdown memory under `~/.allbert/memory/notes/`.
- `staging`: candidate learnings awaiting review under `~/.allbert/memory/staging/`.
- `episode`: derived search over session journals; labelled as working history, not approved memory.
- `fact`: approved temporal facts indexed from durable memory frontmatter.
- `all`: explicit cross-tier search.

Default prefetch stays conservative. Staging and episode content are not auto-injected as approved durable memory.

## Episode Recall

Episode recall indexes bounded session journal turns from `~/.allbert/sessions/*/turns.md`. It helps answer questions like "what did we decide last session?" without turning transcripts into durable memory.

Rules:

- episode hits are labelled as session working history
- forgotten or archived sessions are skipped on rebuild
- learnings extracted from episodes still go through staging before promotion
- episode prefetch remains disabled unless `memory.episodes.prefetch_enabled = true`

## Temporal Facts

Staged or durable memory entries may carry fact metadata:

```yaml
facts:
  - subject: "project storage"
    predicate: "uses"
    object: "Postgres"
    valid_from: "2026-04-24T00:00:00Z"
    valid_until: null
    source:
      kind: "staged_memory"
      id: "stg_..."
    supersedes: []
```

Facts do not become durable merely by being extracted. They are searchable as `tier = "fact"` only after their parent memory is promoted into durable notes. Superseded facts remain auditable, but default fact views filter them out.

## Semantic Retrieval

BM25/Tantivy remains the default. Semantic retrieval is disabled by default:

```toml
[memory.semantic]
enabled = false
provider = "none"
embedding_model = ""
hybrid_weight = 0.35
```

Allbert ships the derived-index seam and a fake deterministic provider for provider-free validation. Do not configure a hosted semantic provider for semantic retrieval yet; real embedding adapters are an additive follow-up. If semantic retrieval is enabled for validation, use:

```toml
[memory.semantic]
enabled = true
provider = "fake"
embedding_model = "fake-test"
hybrid_weight = 0.35
```

The semantic index is derived and rebuildable under `~/.allbert/memory/index/semantic/`.

## Stats And Verification

Use:

```bash
cargo run -p allbert-cli -- memory stats
cargo run -p allbert-cli -- memory verify
```

`memory stats` reports durable, staged, episode, and fact counts plus index metadata. `memory verify` remains the reconciliation check for markdown ground truth versus derived artifacts.

## Recovery

v0.12.1 makes memory forget/reject operations reversible within retention windows:

```bash
cargo run -p allbert-cli -- memory forget "notes/projects/postgres.md" --confirm
cargo run -p allbert-cli -- memory restore notes_projects_postgres
cargo run -p allbert-cli -- memory reject <staged-id> --reason "not durable"
cargo run -p allbert-cli -- memory reconsider <staged-id>
cargo run -p allbert-cli -- memory recovery-gc
```

Durable-memory trash entries live under `~/.allbert/memory/trash/` with original id, original path, deletion time, and reason metadata. Restore refuses to overwrite a live memory path.

Soft-rejected staged entries live under `~/.allbert/memory/reject/<session>/` with original staged id, source session, rejection time, and reason metadata. Reconsider refuses to collide with an active staged entry of the same id. Retention is controlled by:

```toml
[memory]
trash_retention_days = 30
rejected_retention_days = 30
```

## Related Docs

- [Telemetry operator guide](telemetry.md)
- [Personality digest guide](personality-digest.md)
- [v0.12.1 upgrade notes](../notes/v0.12.1-upgrade-2026-04-25.md)
