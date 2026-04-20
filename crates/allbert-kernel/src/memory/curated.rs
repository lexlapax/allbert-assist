// v0.5 picks tantivy so the retriever index stays durable, filterable, and cheap to reopen
// without turning Allbert into a search-engine project. If this dependency becomes too heavy
// or the runtime targets change, revisit ADR 0046 before replacing this module.

use std::collections::BTreeMap;
use std::fs::{self, File};
use std::io::Write;
use std::path::{Path, PathBuf};
use std::time::SystemTime;

use fs2::FileExt;
use pulldown_cmark::{Event, Parser, Tag, TagEnd};
use serde::{Deserialize, Serialize};
use serde_json::json;
use serde_json::Value as JsonValue;
use sha2::{Digest, Sha256};
use tantivy::collector::TopDocs;
use tantivy::doc;
use tantivy::query::{BooleanQuery, Occur, Query, QueryParser, TermQuery};
use tantivy::schema::document::TantivyDocument;
use tantivy::schema::Value;
use tantivy::schema::{IndexRecordOption, Schema, INDEXED, STORED, STRING, TEXT};
use tantivy::{Index, Term};
use time::format_description::well_known::Rfc3339;
use time::OffsetDateTime;

use crate::config::MemoryConfig;
use crate::error::KernelError;
use crate::paths::AllbertPaths;

const MANIFEST_SCHEMA_VERSION: u32 = 1;
const INDEX_SCHEMA_VERSION: u32 = 1;
const TANTIVY_VERSION: &str = "0.22";
const STAGED_BODY_MAX_BYTES: usize = 16 * 1024;

#[derive(Debug, Clone, Copy, Serialize, Deserialize, PartialEq, Eq)]
#[serde(rename_all = "snake_case")]
pub enum MemoryTier {
    Durable,
    Staging,
    All,
}

impl Default for MemoryTier {
    fn default() -> Self {
        Self::Durable
    }
}

#[derive(Debug, Clone, Copy, Serialize, Deserialize, PartialEq, Eq)]
#[serde(rename_all = "snake_case")]
pub enum StagedMemoryKind {
    ExplicitRequest,
    LearnedFact,
    JobSummary,
    SubagentResult,
    CuratorExtraction,
}

impl StagedMemoryKind {
    fn as_str(self) -> &'static str {
        match self {
            Self::ExplicitRequest => "explicit_request",
            Self::LearnedFact => "learned_fact",
            Self::JobSummary => "job_summary",
            Self::SubagentResult => "subagent_result",
            Self::CuratorExtraction => "curator_extraction",
        }
    }
}

#[derive(Debug, Clone, Deserialize)]
pub struct SearchMemoryInput {
    pub query: String,
    #[serde(default)]
    pub tier: MemoryTier,
    #[serde(default)]
    pub limit: Option<usize>,
}

#[derive(Debug, Clone, Serialize)]
pub struct SearchMemoryHit {
    pub path: String,
    pub title: String,
    pub tier: String,
    pub score: f32,
    pub tags: Vec<String>,
    pub snippet: String,
}

#[derive(Debug, Clone, Deserialize)]
pub struct StageMemoryInput {
    pub content: String,
    pub kind: StagedMemoryKind,
    pub summary: String,
    #[serde(default)]
    pub tags: Vec<String>,
    #[serde(default)]
    pub provenance: Option<JsonValue>,
}

#[derive(Debug, Clone)]
pub struct StageMemoryRequest {
    pub session_id: String,
    pub turn_id: String,
    pub agent: String,
    pub source: String,
    pub content: String,
    pub kind: StagedMemoryKind,
    pub summary: String,
    pub tags: Vec<String>,
    pub provenance: Option<JsonValue>,
}

#[derive(Debug, Clone, Serialize)]
pub struct StagedMemoryRecord {
    pub id: String,
    pub path: String,
    pub agent: String,
    pub session_id: String,
    pub turn_id: String,
    pub kind: String,
    pub summary: String,
    pub source: String,
    pub provenance: Option<JsonValue>,
    pub tags: Vec<String>,
    pub fingerprint: String,
    pub created_at: String,
    pub expires_at: String,
    pub body: String,
}

#[derive(Debug, Clone, Serialize)]
pub struct MemoryPromotionPreview {
    pub id: String,
    pub source_path: String,
    pub destination_path: String,
    pub title: String,
    pub summary: String,
    pub tags: Vec<String>,
    pub agent: String,
    pub provenance: Option<JsonValue>,
    pub rendered: String,
}

#[derive(Debug, Clone, Serialize)]
pub struct MemoryForgetPreview {
    pub query: String,
    pub rendered: String,
    pub targets: Vec<ForgetTarget>,
}

#[derive(Debug, Clone, Serialize)]
pub struct ForgetTarget {
    pub path: String,
    pub title: String,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct MemoryManifest {
    pub schema_version: u32,
    pub documents: Vec<MemoryManifestEntry>,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct MemoryManifestEntry {
    pub path: String,
    pub title: String,
    #[serde(default)]
    pub tags: Vec<String>,
    pub content_hash: String,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct MemoryIndexMeta {
    pub schema_version: u32,
    pub tantivy_version: String,
    pub last_rebuild_at: String,
    pub last_rebuild_reason: String,
    pub doc_count: usize,
    pub manifest_hash: String,
    pub elapsed_ms: u128,
}

#[derive(Debug, Clone)]
pub struct MemoryBootstrapReport {
    pub imported_legacy_files: usize,
    pub expired_staged_entries: usize,
    pub manifest_rebuilt: bool,
    pub rebuild_report: Option<RebuildIndexReport>,
}

#[derive(Debug, Clone)]
pub struct RebuildIndexReport {
    pub reason: String,
    pub docs_indexed: usize,
    pub elapsed_ms: u128,
}

#[derive(Debug, Clone)]
pub struct MemoryStatusSnapshot {
    pub setup_version: u8,
    pub manifest_docs: usize,
    pub staged_counts: BTreeMap<String, usize>,
    pub rejected_count: usize,
    pub expired_pending_count: usize,
    pub index_age_seconds: Option<u64>,
    pub last_rebuild_reason: Option<String>,
    pub last_rebuild_elapsed_ms: Option<u128>,
    pub schema_version: u32,
}

#[derive(Debug, Serialize, Deserialize)]
struct StageFrontmatter {
    #[serde(default)]
    id: Option<String>,
    #[serde(default)]
    agent: Option<String>,
    #[serde(default)]
    session_id: Option<String>,
    #[serde(default)]
    turn_id: Option<String>,
    #[serde(default)]
    kind: Option<String>,
    #[serde(default)]
    summary: Option<String>,
    #[serde(default)]
    source: Option<String>,
    #[serde(default)]
    provenance: Option<JsonValue>,
    #[serde(default)]
    tags: Option<Vec<String>>,
    #[serde(default)]
    fingerprint: Option<String>,
    #[serde(default)]
    created_at: Option<String>,
    #[serde(default)]
    expires_at: Option<String>,
}

fn empty_stage_frontmatter() -> StageFrontmatter {
    StageFrontmatter {
        id: None,
        agent: None,
        session_id: None,
        turn_id: None,
        kind: None,
        summary: None,
        source: None,
        provenance: None,
        tags: None,
        fingerprint: None,
        created_at: None,
        expires_at: None,
    }
}

pub fn bootstrap_curated_memory(
    paths: &AllbertPaths,
    config: &MemoryConfig,
) -> Result<MemoryBootstrapReport, KernelError> {
    ensure_curated_dirs(paths)?;

    let imported_legacy_files = import_legacy_v0_4_buckets(paths)?;
    let manifest_rebuilt = if !paths.memory_manifest.exists() {
        let manifest = scan_manifest(paths)?;
        write_manifest(paths, &manifest)?;
        true
    } else {
        false
    };

    let expired_staged_entries = expire_staged_entries(paths, config)?;
    let manifest = load_manifest(paths)?;
    let rebuild_report = maybe_rebuild_index(paths, &manifest, false, None)?;

    Ok(MemoryBootstrapReport {
        imported_legacy_files,
        expired_staged_entries,
        manifest_rebuilt,
        rebuild_report,
    })
}

pub fn rebuild_memory_index(
    paths: &AllbertPaths,
    _config: &MemoryConfig,
    force: bool,
) -> Result<RebuildIndexReport, KernelError> {
    ensure_curated_dirs(paths)?;
    if !paths.memory_manifest.exists() {
        write_manifest(paths, &scan_manifest(paths)?)?;
    }
    let manifest = load_manifest(paths)?;
    maybe_rebuild_index(paths, &manifest, force, Some("operator-request"))?
        .ok_or_else(|| KernelError::InitFailed("index rebuild skipped unexpectedly".into()))
}

pub fn memory_status(
    paths: &AllbertPaths,
    config: &MemoryConfig,
    setup_version: u8,
) -> Result<MemoryStatusSnapshot, KernelError> {
    let _ = bootstrap_curated_memory(paths, config)?;
    let manifest = load_manifest(paths)?;
    let meta = load_index_meta(paths).ok();
    let mut staged_counts = BTreeMap::new();
    let mut expired_pending_count = 0usize;

    for entry in list_staging_entries(&paths.memory_staging)? {
        let frontmatter = parse_stage_frontmatter(&entry)?;
        let kind = frontmatter.kind.unwrap_or_else(|| "unknown".to_string());
        *staged_counts.entry(kind).or_insert(0) += 1;
        if let Some(expires_at) = frontmatter.expires_at {
            if let Ok(ts) = OffsetDateTime::parse(&expires_at, &Rfc3339) {
                if ts <= OffsetDateTime::now_utc() {
                    expired_pending_count += 1;
                }
            }
        }
    }

    let rejected_count = count_markdown_files(&paths.memory_staging_rejected)?;
    let index_age_seconds = meta
        .as_ref()
        .and_then(|value| OffsetDateTime::parse(&value.last_rebuild_at, &Rfc3339).ok())
        .map(|ts| {
            let now = OffsetDateTime::now_utc();
            (now - ts).whole_seconds().max(0) as u64
        });

    Ok(MemoryStatusSnapshot {
        setup_version,
        manifest_docs: manifest.documents.len(),
        staged_counts,
        rejected_count,
        expired_pending_count,
        index_age_seconds,
        last_rebuild_reason: meta.as_ref().map(|value| value.last_rebuild_reason.clone()),
        last_rebuild_elapsed_ms: meta.as_ref().map(|value| value.elapsed_ms),
        schema_version: INDEX_SCHEMA_VERSION,
    })
}

pub fn search_memory(
    paths: &AllbertPaths,
    config: &MemoryConfig,
    input: SearchMemoryInput,
) -> Result<Vec<SearchMemoryHit>, KernelError> {
    let _ = bootstrap_curated_memory(paths, config)?;
    let raw_query = input.query.trim();
    if raw_query.is_empty() {
        return Err(KernelError::InitFailed(
            "search_memory.query must not be empty".into(),
        ));
    }

    let limit = input
        .limit
        .unwrap_or(config.default_search_limit)
        .clamp(1, 100);
    let tantivy_dir = paths.memory_index_dir.join("tantivy");
    let index = Index::open_in_dir(&tantivy_dir)
        .map_err(|e| KernelError::InitFailed(format!("open tantivy index: {e}")))?;
    let schema = index.schema();
    let title_f = schema.get_field("title").expect("title field");
    let body_f = schema.get_field("body").expect("body field");
    let tags_f = schema.get_field("tags").expect("tags field");
    let tier_f = schema.get_field("tier").expect("tier field");
    let path_f = schema.get_field("path").expect("path field");
    let parser = QueryParser::for_index(&index, vec![title_f, body_f, tags_f]);
    let parsed_query = parser
        .parse_query(raw_query)
        .map_err(|e| KernelError::InitFailed(format!("parse query '{raw_query}': {e}")))?;
    let compiled_query: Box<dyn Query> = match input.tier {
        MemoryTier::All => Box::new(parsed_query),
        MemoryTier::Durable | MemoryTier::Staging => {
            let wanted = match input.tier {
                MemoryTier::Durable => "durable",
                MemoryTier::Staging => "staging",
                MemoryTier::All => unreachable!(),
            };
            let tier_query = TermQuery::new(
                Term::from_field_text(tier_f, wanted),
                IndexRecordOption::Basic,
            );
            Box::new(BooleanQuery::new(vec![
                (Occur::Must, Box::new(parsed_query)),
                (Occur::Must, Box::new(tier_query)),
            ]))
        }
    };

    let reader = index
        .reader()
        .map_err(|e| KernelError::InitFailed(format!("open tantivy reader: {e}")))?;
    let searcher = reader.searcher();
    let top_docs = searcher
        .search(&compiled_query, &TopDocs::with_limit(limit))
        .map_err(|e| KernelError::InitFailed(format!("search memory index: {e}")))?;

    let mut hits = Vec::new();
    for (score, addr) in top_docs {
        let doc: TantivyDocument = searcher
            .doc(addr)
            .map_err(|e| KernelError::InitFailed(format!("load search hit: {e}")))?;
        let path = doc_text(&doc, path_f).unwrap_or_default();
        let title = doc_text(&doc, title_f).unwrap_or_else(|| "untitled".into());
        let tier = doc_text(&doc, tier_f).unwrap_or_else(|| "durable".into());
        let tags = split_csv_tags(doc_text(&doc, tags_f).unwrap_or_default());
        let snippet = excerpt_for_relative_path(paths, &path, raw_query, 220);
        hits.push(SearchMemoryHit {
            path,
            title,
            tier,
            score,
            tags,
            snippet,
        });
    }

    hits.sort_by(|a, b| {
        b.score
            .partial_cmp(&a.score)
            .unwrap_or(std::cmp::Ordering::Equal)
            .then_with(|| a.path.cmp(&b.path))
    });
    Ok(hits)
}

pub fn stage_memory(
    paths: &AllbertPaths,
    config: &MemoryConfig,
    request: StageMemoryRequest,
) -> Result<StagedMemoryRecord, KernelError> {
    let _ = bootstrap_curated_memory(paths, config)?;
    let current_staged = list_staging_entries(&paths.memory_staging)?;
    if current_staged.len() >= config.staged_total_cap {
        return Err(KernelError::InitFailed(format!(
            "staging global cap exceeded ({} entries)",
            config.staged_total_cap
        )));
    }

    let summary = request.summary.trim();
    if summary.is_empty() {
        return Err(KernelError::InitFailed(
            "stage_memory.summary must not be empty".into(),
        ));
    }

    let normalized_body = normalized_markdown_body(&request.content);
    let fingerprint = format!("sha256:{}", sha256_hex(normalized_body.as_bytes()));
    if durable_fingerprint_exists(paths, &fingerprint)? {
        return Err(KernelError::InitFailed(format!(
            "staging rejected: content already exists in durable memory ({fingerprint})"
        )));
    }

    let ttl_cutoff =
        OffsetDateTime::now_utc() - time::Duration::days(i64::from(config.staged_entry_ttl_days));
    for entry in current_staged {
        let raw = fs::read_to_string(&entry)
            .map_err(|e| KernelError::InitFailed(format!("read {}: {e}", entry.display())))?;
        let (frontmatter_raw, body_raw) = split_frontmatter_and_body(&raw);
        let frontmatter: StageFrontmatter = if frontmatter_raw.is_empty() {
            empty_stage_frontmatter()
        } else {
            serde_yaml::from_str(frontmatter_raw).map_err(|e| {
                KernelError::InitFailed(format!("parse {} frontmatter: {e}", entry.display()))
            })?
        };
        let duplicate = frontmatter
            .fingerprint
            .as_deref()
            .map(|value| value == fingerprint)
            .unwrap_or_else(|| normalized_markdown_body(&body_raw) == normalized_body);
        if !duplicate {
            continue;
        }
        let fresh_enough = frontmatter
            .created_at
            .as_deref()
            .and_then(|value| OffsetDateTime::parse(value, &Rfc3339).ok())
            .map(|created| created >= ttl_cutoff)
            .unwrap_or(true);
        if fresh_enough {
            return Err(KernelError::InitFailed(format!(
                "staging duplicate rejected for fingerprint {fingerprint}"
            )));
        }
    }

    let mut body = request.content.trim().to_string();
    if body.as_bytes().len() > STAGED_BODY_MAX_BYTES {
        body = truncate_to_bytes(&body, STAGED_BODY_MAX_BYTES.saturating_sub(14));
        if !body.ends_with('\n') {
            body.push('\n');
        }
        body.push_str("[truncated]\n");
    }

    let created_at = OffsetDateTime::now_utc();
    let expires_at = created_at + time::Duration::days(i64::from(config.staged_entry_ttl_days));
    let id = format!("stg_{}", uuid::Uuid::new_v4().simple());
    let mut tag_set = BTreeMap::<String, ()>::new();
    for tag in request.tags {
        let lowered = tag.trim().to_ascii_lowercase();
        if !lowered.is_empty() {
            tag_set.insert(lowered, ());
        }
    }
    let tags = tag_set.into_keys().collect::<Vec<_>>();
    let summary = truncate_to_bytes(summary, 240);

    let frontmatter = StageFrontmatter {
        id: Some(id.clone()),
        agent: Some(request.agent.clone()),
        session_id: Some(request.session_id.clone()),
        turn_id: Some(request.turn_id.clone()),
        kind: Some(request.kind.as_str().into()),
        summary: Some(summary.clone()),
        source: Some(request.source.clone()),
        provenance: request.provenance.clone(),
        tags: Some(tags.clone()),
        fingerprint: Some(fingerprint.clone()),
        created_at: Some(
            created_at
                .format(&Rfc3339)
                .map_err(|e| KernelError::InitFailed(format!("format timestamp: {e}")))?,
        ),
        expires_at: Some(
            expires_at
                .format(&Rfc3339)
                .map_err(|e| KernelError::InitFailed(format!("format timestamp: {e}")))?,
        ),
    };
    let rendered = render_staged_entry(&frontmatter, &body)?;
    let filename = staged_filename(&id, created_at);
    let path = paths.memory_staging.join(&filename);
    atomic_write(&path, rendered.as_bytes())?;
    let manifest = load_manifest(paths)?;
    let _ = maybe_rebuild_index(paths, &manifest, true, Some("stage-memory"))?;

    Ok(parse_staged_record(paths, &path)?)
}

pub fn list_staged_memory(
    paths: &AllbertPaths,
    config: &MemoryConfig,
    kind: Option<&str>,
    since: Option<OffsetDateTime>,
    limit: Option<usize>,
) -> Result<Vec<StagedMemoryRecord>, KernelError> {
    let _ = bootstrap_curated_memory(paths, config)?;
    let mut records = Vec::new();
    for path in list_staging_entries(&paths.memory_staging)? {
        let record = parse_staged_record(paths, &path)?;
        if let Some(kind_filter) = kind {
            if record.kind != kind_filter {
                continue;
            }
        }
        if let Some(since_ts) = since {
            let created = OffsetDateTime::parse(&record.created_at, &Rfc3339).map_err(|e| {
                KernelError::InitFailed(format!("parse staged created_at {}: {e}", record.id))
            })?;
            if created < since_ts {
                continue;
            }
        }
        records.push(record);
    }
    records.sort_by(|a, b| {
        b.created_at
            .cmp(&a.created_at)
            .then_with(|| a.id.cmp(&b.id))
    });
    if let Some(limit) = limit {
        records.truncate(limit);
    }
    Ok(records)
}

pub fn get_staged_memory(
    paths: &AllbertPaths,
    config: &MemoryConfig,
    id: &str,
) -> Result<StagedMemoryRecord, KernelError> {
    let _ = bootstrap_curated_memory(paths, config)?;
    let path = find_staged_entry_by_id(&paths.memory_staging, id)?
        .ok_or_else(|| KernelError::InitFailed(format!("staged memory entry not found: {id}")))?;
    parse_staged_record(paths, &path)
}

pub fn preview_promote_staged_memory(
    paths: &AllbertPaths,
    config: &MemoryConfig,
    id: &str,
    path_override: Option<&str>,
    summary_override: Option<&str>,
) -> Result<MemoryPromotionPreview, KernelError> {
    let _ = bootstrap_curated_memory(paths, config)?;
    let record = get_staged_memory(paths, config, id)?;
    let title = summary_override
        .map(str::trim)
        .filter(|value| !value.is_empty())
        .map(ToOwned::to_owned)
        .unwrap_or_else(|| record.summary.clone());
    let destination_path = if let Some(path_override) = path_override {
        sanitize_promote_relative_path(path_override)?
    } else {
        default_promote_relative_path(&record)
    };
    let rendered = format!(
        "Promote staged memory\n\
ID: {}\n\
Title: {}\n\
Kind: {}\n\
Agent: {}\n\
Tags: {}\n\
Source file: {}\n\
Destination: {}\n\
Provenance: {}",
        record.id,
        title,
        record.kind,
        record.agent,
        if record.tags.is_empty() {
            "none".into()
        } else {
            record.tags.join(", ")
        },
        record.path,
        destination_path,
        record
            .provenance
            .as_ref()
            .map(|value| serde_json::to_string_pretty(value).unwrap_or_else(|_| "{}".into()))
            .unwrap_or_else(|| "none".into())
    );
    Ok(MemoryPromotionPreview {
        id: record.id,
        source_path: record.path,
        destination_path,
        title,
        summary: record.summary,
        tags: record.tags,
        agent: record.agent,
        provenance: record.provenance,
        rendered,
    })
}

pub fn promote_staged_memory(
    paths: &AllbertPaths,
    config: &MemoryConfig,
    preview: &MemoryPromotionPreview,
) -> Result<String, KernelError> {
    let _ = bootstrap_curated_memory(paths, config)?;
    let staged_path =
        find_staged_entry_by_id(&paths.memory_staging, &preview.id)?.ok_or_else(|| {
            KernelError::InitFailed(format!("staged memory entry not found: {}", preview.id))
        })?;
    let record = parse_staged_record(paths, &staged_path)?;
    let destination = paths.memory.join(&preview.destination_path);
    if let Some(parent) = destination.parent() {
        fs::create_dir_all(parent)
            .map_err(|e| KernelError::InitFailed(format!("create {}: {e}", parent.display())))?;
    }
    let durable_body = format!("# {}\n\n{}\n", preview.title.trim(), record.body.trim());
    atomic_write(&destination, durable_body.as_bytes())?;
    fs::remove_file(&staged_path)
        .map_err(|e| KernelError::InitFailed(format!("remove {}: {e}", staged_path.display())))?;
    let manifest = scan_manifest(paths)?;
    write_manifest(paths, &manifest)?;
    let _ = maybe_rebuild_index(paths, &manifest, true, Some("promote-staged-memory"))?;
    Ok(preview.destination_path.clone())
}

pub fn reject_staged_memory(
    paths: &AllbertPaths,
    config: &MemoryConfig,
    id: &str,
    reason: Option<&str>,
) -> Result<String, KernelError> {
    let _ = bootstrap_curated_memory(paths, config)?;
    let staged_path = find_staged_entry_by_id(&paths.memory_staging, id)?
        .ok_or_else(|| KernelError::InitFailed(format!("staged memory entry not found: {id}")))?;
    let raw = fs::read_to_string(&staged_path)
        .map_err(|e| KernelError::InitFailed(format!("read {}: {e}", staged_path.display())))?;
    let rejected_name = format!(
        "{}-{}.md",
        OffsetDateTime::now_utc()
            .format(&time::macros::format_description!(
                "[year][month][day]T[hour][minute][second]Z"
            ))
            .map_err(|e| KernelError::InitFailed(format!("format rejection time: {e}")))?,
        id
    );
    let dest = paths.memory_staging_rejected.join(&rejected_name);
    let rejection = json!({
        "reason": reason.unwrap_or("rejected by operator"),
        "rejected_at": now_rfc3339()?,
    });
    let wrapped = format!(
        "---\nrejection:\n  reason: {}\n  rejected_at: {}\n---\n\n{}",
        yaml_escape_scalar(
            rejection["reason"]
                .as_str()
                .unwrap_or("rejected by operator")
        ),
        rejection["rejected_at"].as_str().unwrap_or(""),
        raw
    );
    atomic_write(&dest, wrapped.as_bytes())?;
    fs::remove_file(&staged_path)
        .map_err(|e| KernelError::InitFailed(format!("remove {}: {e}", staged_path.display())))?;
    let manifest = load_manifest(paths)?;
    let _ = maybe_rebuild_index(paths, &manifest, true, Some("reject-staged-memory"))?;
    Ok(relative_to_memory(paths, &dest)?)
}

pub fn preview_forget_memory(
    paths: &AllbertPaths,
    config: &MemoryConfig,
    query: &str,
) -> Result<MemoryForgetPreview, KernelError> {
    let _ = bootstrap_curated_memory(paths, config)?;
    let query = query.trim();
    if query.is_empty() {
        return Err(KernelError::InitFailed(
            "forget target must not be empty".into(),
        ));
    }

    let mut targets = Vec::new();
    let candidate = paths.memory.join(query);
    if candidate.exists() && candidate.is_file() {
        let rel = relative_to_memory(paths, &candidate)?;
        if rel == "MEMORY.md" || rel.starts_with("notes/") {
            let raw = fs::read_to_string(&candidate).unwrap_or_default();
            targets.push(ForgetTarget {
                path: rel,
                title: derive_title(&raw, &candidate),
            });
        }
    }
    if targets.is_empty() {
        let hits = search_memory(
            paths,
            config,
            SearchMemoryInput {
                query: query.to_string(),
                tier: MemoryTier::Durable,
                limit: Some(5),
            },
        )?;
        for hit in hits {
            if hit.path == "MEMORY.md" || !hit.path.starts_with("notes/") {
                continue;
            }
            if !targets.iter().any(|target| target.path == hit.path) {
                targets.push(ForgetTarget {
                    path: hit.path,
                    title: hit.title,
                });
            }
        }
    }
    if targets.is_empty() {
        return Err(KernelError::InitFailed(format!(
            "no durable memory entries matched '{query}'"
        )));
    }

    let rendered = format!(
        "Forget durable memory\nQuery: {}\nTargets:\n{}",
        query,
        targets
            .iter()
            .map(|target| format!("- {} ({})", target.title, target.path))
            .collect::<Vec<_>>()
            .join("\n")
    );
    Ok(MemoryForgetPreview {
        query: query.to_string(),
        rendered,
        targets,
    })
}

pub fn forget_memory(
    paths: &AllbertPaths,
    config: &MemoryConfig,
    preview: &MemoryForgetPreview,
) -> Result<Vec<String>, KernelError> {
    let _ = bootstrap_curated_memory(paths, config)?;
    let mut forgotten = Vec::new();
    for target in &preview.targets {
        let source = paths.memory.join(&target.path);
        if !source.exists() {
            continue;
        }
        let trash_name = format!(
            "{}-{}",
            OffsetDateTime::now_utc()
                .format(&time::macros::format_description!(
                    "[year][month][day]T[hour][minute][second]Z"
                ))
                .map_err(|e| KernelError::InitFailed(format!("format trash timestamp: {e}")))?,
            source
                .file_name()
                .and_then(|value| value.to_str())
                .unwrap_or("memory.md")
        );
        let dest = paths.memory_trash.join(trash_name);
        fs::rename(&source, &dest).map_err(|e| {
            KernelError::InitFailed(format!(
                "move {} -> {}: {e}",
                source.display(),
                dest.display()
            ))
        })?;
        forgotten.push(target.path.clone());
    }
    let manifest = scan_manifest(paths)?;
    write_manifest(paths, &manifest)?;
    let _ = maybe_rebuild_index(paths, &manifest, true, Some("forget-memory"))?;
    Ok(forgotten)
}

fn ensure_curated_dirs(paths: &AllbertPaths) -> Result<(), KernelError> {
    for dir in [
        &paths.memory,
        &paths.memory_daily,
        &paths.memory_notes,
        &paths.memory_staging,
        &paths.memory_staging_expired,
        &paths.memory_staging_rejected,
        &paths.memory_index_dir,
        &paths.memory_migrations,
        &paths.memory_trash,
    ] {
        fs::create_dir_all(dir)
            .map_err(|e| KernelError::InitFailed(format!("create {}: {e}", dir.display())))?;
    }
    if !paths.memory_index.exists() {
        fs::write(&paths.memory_index, "# MEMORY\n\n").map_err(|e| {
            KernelError::InitFailed(format!("write {}: {e}", paths.memory_index.display()))
        })?;
    }
    ensure_file(&paths.memory_notes.join(".keep"), "")?;
    ensure_file(&paths.memory_staging.join(".keep"), "")?;
    ensure_file(&paths.memory_index_lock, "")?;
    Ok(())
}

fn ensure_file(path: &Path, contents: &str) -> Result<(), KernelError> {
    if !path.exists() {
        fs::write(path, contents)
            .map_err(|e| KernelError::InitFailed(format!("write {}: {e}", path.display())))?;
    }
    Ok(())
}

fn import_legacy_v0_4_buckets(paths: &AllbertPaths) -> Result<usize, KernelError> {
    let buckets = [
        ("topics", &paths.memory_topics),
        ("people", &paths.memory_people),
        ("projects", &paths.memory_projects),
        ("decisions", &paths.memory_decisions),
    ];
    let mut imported_files = 0usize;
    let mut report = Vec::<MigrationRecord>::new();
    let backup_root = &paths.memory_legacy_v04;
    let mut migrated_any = false;

    for (bucket, source) in buckets {
        if !source.exists() || is_effectively_empty_dir(source)? {
            continue;
        }
        migrated_any = true;
        let dest_root = paths.memory_notes.join(bucket);
        fs::create_dir_all(&dest_root)
            .map_err(|e| KernelError::InitFailed(format!("create {}: {e}", dest_root.display())))?;
        imported_files += copy_markdown_tree(source, &dest_root)?;

        fs::create_dir_all(backup_root).map_err(|e| {
            KernelError::InitFailed(format!("create {}: {e}", backup_root.display()))
        })?;
        let backup = backup_root.join(bucket);
        if backup.exists() {
            fs::remove_dir_all(&backup).map_err(|e| {
                KernelError::InitFailed(format!("remove {}: {e}", backup.display()))
            })?;
        }
        fs::rename(source, &backup).map_err(|e| {
            KernelError::InitFailed(format!(
                "move legacy memory bucket {} -> {}: {e}",
                source.display(),
                backup.display()
            ))
        })?;
        report.push(MigrationRecord {
            bucket: bucket.to_string(),
            imported_to: relative_to_memory(paths, &dest_root)?,
            backup_to: relative_to_memory(paths, &backup)?,
        });
    }

    if migrated_any {
        let report_path = paths.memory_migrations.join("v0.5-import.json");
        let rendered = serde_json::to_string_pretty(&report).map_err(|e| {
            KernelError::InitFailed(format!("serialize {}: {e}", report_path.display()))
        })?;
        fs::write(&report_path, rendered).map_err(|e| {
            KernelError::InitFailed(format!("write {}: {e}", report_path.display()))
        })?;
    }

    Ok(imported_files)
}

#[derive(Debug, Serialize)]
struct MigrationRecord {
    bucket: String,
    imported_to: String,
    backup_to: String,
}

fn maybe_rebuild_index(
    paths: &AllbertPaths,
    manifest: &MemoryManifest,
    force: bool,
    explicit_reason: Option<&str>,
) -> Result<Option<RebuildIndexReport>, KernelError> {
    let manifest_hash = manifest_hash(manifest)?;
    let meta = load_index_meta(paths).ok();
    let reason = if force {
        Some(explicit_reason.unwrap_or("force").to_string())
    } else if meta.is_none() {
        Some("missing-meta".into())
    } else {
        let meta = meta.as_ref().expect("checked is_some");
        if meta.schema_version != INDEX_SCHEMA_VERSION {
            Some("schema-version".into())
        } else if meta.manifest_hash != manifest_hash {
            Some("manifest-changed".into())
        } else if meta.doc_count != manifest.documents.len() {
            Some("doc-count-drift".into())
        } else {
            None
        }
    };

    if let Some(reason) = reason {
        Ok(Some(rebuild_index(paths, manifest, &reason)?))
    } else {
        Ok(None)
    }
}

fn rebuild_index(
    paths: &AllbertPaths,
    manifest: &MemoryManifest,
    reason: &str,
) -> Result<RebuildIndexReport, KernelError> {
    let lock = File::options()
        .read(true)
        .write(true)
        .create(true)
        .open(&paths.memory_index_lock)
        .map_err(|e| {
            KernelError::InitFailed(format!("open {}: {e}", paths.memory_index_lock.display()))
        })?;
    lock.lock_exclusive().map_err(|e| {
        KernelError::InitFailed(format!("lock {}: {e}", paths.memory_index_lock.display()))
    })?;

    let start = std::time::Instant::now();
    if paths.memory_index_dir.exists() {
        for entry in fs::read_dir(&paths.memory_index_dir).map_err(|e| {
            KernelError::InitFailed(format!("read {}: {e}", paths.memory_index_dir.display()))
        })? {
            let entry = entry.map_err(|e| KernelError::InitFailed(e.to_string()))?;
            let path = entry.path();
            if path == paths.memory_index_lock || path == paths.memory_index_meta {
                continue;
            }
            if path.is_dir() {
                fs::remove_dir_all(&path).map_err(|e| {
                    KernelError::InitFailed(format!("remove {}: {e}", path.display()))
                })?;
            } else {
                fs::remove_file(&path).map_err(|e| {
                    KernelError::InitFailed(format!("remove {}: {e}", path.display()))
                })?;
            }
        }
    }

    let tantivy_dir = paths.memory_index_dir.join("tantivy");
    if tantivy_dir.exists() {
        fs::remove_dir_all(&tantivy_dir).map_err(|e| {
            KernelError::InitFailed(format!("remove {}: {e}", tantivy_dir.display()))
        })?;
    }
    fs::create_dir_all(&tantivy_dir)
        .map_err(|e| KernelError::InitFailed(format!("create {}: {e}", tantivy_dir.display())))?;

    let schema = build_schema();
    let index = tantivy::Index::create_in_dir(&tantivy_dir, schema.clone())
        .map_err(|e| KernelError::InitFailed(format!("create tantivy index: {e}")))?;
    let mut writer = index
        .writer(20_000_000)
        .map_err(|e| KernelError::InitFailed(format!("open tantivy writer: {e}")))?;

    let id_f = schema.get_field("id").expect("id field");
    let path_f = schema.get_field("path").expect("path field");
    let title_f = schema.get_field("title").expect("title field");
    let body_f = schema.get_field("body").expect("body field");
    let tags_f = schema.get_field("tags").expect("tags field");
    let tier_f = schema.get_field("tier").expect("tier field");
    let date_f = schema.get_field("date").expect("date field");

    for entry in &manifest.documents {
        let full_path = paths.memory.join(&entry.path);
        let raw = fs::read_to_string(&full_path).unwrap_or_default();
        let body = markdown_to_plain_text(&raw);
        writer
            .add_document(doc!(
                id_f => entry.content_hash.clone(),
                path_f => entry.path.clone(),
                title_f => entry.title.clone(),
                body_f => body,
                tags_f => entry.tags.clone().join(","),
                tier_f => "durable",
                date_f => tantivy::DateTime::from_timestamp_secs(file_timestamp_secs(&full_path)),
            ))
            .map_err(|e| {
                KernelError::InitFailed(format!("index document {}: {e}", full_path.display()))
            })?;
    }

    for staged in list_staging_entries(&paths.memory_staging)? {
        let raw = fs::read_to_string(&staged).unwrap_or_default();
        let (frontmatter, body_markdown) = split_frontmatter_and_body(&raw);
        let frontmatter: StageFrontmatter =
            serde_yaml::from_str(frontmatter).unwrap_or_else(|_| {
                let mut fallback = empty_stage_frontmatter();
                fallback.kind = Some("unknown".into());
                fallback
            });
        let title = derive_title(&body_markdown, &staged);
        writer
            .add_document(doc!(
                id_f => sha256_hex(staged.to_string_lossy().as_bytes()),
                path_f => relative_to_memory(paths, &staged)?,
                title_f => title,
                body_f => markdown_to_plain_text(&body_markdown),
                tags_f => frontmatter.kind.unwrap_or_else(|| "unknown".into()),
                tier_f => "staging",
                date_f => tantivy::DateTime::from_timestamp_secs(file_timestamp_secs(&staged)),
            ))
            .map_err(|e| {
                KernelError::InitFailed(format!("index staged entry {}: {e}", staged.display()))
            })?;
    }

    writer
        .commit()
        .map_err(|e| KernelError::InitFailed(format!("commit tantivy index: {e}")))?;

    let elapsed_ms = start.elapsed().as_millis();
    let meta = MemoryIndexMeta {
        schema_version: INDEX_SCHEMA_VERSION,
        tantivy_version: TANTIVY_VERSION.into(),
        last_rebuild_at: now_rfc3339()?,
        last_rebuild_reason: reason.into(),
        doc_count: manifest.documents.len(),
        manifest_hash: manifest_hash(manifest)?,
        elapsed_ms,
    };
    write_index_meta(paths, &meta)?;
    lock.unlock().map_err(|e| {
        KernelError::InitFailed(format!("unlock {}: {e}", paths.memory_index_lock.display()))
    })?;

    Ok(RebuildIndexReport {
        reason: reason.into(),
        docs_indexed: meta.doc_count,
        elapsed_ms,
    })
}

fn write_index_meta(paths: &AllbertPaths, meta: &MemoryIndexMeta) -> Result<(), KernelError> {
    let rendered = serde_json::to_vec_pretty(meta)
        .map_err(|e| KernelError::InitFailed(format!("serialize index meta: {e}")))?;
    atomic_write(&paths.memory_index_meta, &rendered)
}

fn load_index_meta(paths: &AllbertPaths) -> Result<MemoryIndexMeta, KernelError> {
    let raw = fs::read_to_string(&paths.memory_index_meta).map_err(|e| {
        KernelError::InitFailed(format!("read {}: {e}", paths.memory_index_meta.display()))
    })?;
    serde_json::from_str(&raw).map_err(|e| {
        KernelError::InitFailed(format!("parse {}: {e}", paths.memory_index_meta.display()))
    })
}

fn scan_manifest(paths: &AllbertPaths) -> Result<MemoryManifest, KernelError> {
    let mut documents = Vec::new();
    collect_markdown_files(&paths.memory_notes, &paths.memory, &mut documents)?;
    collect_daily_files(&paths.memory_daily, &paths.memory, &mut documents)?;
    documents.sort_by(|a, b| a.path.cmp(&b.path));
    Ok(MemoryManifest {
        schema_version: MANIFEST_SCHEMA_VERSION,
        documents,
    })
}

fn collect_markdown_files(
    dir: &Path,
    memory_root: &Path,
    out: &mut Vec<MemoryManifestEntry>,
) -> Result<(), KernelError> {
    if !dir.exists() {
        return Ok(());
    }
    for entry in fs::read_dir(dir)
        .map_err(|e| KernelError::InitFailed(format!("read {}: {e}", dir.display())))?
    {
        let entry = entry.map_err(|e| KernelError::InitFailed(e.to_string()))?;
        let path = entry.path();
        let name = entry.file_name();
        let name = name.to_string_lossy();
        if name.starts_with('.') {
            continue;
        }
        if path.is_dir() {
            collect_markdown_files(&path, memory_root, out)?;
            continue;
        }
        if path.extension().and_then(|v| v.to_str()) != Some("md") {
            continue;
        }
        let raw = fs::read_to_string(&path)
            .map_err(|e| KernelError::InitFailed(format!("read {}: {e}", path.display())))?;
        out.push(MemoryManifestEntry {
            path: relative_to_memory_path(&path, memory_root)?,
            title: derive_title(&raw, &path),
            tags: Vec::new(),
            content_hash: sha256_hex(raw.as_bytes()),
        });
    }
    Ok(())
}

fn collect_daily_files(
    dir: &Path,
    memory_root: &Path,
    out: &mut Vec<MemoryManifestEntry>,
) -> Result<(), KernelError> {
    if !dir.exists() {
        return Ok(());
    }
    for entry in fs::read_dir(dir)
        .map_err(|e| KernelError::InitFailed(format!("read {}: {e}", dir.display())))?
    {
        let entry = entry.map_err(|e| KernelError::InitFailed(e.to_string()))?;
        let path = entry.path();
        if path.extension().and_then(|v| v.to_str()) != Some("md") {
            continue;
        }
        let raw = fs::read_to_string(&path)
            .map_err(|e| KernelError::InitFailed(format!("read {}: {e}", path.display())))?;
        out.push(MemoryManifestEntry {
            path: relative_to_memory_path(&path, memory_root)?,
            title: derive_title(&raw, &path),
            tags: vec!["daily".into()],
            content_hash: sha256_hex(raw.as_bytes()),
        });
    }
    Ok(())
}

fn write_manifest(paths: &AllbertPaths, manifest: &MemoryManifest) -> Result<(), KernelError> {
    let rendered = serde_json::to_vec_pretty(manifest)
        .map_err(|e| KernelError::InitFailed(format!("serialize manifest: {e}")))?;
    atomic_write(&paths.memory_manifest, &rendered)
}

fn load_manifest(paths: &AllbertPaths) -> Result<MemoryManifest, KernelError> {
    let raw = fs::read_to_string(&paths.memory_manifest).map_err(|e| {
        KernelError::InitFailed(format!("read {}: {e}", paths.memory_manifest.display()))
    })?;
    serde_json::from_str(&raw).map_err(|e| {
        KernelError::InitFailed(format!("parse {}: {e}", paths.memory_manifest.display()))
    })
}

fn expire_staged_entries(
    paths: &AllbertPaths,
    _config: &MemoryConfig,
) -> Result<usize, KernelError> {
    let mut moved = 0usize;
    for entry in list_staging_entries(&paths.memory_staging)? {
        let frontmatter = parse_stage_frontmatter(&entry)?;
        let Some(expires_at) = frontmatter.expires_at else {
            continue;
        };
        let Ok(expiry) = OffsetDateTime::parse(&expires_at, &Rfc3339) else {
            continue;
        };
        if expiry > OffsetDateTime::now_utc() {
            continue;
        }
        let dest = paths.memory_staging_expired.join(
            entry
                .file_name()
                .ok_or_else(|| KernelError::InitFailed("staged entry missing filename".into()))?,
        );
        fs::rename(&entry, &dest).map_err(|e| {
            KernelError::InitFailed(format!(
                "move expired staged entry {}: {e}",
                entry.display()
            ))
        })?;
        moved += 1;
    }
    Ok(moved)
}

fn list_staging_entries(dir: &Path) -> Result<Vec<PathBuf>, KernelError> {
    if !dir.exists() {
        return Ok(Vec::new());
    }
    let mut entries = Vec::new();
    for entry in fs::read_dir(dir)
        .map_err(|e| KernelError::InitFailed(format!("read {}: {e}", dir.display())))?
    {
        let entry = entry.map_err(|e| KernelError::InitFailed(e.to_string()))?;
        let path = entry.path();
        if path.is_dir() {
            continue;
        }
        if path.extension().and_then(|v| v.to_str()) != Some("md") {
            continue;
        }
        entries.push(path);
    }
    entries.sort();
    Ok(entries)
}

fn count_markdown_files(dir: &Path) -> Result<usize, KernelError> {
    if !dir.exists() {
        return Ok(0);
    }
    let mut count = 0usize;
    for entry in fs::read_dir(dir)
        .map_err(|e| KernelError::InitFailed(format!("read {}: {e}", dir.display())))?
    {
        let entry = entry.map_err(|e| KernelError::InitFailed(e.to_string()))?;
        let path = entry.path();
        if path.is_dir() {
            count += count_markdown_files(&path)?;
        } else if path.extension().and_then(|v| v.to_str()) == Some("md") {
            count += 1;
        }
    }
    Ok(count)
}

fn split_frontmatter_and_body(raw: &str) -> (&str, String) {
    if !raw.starts_with("---\n") {
        return ("", raw.to_string());
    }
    let remainder = &raw["---\n".len()..];
    let Some(end) = remainder.find("\n---\n") else {
        return ("", raw.to_string());
    };
    let frontmatter = &remainder[..end];
    let body = remainder[end + "\n---\n".len()..].to_string();
    (frontmatter, body)
}

fn parse_stage_frontmatter(path: &Path) -> Result<StageFrontmatter, KernelError> {
    let raw = fs::read_to_string(path)
        .map_err(|e| KernelError::InitFailed(format!("read {}: {e}", path.display())))?;
    let (frontmatter, _) = split_frontmatter_and_body(&raw);
    if frontmatter.is_empty() {
        return Ok(empty_stage_frontmatter());
    }
    serde_yaml::from_str(frontmatter)
        .map_err(|e| KernelError::InitFailed(format!("parse {} frontmatter: {e}", path.display())))
}

fn parse_staged_record(
    paths: &AllbertPaths,
    path: &Path,
) -> Result<StagedMemoryRecord, KernelError> {
    let raw = fs::read_to_string(path)
        .map_err(|e| KernelError::InitFailed(format!("read {}: {e}", path.display())))?;
    let (frontmatter_raw, body) = split_frontmatter_and_body(&raw);
    let frontmatter: StageFrontmatter = if frontmatter_raw.is_empty() {
        empty_stage_frontmatter()
    } else {
        serde_yaml::from_str(frontmatter_raw).map_err(|e| {
            KernelError::InitFailed(format!("parse {} frontmatter: {e}", path.display()))
        })?
    };
    Ok(StagedMemoryRecord {
        id: frontmatter.id.unwrap_or_else(|| "unknown".into()),
        path: relative_to_memory(paths, path)?,
        agent: frontmatter.agent.unwrap_or_else(|| "unknown".into()),
        session_id: frontmatter.session_id.unwrap_or_else(|| "unknown".into()),
        turn_id: frontmatter.turn_id.unwrap_or_else(|| "unknown".into()),
        kind: frontmatter.kind.unwrap_or_else(|| "unknown".into()),
        summary: frontmatter
            .summary
            .unwrap_or_else(|| derive_title(&body, path)),
        source: frontmatter.source.unwrap_or_else(|| "unknown".into()),
        provenance: frontmatter.provenance,
        tags: frontmatter.tags.unwrap_or_default(),
        fingerprint: frontmatter.fingerprint.unwrap_or_default(),
        created_at: frontmatter
            .created_at
            .unwrap_or_else(|| now_rfc3339().unwrap_or_default()),
        expires_at: frontmatter
            .expires_at
            .unwrap_or_else(|| now_rfc3339().unwrap_or_default()),
        body,
    })
}

fn render_staged_entry(frontmatter: &StageFrontmatter, body: &str) -> Result<String, KernelError> {
    let yaml = serde_yaml::to_string(frontmatter)
        .map_err(|e| KernelError::InitFailed(format!("serialize staged frontmatter: {e}")))?;
    Ok(format!("---\n{}---\n\n{}\n", yaml, body.trim()))
}

fn staged_filename(id: &str, created_at: OffsetDateTime) -> String {
    let ts = created_at
        .format(&time::macros::format_description!(
            "[year][month][day]T[hour][minute][second]Z"
        ))
        .unwrap_or_else(|_| "19700101T000000Z".into());
    let suffix = sha256_hex(id.as_bytes());
    format!("{ts}-{}.md", &suffix[..8])
}

fn normalized_markdown_body(body: &str) -> String {
    markdown_to_plain_text(body)
        .split_whitespace()
        .collect::<Vec<_>>()
        .join(" ")
        .to_ascii_lowercase()
}

fn durable_fingerprint_exists(
    paths: &AllbertPaths,
    fingerprint: &str,
) -> Result<bool, KernelError> {
    let manifest = load_manifest(paths)?;
    for entry in manifest.documents {
        let full_path = paths.memory.join(entry.path);
        if !full_path.exists() {
            continue;
        }
        let raw = fs::read_to_string(&full_path)
            .map_err(|e| KernelError::InitFailed(format!("read {}: {e}", full_path.display())))?;
        let candidate = format!(
            "sha256:{}",
            sha256_hex(normalized_markdown_body(&raw).as_bytes())
        );
        if candidate == fingerprint {
            return Ok(true);
        }
    }
    Ok(false)
}

fn find_staged_entry_by_id(dir: &Path, id: &str) -> Result<Option<PathBuf>, KernelError> {
    for path in list_staging_entries(dir)? {
        let frontmatter = parse_stage_frontmatter(&path)?;
        if frontmatter.id.as_deref() == Some(id) {
            return Ok(Some(path));
        }
    }
    Ok(None)
}

fn sanitize_promote_relative_path(input: &str) -> Result<String, KernelError> {
    let path = Path::new(input);
    if path.is_absolute() {
        return Err(KernelError::InitFailed(
            "promotion path must be relative to ~/.allbert/memory".into(),
        ));
    }
    if path.components().any(|component| {
        matches!(
            component,
            std::path::Component::ParentDir
                | std::path::Component::RootDir
                | std::path::Component::Prefix(_)
        )
    }) {
        return Err(KernelError::InitFailed(
            "promotion path escapes memory root".into(),
        ));
    }
    let normalized = path.to_string_lossy().replace('\\', "/");
    if normalized == "MEMORY.md" {
        return Err(KernelError::InitFailed(
            "cannot promote directly into MEMORY.md".into(),
        ));
    }
    Ok(if normalized.starts_with("notes/") {
        normalized
    } else {
        format!("notes/{normalized}")
    })
}

fn default_promote_relative_path(record: &StagedMemoryRecord) -> String {
    let slug = slugify(&record.summary);
    format!("notes/staged/{slug}.md")
}

fn slugify(input: &str) -> String {
    let mut out = String::new();
    let mut last_dash = false;
    for ch in input.chars().flat_map(|ch| ch.to_lowercase()) {
        if ch.is_ascii_alphanumeric() {
            out.push(ch);
            last_dash = false;
        } else if !last_dash {
            out.push('-');
            last_dash = true;
        }
    }
    let slug = out.trim_matches('-');
    if slug.is_empty() {
        "memory-entry".into()
    } else {
        slug.into()
    }
}

fn yaml_escape_scalar(input: &str) -> String {
    input.replace(':', "\\:").replace('\n', " ")
}

fn truncate_to_bytes(input: &str, max_bytes: usize) -> String {
    if input.as_bytes().len() <= max_bytes {
        return input.to_string();
    }
    let mut end = 0usize;
    for (idx, ch) in input.char_indices() {
        let next = idx + ch.len_utf8();
        if next > max_bytes {
            break;
        }
        end = next;
    }
    input[..end].to_string()
}

fn split_csv_tags(csv: String) -> Vec<String> {
    csv.split(',')
        .map(str::trim)
        .filter(|value| !value.is_empty())
        .map(ToOwned::to_owned)
        .collect()
}

fn excerpt_for_relative_path(
    paths: &AllbertPaths,
    relative: &str,
    query: &str,
    max_chars: usize,
) -> String {
    let full = paths.memory.join(relative);
    let raw = fs::read_to_string(&full).unwrap_or_default();
    let plain = markdown_to_plain_text(&raw);
    make_excerpt(&plain, query, max_chars)
}

fn make_excerpt(text: &str, query: &str, max_chars: usize) -> String {
    let trimmed = text.trim();
    if trimmed.is_empty() {
        return String::new();
    }
    let lower_text = trimmed.to_ascii_lowercase();
    let lower_query = query.to_ascii_lowercase();
    if let Some(pos) = lower_text.find(&lower_query) {
        let start = pos.saturating_sub(max_chars / 3);
        let end = (start + max_chars).min(trimmed.len());
        let snippet = trimmed[start..end].trim();
        let prefix = if start > 0 { "..." } else { "" };
        let suffix = if end < trimmed.len() { "..." } else { "" };
        format!("{prefix}{snippet}{suffix}")
    } else {
        truncate_to_bytes(trimmed, max_chars)
    }
}

fn doc_text(doc: &TantivyDocument, field: tantivy::schema::Field) -> Option<String> {
    doc.get_first(field)
        .and_then(|value| value.as_str())
        .map(ToOwned::to_owned)
}

fn build_schema() -> Schema {
    let mut builder = Schema::builder();
    builder.add_text_field("id", STRING | STORED);
    builder.add_text_field("path", STRING | STORED);
    builder.add_text_field("title", TEXT | STORED);
    builder.add_text_field("body", TEXT);
    builder.add_text_field("tags", STRING | STORED);
    builder.add_text_field("tier", STRING | STORED);
    builder.add_date_field("date", INDEXED | STORED);
    builder.build()
}

fn markdown_to_plain_text(markdown: &str) -> String {
    let mut out = String::new();
    for event in Parser::new(markdown) {
        match event {
            Event::Text(text) | Event::Code(text) | Event::Html(text) => {
                out.push_str(&text);
                out.push(' ');
            }
            Event::SoftBreak | Event::HardBreak => out.push('\n'),
            Event::Start(Tag::Paragraph) | Event::End(TagEnd::Paragraph) => out.push('\n'),
            _ => {}
        }
    }
    out
}

fn derive_title(raw: &str, path: &Path) -> String {
    for line in raw.lines() {
        let trimmed = line.trim();
        if trimmed.is_empty() {
            continue;
        }
        if let Some(rest) = trimmed.strip_prefix('#') {
            return rest.trim().to_string();
        }
    }
    path.file_stem()
        .and_then(|v| v.to_str())
        .unwrap_or("untitled")
        .to_string()
}

fn sha256_hex(bytes: &[u8]) -> String {
    let mut hasher = Sha256::new();
    hasher.update(bytes);
    format!("{:x}", hasher.finalize())
}

fn manifest_hash(manifest: &MemoryManifest) -> Result<String, KernelError> {
    let rendered = serde_json::to_vec(manifest)
        .map_err(|e| KernelError::InitFailed(format!("serialize manifest hash: {e}")))?;
    Ok(sha256_hex(&rendered))
}

fn file_timestamp_secs(path: &Path) -> i64 {
    fs::metadata(path)
        .ok()
        .and_then(|m| m.modified().ok())
        .and_then(system_time_to_unix_secs)
        .unwrap_or_else(|| OffsetDateTime::now_utc().unix_timestamp())
}

fn system_time_to_unix_secs(value: SystemTime) -> Option<i64> {
    value
        .duration_since(SystemTime::UNIX_EPOCH)
        .ok()
        .map(|d| d.as_secs() as i64)
}

fn atomic_write(path: &Path, bytes: &[u8]) -> Result<(), KernelError> {
    let parent = path
        .parent()
        .ok_or_else(|| KernelError::InitFailed(format!("{} has no parent", path.display())))?;
    let mut tmp = tempfile::NamedTempFile::new_in(parent).map_err(|e| {
        KernelError::InitFailed(format!("create temp file in {}: {e}", parent.display()))
    })?;
    tmp.write_all(bytes).map_err(|e| {
        KernelError::InitFailed(format!("write temp file for {}: {e}", path.display()))
    })?;
    tmp.as_file().sync_all().map_err(|e| {
        KernelError::InitFailed(format!("sync temp file for {}: {e}", path.display()))
    })?;
    tmp.persist(path)
        .map_err(|e| KernelError::InitFailed(format!("persist {}: {}", path.display(), e.error)))?;
    Ok(())
}

fn relative_to_memory(paths: &AllbertPaths, path: &Path) -> Result<String, KernelError> {
    relative_to_memory_path(path, &paths.memory)
}

fn relative_to_memory_path(path: &Path, root: &Path) -> Result<String, KernelError> {
    path.strip_prefix(root)
        .map_err(|e| {
            KernelError::InitFailed(format!(
                "strip {} from {}: {e}",
                root.display(),
                path.display()
            ))
        })
        .map(|p| p.to_string_lossy().replace('\\', "/"))
}

fn now_rfc3339() -> Result<String, KernelError> {
    OffsetDateTime::now_utc()
        .format(&Rfc3339)
        .map_err(|e| KernelError::InitFailed(format!("format timestamp: {e}")))
}

fn is_effectively_empty_dir(dir: &Path) -> Result<bool, KernelError> {
    if !dir.exists() {
        return Ok(true);
    }
    for entry in fs::read_dir(dir)
        .map_err(|e| KernelError::InitFailed(format!("read {}: {e}", dir.display())))?
    {
        let entry = entry.map_err(|e| KernelError::InitFailed(e.to_string()))?;
        let path = entry.path();
        let name = entry.file_name();
        if name.to_string_lossy().starts_with('.') {
            continue;
        }
        if path.is_dir() && is_effectively_empty_dir(&path)? {
            continue;
        }
        return Ok(false);
    }
    Ok(true)
}

fn copy_markdown_tree(source: &Path, dest: &Path) -> Result<usize, KernelError> {
    let mut copied = 0usize;
    for entry in fs::read_dir(source)
        .map_err(|e| KernelError::InitFailed(format!("read {}: {e}", source.display())))?
    {
        let entry = entry.map_err(|e| KernelError::InitFailed(e.to_string()))?;
        let path = entry.path();
        let name = entry.file_name();
        if name.to_string_lossy().starts_with('.') {
            continue;
        }
        let dest_path = dest.join(&name);
        if path.is_dir() {
            fs::create_dir_all(&dest_path).map_err(|e| {
                KernelError::InitFailed(format!("create {}: {e}", dest_path.display()))
            })?;
            copied += copy_markdown_tree(&path, &dest_path)?;
        } else {
            fs::copy(&path, &dest_path).map_err(|e| {
                KernelError::InitFailed(format!(
                    "copy {} -> {}: {e}",
                    path.display(),
                    dest_path.display()
                ))
            })?;
            copied += 1;
        }
    }
    Ok(copied)
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::paths::AllbertPaths;
    use std::sync::atomic::{AtomicUsize, Ordering};

    static TEMP_COUNTER: AtomicUsize = AtomicUsize::new(0);

    struct TempRoot {
        path: PathBuf,
    }

    impl TempRoot {
        fn new() -> Self {
            let counter = TEMP_COUNTER.fetch_add(1, Ordering::Relaxed);
            let unique = format!(
                "allbert-memory-test-{}-{}-{}",
                std::process::id(),
                counter,
                SystemTime::now()
                    .duration_since(SystemTime::UNIX_EPOCH)
                    .expect("time")
                    .as_nanos()
            );
            let path = std::env::temp_dir().join(unique);
            fs::create_dir_all(&path).expect("temp root");
            Self { path }
        }

        fn paths(&self) -> AllbertPaths {
            AllbertPaths::under(self.path.clone())
        }
    }

    impl Drop for TempRoot {
        fn drop(&mut self) {
            let _ = fs::remove_dir_all(&self.path);
        }
    }

    #[test]
    fn bootstrap_seeds_curated_memory_layout_and_index() {
        let temp = TempRoot::new();
        let paths = temp.paths();
        paths.ensure().unwrap();
        let report = bootstrap_curated_memory(&paths, &MemoryConfig::default()).unwrap();
        assert!(paths.memory_notes.exists());
        assert!(paths.memory_staging.exists());
        assert!(paths.memory_index_dir.exists());
        assert!(paths.memory_manifest.exists());
        assert!(paths.memory_index_meta.exists());
        assert!(report.rebuild_report.is_some());
    }

    #[test]
    fn legacy_v0_4_buckets_import_into_notes_tree() {
        let temp = TempRoot::new();
        let paths = temp.paths();
        paths.ensure().unwrap();
        fs::create_dir_all(&paths.memory_projects).unwrap();
        fs::write(
            paths.memory_projects.join("postgres.md"),
            "# Postgres\n\nWe use Postgres.\n",
        )
        .unwrap();

        let report = bootstrap_curated_memory(&paths, &MemoryConfig::default()).unwrap();
        assert_eq!(report.imported_legacy_files, 1);
        assert!(paths.memory_notes.join("projects/postgres.md").exists());
        assert!(paths
            .memory_legacy_v04
            .join("projects/postgres.md")
            .exists());
        let manifest = load_manifest(&paths).unwrap();
        assert!(manifest
            .documents
            .iter()
            .any(|doc| doc.path == "notes/projects/postgres.md"));
    }

    #[test]
    fn expired_staged_entries_move_to_expired() {
        let temp = TempRoot::new();
        let paths = temp.paths();
        paths.ensure().unwrap();
        let staged = paths.memory_staging.join("20260420T000000Z-deadbeef.md");
        fs::write(
            &staged,
            "---\nkind: learned_fact\nexpires_at: 2000-01-01T00:00:00Z\n---\n# Fact\n\nOld.\n",
        )
        .unwrap();
        let report = bootstrap_curated_memory(&paths, &MemoryConfig::default()).unwrap();
        assert_eq!(report.expired_staged_entries, 1);
        assert!(!staged.exists());
        assert!(paths
            .memory_staging_expired
            .join("20260420T000000Z-deadbeef.md")
            .exists());
    }

    #[test]
    fn search_memory_prefers_exact_matches_and_respects_tier_filter() {
        let temp = TempRoot::new();
        let paths = temp.paths();
        paths.ensure().unwrap();
        fs::create_dir_all(paths.memory_notes.join("projects")).unwrap();
        fs::write(
            paths.memory_notes.join("projects/postgres.md"),
            "# Postgres\n\nWe use Postgres for the main app database.\n",
        )
        .unwrap();
        fs::write(
            paths.memory_notes.join("projects/sqlite.md"),
            "# SQLite\n\nSQLite is only for local scratch work.\n",
        )
        .unwrap();
        bootstrap_curated_memory(&paths, &MemoryConfig::default()).unwrap();
        let staged = stage_memory(
            &paths,
            &MemoryConfig::default(),
            StageMemoryRequest {
                session_id: "sess-1".into(),
                turn_id: "turn-1".into(),
                agent: "allbert/root".into(),
                source: "channel".into(),
                content: "Remember that Postgres maintenance happens on Sundays.".into(),
                kind: StagedMemoryKind::LearnedFact,
                summary: "Postgres maintenance".into(),
                tags: vec!["postgres".into()],
                provenance: None,
            },
        )
        .unwrap();

        let durable = search_memory(
            &paths,
            &MemoryConfig::default(),
            SearchMemoryInput {
                query: "Postgres".into(),
                tier: MemoryTier::Durable,
                limit: Some(5),
            },
        )
        .unwrap();
        assert!(!durable.is_empty());
        assert_eq!(durable[0].path, "notes/projects/postgres.md");
        assert!(durable.iter().all(|hit| hit.tier == "durable"));

        let staging = search_memory(
            &paths,
            &MemoryConfig::default(),
            SearchMemoryInput {
                query: "maintenance".into(),
                tier: MemoryTier::Staging,
                limit: Some(5),
            },
        )
        .unwrap();
        assert_eq!(staging.len(), 1);
        assert_eq!(staging[0].path, staged.path);
        assert_eq!(staging[0].tier, "staging");
    }

    #[test]
    fn stage_promote_then_search_finds_durable_note() {
        let temp = TempRoot::new();
        let paths = temp.paths();
        paths.ensure().unwrap();
        bootstrap_curated_memory(&paths, &MemoryConfig::default()).unwrap();
        let staged = stage_memory(
            &paths,
            &MemoryConfig::default(),
            StageMemoryRequest {
                session_id: "sess-2".into(),
                turn_id: "turn-7".into(),
                agent: "allbert/root".into(),
                source: "channel".into(),
                content: "We use Postgres for production data.".into(),
                kind: StagedMemoryKind::ExplicitRequest,
                summary: "Production database".into(),
                tags: vec!["postgres".into(), "database".into()],
                provenance: None,
            },
        )
        .unwrap();

        let preview = preview_promote_staged_memory(
            &paths,
            &MemoryConfig::default(),
            &staged.id,
            Some("notes/projects/production-db.md"),
            None,
        )
        .unwrap();
        let destination =
            promote_staged_memory(&paths, &MemoryConfig::default(), &preview).unwrap();
        assert_eq!(destination, "notes/projects/production-db.md");
        assert!(paths.memory.join(&destination).exists());

        let results = search_memory(
            &paths,
            &MemoryConfig::default(),
            SearchMemoryInput {
                query: "production database".into(),
                tier: MemoryTier::Durable,
                limit: Some(5),
            },
        )
        .unwrap();
        assert!(results.iter().any(|hit| hit.path == destination));
    }

    #[test]
    fn reject_staged_memory_removes_it_from_staging_search() {
        let temp = TempRoot::new();
        let paths = temp.paths();
        paths.ensure().unwrap();
        bootstrap_curated_memory(&paths, &MemoryConfig::default()).unwrap();
        let staged = stage_memory(
            &paths,
            &MemoryConfig::default(),
            StageMemoryRequest {
                session_id: "sess-3".into(),
                turn_id: "turn-3".into(),
                agent: "allbert/root".into(),
                source: "channel".into(),
                content: "Temporary false note.".into(),
                kind: StagedMemoryKind::LearnedFact,
                summary: "Temporary false note".into(),
                tags: vec![],
                provenance: None,
            },
        )
        .unwrap();
        let rejected_path = reject_staged_memory(
            &paths,
            &MemoryConfig::default(),
            &staged.id,
            Some("not actually durable"),
        )
        .unwrap();
        assert!(paths.memory.join(&rejected_path).exists());
        let results = search_memory(
            &paths,
            &MemoryConfig::default(),
            SearchMemoryInput {
                query: "Temporary false note".into(),
                tier: MemoryTier::Staging,
                limit: Some(5),
            },
        )
        .unwrap();
        assert!(results.is_empty());
    }

    #[test]
    fn duplicate_stage_memory_is_rejected_by_fingerprint() {
        let temp = TempRoot::new();
        let paths = temp.paths();
        paths.ensure().unwrap();
        bootstrap_curated_memory(&paths, &MemoryConfig::default()).unwrap();
        let request = StageMemoryRequest {
            session_id: "sess-4".into(),
            turn_id: "turn-1".into(),
            agent: "allbert/root".into(),
            source: "channel".into(),
            content: "Remember that we use Postgres.\n".into(),
            kind: StagedMemoryKind::ExplicitRequest,
            summary: "Uses Postgres".into(),
            tags: vec!["postgres".into()],
            provenance: None,
        };
        stage_memory(&paths, &MemoryConfig::default(), request.clone()).unwrap();
        let err = stage_memory(&paths, &MemoryConfig::default(), request).unwrap_err();
        assert!(err.to_string().contains("duplicate"));
    }
}
