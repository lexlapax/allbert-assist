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
        "setup version:        {}\nretriever schema:     {}\nindexed docs:         {}\nstaged entries:       {}\nrejected entries:     {}\nexpired pending:      {}\nindex age:            {}\nlast rebuild reason:  {}\nlast rebuild elapsed: {} ms",
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
