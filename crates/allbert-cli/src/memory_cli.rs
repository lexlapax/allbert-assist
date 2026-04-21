use std::io::{self, Write};

use allbert_kernel::{memory, AllbertPaths, Config, MemoryTier, SearchMemoryInput};
use anyhow::{anyhow, Result};
use time::format_description::well_known::Rfc3339;
use time::OffsetDateTime;

pub fn status(paths: &AllbertPaths, config: &Config) -> Result<String> {
    let snapshot = memory::memory_status(paths, &config.memory, config.setup.version)?;
    let staged = if snapshot.staged_counts.is_empty() {
        "none".to_string()
    } else {
        snapshot
            .staged_counts
            .iter()
            .map(|(kind, count)| format!("{kind}={count}"))
            .collect::<Vec<_>>()
            .join(", ")
    };
    let age = snapshot
        .index_age_seconds
        .map(|seconds| format!("{seconds}s"))
        .unwrap_or_else(|| "unknown".into());
    Ok(format!(
        "profile version:      {}\nretriever schema:     {}\nindexed docs:         {}\nstaged entries:       {}\nrejected entries:     {}\nexpired pending:      {}\nindex age:            {}\nlast rebuild reason:  {}\nlast rebuild elapsed: {} ms",
        snapshot.setup_version,
        snapshot.schema_version,
        snapshot.manifest_docs,
        staged,
        snapshot.rejected_count,
        snapshot.expired_pending_count,
        age,
        snapshot
            .last_rebuild_reason
            .unwrap_or_else(|| "unknown".into()),
        snapshot.last_rebuild_elapsed_ms.unwrap_or_default()
    ))
}

pub fn search(
    paths: &AllbertPaths,
    config: &Config,
    query: &str,
    tier: &str,
    limit: Option<usize>,
    format: &str,
) -> Result<String> {
    let tier = parse_tier(tier)?;
    let hits = memory::search_memory(
        paths,
        &config.memory,
        SearchMemoryInput {
            query: query.to_string(),
            tier,
            limit,
        },
    )?;
    if format == "json" {
        return Ok(serde_json::to_string_pretty(&hits)?);
    }
    if hits.is_empty() {
        return Ok("no memory results".into());
    }
    Ok(hits
        .iter()
        .map(|hit| {
            format!(
                "{} [{}] score={:.3}\n  path: {}\n  tags: {}\n  excerpt: {}",
                hit.title,
                hit.tier,
                hit.score,
                hit.path,
                if hit.tags.is_empty() {
                    "none".into()
                } else {
                    hit.tags.join(", ")
                },
                if hit.snippet.is_empty() {
                    "(no excerpt)".into()
                } else {
                    hit.snippet.clone()
                }
            )
        })
        .collect::<Vec<_>>()
        .join("\n\n"))
}

pub fn staged_list(
    paths: &AllbertPaths,
    config: &Config,
    kind: Option<&str>,
    since: Option<&str>,
    limit: Option<usize>,
    format: &str,
) -> Result<String> {
    let since = since.map(parse_since).transpose()?;
    let entries = memory::list_staged_memory(paths, &config.memory, kind, since, limit)?;
    if format == "json" {
        return Ok(serde_json::to_string_pretty(&entries)?);
    }
    if entries.is_empty() {
        return Ok("no staged memory entries".into());
    }
    Ok(entries
        .iter()
        .map(|entry| {
            format!(
                "{} [{}]\n  id: {}\n  source: {} via {}\n  tags: {}\n  created: {}\n  summary: {}\n  excerpt: {}",
                entry.summary,
                entry.kind,
                entry.id,
                entry.agent,
                entry.source,
                if entry.tags.is_empty() {
                    "none".into()
                } else {
                    entry.tags.join(", ")
                },
                entry.created_at,
                entry.summary,
                truncate_inline(&entry.body, 120)
            )
        })
        .collect::<Vec<_>>()
        .join("\n\n"))
}

pub fn staged_show(paths: &AllbertPaths, config: &Config, id: &str) -> Result<String> {
    let entry = memory::get_staged_memory(paths, &config.memory, id)?;
    Ok(format!(
        "id: {}\npath: {}\nagent: {}\nsession: {}\nturn: {}\nkind: {}\nsource: {}\nsummary: {}\ntags: {}\nfingerprint: {}\ncreated: {}\nexpires: {}\nprovenance: {}\n\n{}",
        entry.id,
        entry.path,
        entry.agent,
        entry.session_id,
        entry.turn_id,
        entry.kind,
        entry.source,
        entry.summary,
        if entry.tags.is_empty() {
            "none".into()
        } else {
            entry.tags.join(", ")
        },
        entry.fingerprint,
        entry.created_at,
        entry.expires_at,
        entry
            .provenance
            .as_ref()
            .map(|value| serde_json::to_string_pretty(value).unwrap_or_else(|_| "{}".into()))
            .unwrap_or_else(|| "none".into()),
        entry.body
    ))
}

pub fn promote(
    paths: &AllbertPaths,
    config: &Config,
    id: &str,
    path: Option<&str>,
    summary: Option<&str>,
    confirm: bool,
) -> Result<String> {
    let preview = memory::preview_promote_staged_memory(paths, &config.memory, id, path, summary)?;
    if !confirm && !prompt_yes_no(&preview.rendered)? {
        return Ok("memory promotion cancelled".into());
    }
    let destination = memory::promote_staged_memory(paths, &config.memory, &preview)?;
    Ok(format!(
        "{}\n\npromoted staged memory {} -> {}",
        preview.rendered, id, destination
    ))
}

pub fn reject(
    paths: &AllbertPaths,
    config: &Config,
    id: &str,
    reason: Option<&str>,
) -> Result<String> {
    let rejected = memory::reject_staged_memory(paths, &config.memory, id, reason)?;
    Ok(format!("rejected staged memory {id}\npath: {rejected}"))
}

pub fn forget(
    paths: &AllbertPaths,
    config: &Config,
    target: &str,
    confirm: bool,
) -> Result<String> {
    let preview = memory::preview_forget_memory(paths, &config.memory, target)?;
    if !confirm {
        return Ok(format!(
            "{}\n\nRefusing to forget without --confirm.",
            preview.rendered
        ));
    }
    let forgotten = memory::forget_memory(paths, &config.memory, &preview)?;
    Ok(format!(
        "{}\n\nforgot durable memory:\n{}",
        preview.rendered,
        forgotten
            .iter()
            .map(|path| format!("- {path}"))
            .collect::<Vec<_>>()
            .join("\n")
    ))
}

pub fn rebuild_index(paths: &AllbertPaths, config: &Config, force: bool) -> Result<String> {
    let report = memory::rebuild_memory_index(paths, &config.memory, force)?;
    Ok(format!(
        "rebuilt memory index\nreason: {}\ndocs indexed: {}\nelapsed: {} ms",
        report.reason, report.docs_indexed, report.elapsed_ms
    ))
}

fn parse_tier(input: &str) -> Result<MemoryTier> {
    match input.trim().to_ascii_lowercase().as_str() {
        "durable" => Ok(MemoryTier::Durable),
        "staging" => Ok(MemoryTier::Staging),
        "all" => Ok(MemoryTier::All),
        other => Err(anyhow!("unsupported memory tier: {other}")),
    }
}

fn parse_since(input: &str) -> Result<OffsetDateTime> {
    let trimmed = input.trim();
    if trimmed.is_empty() {
        return Err(anyhow!("--since must not be empty"));
    }
    let (number, unit) = trimmed.split_at(trimmed.len().saturating_sub(1));
    let value: i64 = number.parse()?;
    let delta = match unit {
        "m" => time::Duration::minutes(value),
        "h" => time::Duration::hours(value),
        "d" => time::Duration::days(value),
        _ => {
            return OffsetDateTime::parse(trimmed, &Rfc3339)
                .map_err(|e| anyhow!("invalid --since value '{trimmed}': {e}"));
        }
    };
    Ok(OffsetDateTime::now_utc() - delta)
}

fn truncate_inline(input: &str, max: usize) -> String {
    let single = input.split_whitespace().collect::<Vec<_>>().join(" ");
    if single.len() <= max {
        single
    } else {
        format!("{}...", &single[..max.saturating_sub(3)])
    }
}

fn prompt_yes_no(rendered: &str) -> Result<bool> {
    print!("{rendered}\n[y/N] ");
    io::stdout().flush()?;
    let mut buf = String::new();
    io::stdin().read_line(&mut buf)?;
    let choice = buf.trim().to_ascii_lowercase();
    Ok(matches!(choice.as_str(), "y" | "yes"))
}

#[cfg(test)]
mod tests {
    use std::path::PathBuf;
    use std::sync::atomic::{AtomicUsize, Ordering};

    use allbert_kernel::{memory, AllbertPaths, Config, MemoryTier, SearchMemoryInput};

    use super::{forget, promote, reject, search, staged_list, staged_show, status};

    static TEMP_COUNTER: AtomicUsize = AtomicUsize::new(0);

    struct TempRoot {
        path: PathBuf,
    }

    impl TempRoot {
        fn new() -> Self {
            let counter = TEMP_COUNTER.fetch_add(1, Ordering::Relaxed);
            let unique = format!(
                "allbert-cli-memory-test-{}-{}-{}",
                std::process::id(),
                counter,
                std::time::SystemTime::now()
                    .duration_since(std::time::UNIX_EPOCH)
                    .expect("time should be monotonic")
                    .as_nanos()
            );
            let path = std::env::temp_dir().join(unique);
            std::fs::create_dir_all(&path).expect("temp root should be created");
            Self { path }
        }

        fn paths(&self) -> AllbertPaths {
            AllbertPaths::under(self.path.join("allbert-home"))
        }
    }

    impl Drop for TempRoot {
        fn drop(&mut self) {
            let _ = std::fs::remove_dir_all(&self.path);
        }
    }

    fn stage(
        paths: &AllbertPaths,
        config: &Config,
        summary: &str,
        content: &str,
    ) -> memory::StagedMemoryRecord {
        memory::stage_memory(
            paths,
            &config.memory,
            memory::StageMemoryRequest {
                session_id: "session-1".into(),
                turn_id: "turn-1".into(),
                agent: "allbert/root".into(),
                source: "channel".into(),
                content: content.into(),
                kind: memory::StagedMemoryKind::LearnedFact,
                summary: summary.into(),
                tags: vec!["database".into()],
                provenance: None,
            },
        )
        .expect("staging should succeed")
    }

    #[test]
    fn status_reports_curated_memory_fields() {
        let temp = TempRoot::new();
        let paths = temp.paths();
        let config = Config::load_or_create(&paths).expect("config should load");

        let rendered = status(&paths, &config).expect("status should render");
        assert!(rendered.contains("profile version:"));
        assert!(rendered.contains("retriever schema:"));
        assert!(rendered.contains("indexed docs:"));
        assert!(rendered.contains("staged entries:"));
    }

    #[test]
    fn cli_memory_flow_renders_search_stage_promote_reject_and_forget() {
        let temp = TempRoot::new();
        let paths = temp.paths();
        let config = Config::load_or_create(&paths).expect("config should load");

        let promoted = stage(
            &paths,
            &config,
            "Primary database is Postgres",
            "We use Postgres for primary storage.",
        );
        let rejected = stage(
            &paths,
            &config,
            "Temporary experiment note",
            "We might maybe try Cassandra later.",
        );

        let staged = staged_list(&paths, &config, None, None, Some(10), "text")
            .expect("staged list should render");
        assert!(staged.contains("Primary database is Postgres"));
        assert!(staged.contains("Temporary experiment note"));

        let shown = staged_show(&paths, &config, &promoted.id).expect("staged show should render");
        assert!(shown.contains("summary: Primary database is Postgres"));
        assert!(shown.contains("kind: learned_fact"));

        let promoted_output =
            promote(&paths, &config, &promoted.id, None, None, true).expect("promote should work");
        assert!(promoted_output.contains("promoted staged memory"));

        let durable = search(&paths, &config, "Postgres", "durable", Some(10), "text")
            .expect("durable search should render");
        assert!(durable.contains("Postgres"));

        let rejected_output =
            reject(&paths, &config, &rejected.id, Some("not durable")).expect("reject should work");
        assert!(rejected_output.contains("rejected staged memory"));

        let staging_results = memory::search_memory(
            &paths,
            &config.memory,
            SearchMemoryInput {
                query: "Cassandra".into(),
                tier: MemoryTier::Staging,
                limit: Some(10),
            },
        )
        .expect("staging search should succeed");
        assert!(
            staging_results.is_empty(),
            "rejected staged entry should leave staging search empty"
        );

        let durable_hits = memory::search_memory(
            &paths,
            &config.memory,
            SearchMemoryInput {
                query: "Postgres".into(),
                tier: MemoryTier::Durable,
                limit: Some(10),
            },
        )
        .expect("durable search should succeed");
        let durable_path = durable_hits
            .first()
            .expect("promoted note should be searchable")
            .path
            .clone();

        let forgotten =
            forget(&paths, &config, &durable_path, true).expect("forget should succeed");
        assert!(forgotten.contains("forgot durable memory"));

        let durable_after_forget = search(&paths, &config, "Postgres", "durable", Some(10), "text")
            .expect("durable search should render");
        assert_eq!(durable_after_forget, "no memory results");
    }
}
