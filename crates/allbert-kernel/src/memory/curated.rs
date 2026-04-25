// v0.5 picks tantivy so the retriever index stays durable, filterable, and cheap to reopen
// without turning Allbert into a search-engine project. If this dependency becomes too heavy
// or the runtime targets change, revisit ADR 0046 before replacing this module.

use std::collections::{BTreeMap, BTreeSet};
use std::fs::{self, File};
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
const INDEX_SCHEMA_VERSION: u32 = 2;
const SEMANTIC_SCHEMA_VERSION: u32 = 1;
const FAKE_EMBEDDING_DIM: usize = 32;
const TANTIVY_VERSION: &str = "0.22";
const STAGED_BODY_MAX_BYTES: usize = 16 * 1024;

#[derive(Debug, Clone, Copy, Serialize, Deserialize, PartialEq, Eq)]
#[serde(rename_all = "snake_case")]
#[derive(Default)]
pub enum MemoryTier {
    #[default]
    Durable,
    Staging,
    Episode,
    Fact,
    All,
}

#[derive(Debug, Clone, Copy, Serialize, Deserialize, PartialEq, Eq)]
#[serde(rename_all = "snake_case")]
pub enum StagedMemoryKind {
    ExplicitRequest,
    LearnedFact,
    JobSummary,
    SubagentResult,
    CuratorExtraction,
    Research,
}

impl StagedMemoryKind {
    pub(crate) fn as_str(self) -> &'static str {
        match self {
            Self::ExplicitRequest => "explicit_request",
            Self::LearnedFact => "learned_fact",
            Self::JobSummary => "job_summary",
            Self::SubagentResult => "subagent_result",
            Self::CuratorExtraction => "curator_extraction",
            Self::Research => "research",
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
    #[serde(default)]
    pub include_superseded: bool,
}

#[derive(Debug, Clone, Serialize)]
pub struct SearchMemoryHit {
    pub path: String,
    pub title: String,
    pub tier: String,
    pub score: f32,
    pub tags: Vec<String>,
    pub snippet: String,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub source: Option<JsonValue>,
}

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq, Eq, Default)]
#[serde(default)]
pub struct MemoryFact {
    pub id: String,
    pub subject: String,
    pub predicate: String,
    pub object: String,
    pub valid_from: Option<String>,
    pub valid_until: Option<String>,
    pub supersedes: Vec<String>,
    pub source: Option<JsonValue>,
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
    #[serde(default)]
    pub fingerprint_basis: Option<String>,
    #[serde(default)]
    pub facts: Vec<MemoryFact>,
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
    pub fingerprint_basis: Option<String>,
    pub facts: Vec<MemoryFact>,
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
    pub facts: Vec<MemoryFact>,
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

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq, Eq)]
pub struct MemoryManifest {
    pub schema_version: u32,
    pub documents: Vec<MemoryManifestEntry>,
}

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq, Eq)]
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

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct MemoryReconcileMeta {
    pub last_reconcile_at: String,
    pub manifest_hash: String,
    pub manifest_docs: usize,
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
    pub episode_count: usize,
    pub fact_count: usize,
    pub staged_counts: BTreeMap<String, usize>,
    pub rejected_count: usize,
    pub expired_pending_count: usize,
    pub index_age_seconds: Option<u64>,
    pub last_rebuild_reason: Option<String>,
    pub last_rebuild_elapsed_ms: Option<u128>,
    pub schema_version: u32,
    pub manifest_health: MemoryHealth,
    pub index_health: MemoryHealth,
    pub last_reconcile_at: Option<String>,
}

#[derive(Debug, Clone)]
pub struct MemoryReconcileReport {
    pub manifest_rebuilt: bool,
    pub rebuild_report: Option<RebuildIndexReport>,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum MemoryHealth {
    Ok,
    Missing,
    Mismatch,
    Stale,
}

impl MemoryHealth {
    pub fn as_str(self) -> &'static str {
        match self {
            Self::Ok => "ok",
            Self::Missing => "missing",
            Self::Mismatch => "mismatch",
            Self::Stale => "stale",
        }
    }
}

#[derive(Debug, Clone)]
pub struct MemoryVerifyReport {
    pub manifest_health: MemoryHealth,
    pub index_health: MemoryHealth,
    pub last_reconcile_at: Option<String>,
    pub issues: Vec<String>,
}

impl MemoryVerifyReport {
    pub fn is_healthy(&self) -> bool {
        self.issues.is_empty()
    }
}

#[derive(Debug, Clone)]
pub struct TurnMemorySnapshot {
    pub sections: Vec<String>,
    pub prefetch_hits: Vec<SearchMemoryHit>,
    pub trimmed_sources: Vec<String>,
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
    #[serde(default)]
    facts: Vec<MemoryFact>,
    #[serde(flatten)]
    extra: BTreeMap<String, JsonValue>,
}

#[derive(Debug, Serialize, Deserialize)]
struct RejectedStageEnvelope {
    rejection: RejectedStageMetadata,
}

#[derive(Debug, Serialize, Deserialize)]
struct RejectedStageMetadata {
    original_id: String,
    source_session: String,
    rejected_at: String,
    reason: String,
}

#[derive(Debug, Serialize, Deserialize)]
struct TrashEnvelope {
    trash: TrashMetadata,
}

#[derive(Debug, Serialize, Deserialize)]
struct TrashMetadata {
    original_id: String,
    original_path: String,
    deleted_at: String,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    delete_reason: Option<String>,
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
        facts: Vec::new(),
        extra: BTreeMap::new(),
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
    let _ = gc_memory_recovery(paths, config)?;
    let manifest = load_manifest(paths)?;
    let rebuild_report = maybe_rebuild_index(paths, config, &manifest, false, None)?;

    Ok(MemoryBootstrapReport {
        imported_legacy_files,
        expired_staged_entries,
        manifest_rebuilt,
        rebuild_report,
    })
}

pub fn rebuild_memory_index(
    paths: &AllbertPaths,
    config: &MemoryConfig,
    force: bool,
) -> Result<RebuildIndexReport, KernelError> {
    ensure_curated_dirs(paths)?;
    if !paths.memory_manifest.exists() {
        write_manifest(paths, &scan_manifest(paths)?)?;
    }
    let manifest = load_manifest(paths)?;
    maybe_rebuild_index(paths, config, &manifest, force, Some("operator-request"))?
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
    let verify = verify_curated_memory(paths, config)?;
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
        episode_count: collect_episode_docs(paths, config)?.len(),
        fact_count: durable_fact_count(paths, config, &manifest)?,
        staged_counts,
        rejected_count,
        expired_pending_count,
        index_age_seconds,
        last_rebuild_reason: meta.as_ref().map(|value| value.last_rebuild_reason.clone()),
        last_rebuild_elapsed_ms: meta.as_ref().map(|value| value.elapsed_ms),
        schema_version: INDEX_SCHEMA_VERSION,
        manifest_health: verify.manifest_health,
        index_health: verify.index_health,
        last_reconcile_at: verify.last_reconcile_at,
    })
}

pub fn verify_curated_memory(
    paths: &AllbertPaths,
    config: &MemoryConfig,
) -> Result<MemoryVerifyReport, KernelError> {
    ensure_curated_dirs(paths)?;
    let scanned = scan_manifest(paths)?;
    let manifest = load_manifest(paths).ok();
    let index_meta = load_index_meta(paths).ok();
    let reconcile_meta = load_reconcile_meta(paths).ok();

    let manifest_health = match manifest.as_ref() {
        None => MemoryHealth::Missing,
        Some(existing) if *existing == scanned => MemoryHealth::Ok,
        Some(_) => MemoryHealth::Mismatch,
    };

    let manifest_hash = manifest_hash(&scanned)?;
    let index_hash = index_source_hash(paths, config, &scanned)?;
    let expected_doc_count = expected_index_doc_count(paths, config, &scanned)?;
    let tantivy_dir = paths.memory_index_dir.join("tantivy");
    let index_health = match index_meta.as_ref() {
        None => MemoryHealth::Missing,
        Some(_) if !tantivy_dir.exists() || is_effectively_empty_dir(&tantivy_dir)? => {
            MemoryHealth::Missing
        }
        Some(_meta) if manifest_health != MemoryHealth::Ok => MemoryHealth::Stale,
        Some(meta)
            if meta.schema_version != INDEX_SCHEMA_VERSION
                || meta.manifest_hash != index_hash
                || meta.doc_count != expected_doc_count =>
        {
            MemoryHealth::Mismatch
        }
        Some(_) => MemoryHealth::Ok,
    };

    let mut issues = Vec::new();
    match manifest.as_ref() {
        None => issues.push(format!(
            "manifest missing at {}",
            paths.memory_manifest.display()
        )),
        Some(_) if manifest_health == MemoryHealth::Mismatch => {
            issues.push("manifest does not match current markdown notes/daily files".into())
        }
        _ => {}
    }
    match index_meta.as_ref() {
        None => issues.push(format!(
            "index metadata missing at {}",
            paths.memory_index_meta.display()
        )),
        Some(_) if !tantivy_dir.exists() || is_effectively_empty_dir(&tantivy_dir)? => {
            issues.push(format!(
                "tantivy index missing or empty at {}",
                tantivy_dir.display()
            ))
        }
        Some(meta) if meta.schema_version != INDEX_SCHEMA_VERSION => issues.push(format!(
            "index schema version {} does not match expected {}",
            meta.schema_version, INDEX_SCHEMA_VERSION
        )),
        Some(meta) if meta.manifest_hash != index_hash => issues.push(format!(
            "index source hash {} does not match current memory source hash {}",
            meta.manifest_hash, index_hash
        )),
        Some(meta) if meta.doc_count != expected_doc_count => issues.push(format!(
            "index doc count {} does not match current indexable source count {}",
            meta.doc_count, expected_doc_count
        )),
        _ => {}
    }

    if let Some(meta) = reconcile_meta.as_ref() {
        if meta.manifest_hash != manifest_hash || meta.manifest_docs != scanned.documents.len() {
            issues.push("last reconcile metadata is stale for current manifest".into());
        }
    }

    Ok(MemoryVerifyReport {
        manifest_health,
        index_health,
        last_reconcile_at: reconcile_meta.map(|value| value.last_reconcile_at),
        issues,
    })
}

pub fn reconcile_curated_memory(
    paths: &AllbertPaths,
    config: &MemoryConfig,
) -> Result<MemoryReconcileReport, KernelError> {
    ensure_curated_dirs(paths)?;
    let _ = expire_staged_entries(paths, config)?;

    let scanned = scan_manifest(paths)?;
    let manifest_rebuilt = match load_manifest(paths) {
        Ok(existing) if existing == scanned => false,
        _ => {
            write_manifest(paths, &scanned)?;
            true
        }
    };
    let rebuild_report = maybe_rebuild_index(paths, config, &scanned, false, None)?;
    write_reconcile_meta(
        paths,
        &MemoryReconcileMeta {
            last_reconcile_at: now_rfc3339()?,
            manifest_hash: manifest_hash(&scanned)?,
            manifest_docs: scanned.documents.len(),
        },
    )?;
    Ok(MemoryReconcileReport {
        manifest_rebuilt,
        rebuild_report,
    })
}

pub fn build_turn_memory_snapshot(
    paths: &AllbertPaths,
    config: &MemoryConfig,
    ephemeral_summary: &str,
    prefetch_query: Option<&str>,
    prefetch_limit: usize,
) -> Result<TurnMemorySnapshot, KernelError> {
    let _ = reconcile_curated_memory(paths, config)?;

    let mut memory_head = read_memory_head(paths, config.max_memory_md_head_bytes)?;
    let mut daily_head = read_daily_head(paths, config.max_daily_head_bytes)?;
    let mut yesterday_tail = if config.default_daily_recency_days >= 2 {
        read_yesterday_tail(paths, config.max_daily_tail_bytes)?
    } else {
        None
    };
    let ephemeral_summary =
        truncate_to_bytes(ephemeral_summary.trim(), config.max_ephemeral_summary_bytes);
    let mut prefetch_hits =
        if let Some(query) = prefetch_query.map(str::trim).filter(|q| !q.is_empty()) {
            search_memory(
                paths,
                config,
                SearchMemoryInput {
                    query: query.to_string(),
                    tier: MemoryTier::Durable,
                    limit: Some(prefetch_limit.min(config.max_prefetch_snippets)),
                    include_superseded: false,
                },
            )?
        } else {
            Vec::new()
        };
    for hit in &mut prefetch_hits {
        hit.snippet = truncate_to_bytes(hit.snippet.trim(), config.max_prefetch_snippet_bytes);
    }

    let mut trimmed_sources = Vec::new();
    let mut render = render_turn_memory_sections(
        &memory_head,
        &daily_head,
        yesterday_tail.as_deref(),
        &ephemeral_summary,
        &prefetch_hits,
    );

    while rendered_sections_bytes(&render) > config.max_synopsis_bytes {
        if yesterday_tail.take().is_some() {
            trimmed_sources.push("yesterday_tail".into());
        } else if !prefetch_hits.is_empty() {
            let dropped = prefetch_hits.pop().expect("checked non-empty");
            trimmed_sources.push(format!("prefetch:{}", dropped.path));
        } else if !daily_head.is_empty() {
            let over = rendered_sections_bytes(&render) - config.max_synopsis_bytes;
            let new_len = daily_head.len().saturating_sub(over.max(256));
            if new_len == 0 || new_len >= daily_head.len() {
                daily_head.clear();
            } else {
                daily_head = truncate_to_bytes(&daily_head, new_len);
            }
            trimmed_sources.push("daily_head".into());
        } else if !memory_head.is_empty() {
            let over = rendered_sections_bytes(&render) - config.max_synopsis_bytes;
            let new_len = memory_head.len().saturating_sub(over.max(256));
            if new_len == 0 || new_len >= memory_head.len() {
                memory_head.clear();
            } else {
                memory_head = truncate_to_bytes(&memory_head, new_len);
            }
            trimmed_sources.push("memory_head".into());
        } else {
            break;
        }
        render = render_turn_memory_sections(
            &memory_head,
            &daily_head,
            yesterday_tail.as_deref(),
            &ephemeral_summary,
            &prefetch_hits,
        );
    }

    Ok(TurnMemorySnapshot {
        sections: render,
        prefetch_hits,
        trimmed_sources,
    })
}

pub fn search_memory(
    paths: &AllbertPaths,
    config: &MemoryConfig,
    input: SearchMemoryInput,
) -> Result<Vec<SearchMemoryHit>, KernelError> {
    let _ = reconcile_curated_memory(paths, config)?;
    let manifest = load_manifest(paths)?;
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
    let source_f = schema.get_field("source").expect("source field");
    let superseded_f = schema.get_field("superseded").expect("superseded field");
    let fact_subject_f = schema
        .get_field("fact_subject")
        .expect("fact_subject field");
    let fact_object_f = schema.get_field("fact_object").expect("fact_object field");
    let parser = QueryParser::for_index(
        &index,
        vec![title_f, body_f, tags_f, fact_subject_f, fact_object_f],
    );
    let parsed_query = parser
        .parse_query(raw_query)
        .or_else(|_| {
            let sanitized = sanitize_query(raw_query);
            parser.parse_query(&sanitized)
        })
        .map_err(|e| KernelError::InitFailed(format!("parse query '{raw_query}': {e}")))?;
    let mut clauses: Vec<(Occur, Box<dyn Query>)> = vec![(Occur::Must, Box::new(parsed_query))];
    match input.tier {
        MemoryTier::All => {}
        MemoryTier::Durable | MemoryTier::Staging | MemoryTier::Episode | MemoryTier::Fact => {
            let wanted = match input.tier {
                MemoryTier::Durable => "durable",
                MemoryTier::Staging => "staging",
                MemoryTier::Episode => "episode",
                MemoryTier::Fact => "fact",
                MemoryTier::All => unreachable!("handled above"),
            };
            let tier_query = TermQuery::new(
                Term::from_field_text(tier_f, wanted),
                IndexRecordOption::Basic,
            );
            clauses.push((Occur::Must, Box::new(tier_query)));
        }
    };
    if input.tier == MemoryTier::Fact && !input.include_superseded {
        let current_fact_query = TermQuery::new(
            Term::from_field_text(superseded_f, "false"),
            IndexRecordOption::Basic,
        );
        clauses.push((Occur::Must, Box::new(current_fact_query)));
    }
    let compiled_query: Box<dyn Query> = if clauses.len() == 1 {
        clauses.pop().expect("query clause").1
    } else {
        Box::new(BooleanQuery::new(clauses))
    };

    let reader = index
        .reader()
        .map_err(|e| KernelError::InitFailed(format!("open tantivy reader: {e}")))?;
    let searcher = reader.searcher();
    let top_docs = searcher
        .search(
            &compiled_query,
            &TopDocs::with_limit(if config.semantic.enabled {
                limit.saturating_mul(4).max(limit)
            } else {
                limit
            }),
        )
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
        let body = doc_text(&doc, body_f).unwrap_or_default();
        let snippet = make_excerpt(&body, raw_query, 220);
        let source = doc_text(&doc, source_f)
            .and_then(|value| serde_json::from_str::<JsonValue>(&value).ok());
        hits.push(SearchMemoryHit {
            path,
            title,
            tier,
            score,
            tags,
            snippet,
            source,
        });
    }

    hits.sort_by(|a, b| {
        b.score
            .partial_cmp(&a.score)
            .unwrap_or(std::cmp::Ordering::Equal)
            .then_with(|| a.path.cmp(&b.path))
    });
    if config.semantic.enabled {
        return apply_semantic_fusion(paths, config, &manifest, &input, raw_query, hits, limit);
    }
    hits.truncate(limit);
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
    let facts = normalize_facts(request.facts, config.facts.max_facts_per_entry)?;

    let normalized_body = normalized_markdown_body(&request.content);
    let fingerprint_basis = request
        .fingerprint_basis
        .as_deref()
        .map(normalized_markdown_body)
        .unwrap_or_else(|| normalized_body.clone());
    let fingerprint = format!("sha256:{}", sha256_hex(fingerprint_basis.as_bytes()));
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
    if body.len() > STAGED_BODY_MAX_BYTES {
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
        facts,
        extra: BTreeMap::new(),
    };
    let rendered = render_staged_entry(&frontmatter, &body)?;
    let filename = staged_filename(&id, created_at);
    let path = paths.memory_staging.join(&filename);
    atomic_write(&path, rendered.as_bytes())?;
    let manifest = load_manifest(paths)?;
    let _ = maybe_rebuild_index(paths, config, &manifest, true, Some("stage-memory"))?;

    parse_staged_record(paths, &path)
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
    let frontmatter = parse_stage_frontmatter(&staged_path)?;
    let durable_body = render_promoted_durable_note(preview, &record, &frontmatter)?;
    atomic_write(&destination, durable_body.as_bytes())?;
    fs::remove_file(&staged_path)
        .map_err(|e| KernelError::InitFailed(format!("remove {}: {e}", staged_path.display())))?;
    let manifest = scan_manifest(paths)?;
    write_manifest(paths, &manifest)?;
    let _ = maybe_rebuild_index(
        paths,
        config,
        &manifest,
        true,
        Some("promote-staged-memory"),
    )?;
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
    let frontmatter = parse_stage_frontmatter(&staged_path)?;
    let source_session = frontmatter
        .session_id
        .clone()
        .unwrap_or_else(|| "unknown".into());
    let rejected_name = format!(
        "{}/{}-{}.md",
        source_session,
        OffsetDateTime::now_utc()
            .format(&time::macros::format_description!(
                "[year][month][day]T[hour][minute][second]Z"
            ))
            .map_err(|e| KernelError::InitFailed(format!("format rejection time: {e}")))?,
        id
    );
    let dest = paths.memory_staging_rejected.join(&rejected_name);
    if let Some(parent) = dest.parent() {
        fs::create_dir_all(parent)
            .map_err(|e| KernelError::InitFailed(format!("create {}: {e}", parent.display())))?;
    }
    let rejection = RejectedStageEnvelope {
        rejection: RejectedStageMetadata {
            original_id: id.to_string(),
            source_session,
            rejected_at: now_rfc3339()?,
            reason: reason.unwrap_or("rejected by operator").to_string(),
        },
    };
    let rejection_yaml = serde_yaml::to_string(&rejection)
        .map_err(|e| KernelError::InitFailed(format!("serialize rejection metadata: {e}")))?;
    let wrapped = format!("---\n{}---\n\n{}", rejection_yaml, raw.trim_end());
    atomic_write(&dest, wrapped.as_bytes())?;
    fs::remove_file(&staged_path)
        .map_err(|e| KernelError::InitFailed(format!("remove {}: {e}", staged_path.display())))?;
    let manifest = load_manifest(paths)?;
    let _ = maybe_rebuild_index(paths, config, &manifest, true, Some("reject-staged-memory"))?;
    relative_to_memory(paths, &dest)
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
                include_superseded: false,
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
        let raw = fs::read_to_string(&source)
            .map_err(|e| KernelError::InitFailed(format!("read {}: {e}", source.display())))?;
        let trash_name = format!(
            "{}-{}.md",
            OffsetDateTime::now_utc()
                .format(&time::macros::format_description!(
                    "[year][month][day]T[hour][minute][second]Z"
                ))
                .map_err(|e| KernelError::InitFailed(format!("format trash timestamp: {e}")))?,
            memory_id_from_path(&target.path)
        );
        let dest = paths.memory_trash.join(trash_name);
        let trash = TrashEnvelope {
            trash: TrashMetadata {
                original_id: memory_id_from_path(&target.path),
                original_path: target.path.clone(),
                deleted_at: now_rfc3339()?,
                delete_reason: Some(format!("forget query: {}", preview.query)),
            },
        };
        let trash_yaml = serde_yaml::to_string(&trash)
            .map_err(|e| KernelError::InitFailed(format!("serialize trash metadata: {e}")))?;
        let wrapped = format!("---\n{}---\n\n{}", trash_yaml, raw.trim_end());
        atomic_write(&dest, wrapped.as_bytes())?;
        fs::remove_file(&source).map_err(|e| {
            KernelError::InitFailed(format!("remove forgotten memory {}: {e}", source.display()))
        })?;
        forgotten.push(target.path.clone());
    }
    let manifest = scan_manifest(paths)?;
    write_manifest(paths, &manifest)?;
    let _ = maybe_rebuild_index(paths, config, &manifest, true, Some("forget-memory"))?;
    Ok(forgotten)
}

pub fn restore_memory(
    paths: &AllbertPaths,
    config: &MemoryConfig,
    id: &str,
) -> Result<String, KernelError> {
    let _ = bootstrap_curated_memory(paths, config)?;
    let (trash_path, metadata, body) = find_trash_entry(paths, id)?
        .ok_or_else(|| KernelError::InitFailed(format!("trashed memory entry not found: {id}")))?;
    let destination = paths.memory.join(&metadata.original_path);
    if destination.exists() {
        return Err(KernelError::InitFailed(format!(
            "cannot restore {}; live memory already exists at {}",
            metadata.original_id, metadata.original_path
        )));
    }
    if let Some(parent) = destination.parent() {
        fs::create_dir_all(parent)
            .map_err(|e| KernelError::InitFailed(format!("create {}: {e}", parent.display())))?;
    }
    atomic_write(&destination, body.trim_start().as_bytes())?;
    fs::remove_file(&trash_path).map_err(|e| {
        KernelError::InitFailed(format!(
            "remove restored trash {}: {e}",
            trash_path.display()
        ))
    })?;
    let manifest = scan_manifest(paths)?;
    write_manifest(paths, &manifest)?;
    let _ = maybe_rebuild_index(paths, config, &manifest, true, Some("restore-memory"))?;
    Ok(metadata.original_path)
}

pub fn reconsider_staged_memory(
    paths: &AllbertPaths,
    config: &MemoryConfig,
    id: &str,
) -> Result<String, KernelError> {
    let _ = bootstrap_curated_memory(paths, config)?;
    if find_staged_entry_by_id(&paths.memory_staging, id)?.is_some() {
        return Err(KernelError::InitFailed(format!(
            "cannot reconsider {id}; an active staged entry with that id already exists"
        )));
    }
    let (rejected_path, metadata, body) = find_rejected_entry(paths, id)?.ok_or_else(|| {
        KernelError::InitFailed(format!("rejected staged memory entry not found: {id}"))
    })?;
    let created_at = OffsetDateTime::now_utc();
    let destination = paths
        .memory_staging
        .join(staged_filename(&metadata.original_id, created_at));
    atomic_write(&destination, body.trim_start().as_bytes())?;
    fs::remove_file(&rejected_path).map_err(|e| {
        KernelError::InitFailed(format!(
            "remove reconsidered rejection {}: {e}",
            rejected_path.display()
        ))
    })?;
    let manifest = load_manifest(paths)?;
    let _ = maybe_rebuild_index(
        paths,
        config,
        &manifest,
        true,
        Some("reconsider-staged-memory"),
    )?;
    relative_to_memory(paths, &destination)
}

pub fn gc_memory_recovery(
    paths: &AllbertPaths,
    config: &MemoryConfig,
) -> Result<usize, KernelError> {
    ensure_curated_dirs(paths)?;
    let mut removed = 0usize;
    removed += gc_recovery_dir(&paths.memory_trash, config.trash_retention_days, |raw| {
        parse_trash_envelope(raw)
            .ok()
            .map(|(metadata, _)| metadata.deleted_at)
    })?;
    removed += gc_recovery_dir(
        &paths.memory_staging_rejected,
        config.rejected_retention_days,
        |raw| {
            parse_rejected_stage_envelope(raw)
                .ok()
                .map(|(metadata, _)| metadata.rejected_at)
        },
    )?;
    Ok(removed)
}

fn memory_id_from_path(path: &str) -> String {
    path.trim_end_matches(".md").replace(['/', '\\', ' '], "_")
}

fn memory_short_id_from_path(path: &str) -> String {
    path.rsplit(['/', '\\'])
        .next()
        .unwrap_or(path)
        .trim_end_matches(".md")
        .replace(['/', '\\', ' '], "_")
}

fn find_trash_entry(
    paths: &AllbertPaths,
    id: &str,
) -> Result<Option<(PathBuf, TrashMetadata, String)>, KernelError> {
    for path in list_markdown_recursive(&paths.memory_trash)? {
        let raw = fs::read_to_string(&path)
            .map_err(|e| KernelError::InitFailed(format!("read {}: {e}", path.display())))?;
        let (metadata, body) = parse_trash_envelope(&raw)?;
        if metadata.original_id == id
            || metadata.original_path == id
            || memory_short_id_from_path(&metadata.original_path) == id
        {
            return Ok(Some((path, metadata, body)));
        }
    }
    Ok(None)
}

fn find_rejected_entry(
    paths: &AllbertPaths,
    id: &str,
) -> Result<Option<(PathBuf, RejectedStageMetadata, String)>, KernelError> {
    for path in list_markdown_recursive(&paths.memory_staging_rejected)? {
        let raw = fs::read_to_string(&path)
            .map_err(|e| KernelError::InitFailed(format!("read {}: {e}", path.display())))?;
        let (metadata, body) = parse_rejected_stage_envelope(&raw)?;
        if metadata.original_id == id {
            return Ok(Some((path, metadata, body)));
        }
    }
    Ok(None)
}

fn parse_trash_envelope(raw: &str) -> Result<(TrashMetadata, String), KernelError> {
    let (frontmatter, body) = split_frontmatter_and_body(raw);
    let envelope: TrashEnvelope = serde_yaml::from_str(frontmatter)
        .map_err(|e| KernelError::InitFailed(format!("parse trash metadata: {e}")))?;
    Ok((envelope.trash, body))
}

fn parse_rejected_stage_envelope(
    raw: &str,
) -> Result<(RejectedStageMetadata, String), KernelError> {
    let (frontmatter, body) = split_frontmatter_and_body(raw);
    let envelope: RejectedStageEnvelope = serde_yaml::from_str(frontmatter)
        .map_err(|e| KernelError::InitFailed(format!("parse rejection metadata: {e}")))?;
    Ok((envelope.rejection, body))
}

fn gc_recovery_dir<F>(dir: &Path, retention_days: u16, timestamp: F) -> Result<usize, KernelError>
where
    F: Fn(&str) -> Option<String>,
{
    let cutoff = OffsetDateTime::now_utc() - time::Duration::days(i64::from(retention_days));
    let mut removed = 0usize;
    for path in list_markdown_recursive(dir)? {
        let raw = fs::read_to_string(&path)
            .map_err(|e| KernelError::InitFailed(format!("read {}: {e}", path.display())))?;
        let Some(ts) = timestamp(&raw) else {
            continue;
        };
        let Ok(then) = OffsetDateTime::parse(&ts, &Rfc3339) else {
            continue;
        };
        if then < cutoff {
            fs::remove_file(&path).map_err(|e| {
                KernelError::InitFailed(format!("remove expired recovery {}: {e}", path.display()))
            })?;
            removed += 1;
        }
    }
    Ok(removed)
}

fn list_markdown_recursive(dir: &Path) -> Result<Vec<PathBuf>, KernelError> {
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
            entries.extend(list_markdown_recursive(&path)?);
        } else if path.extension().and_then(|value| value.to_str()) == Some("md") {
            entries.push(path);
        }
    }
    entries.sort();
    Ok(entries)
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
        atomic_write(&paths.memory_index, b"# MEMORY\n\n").map_err(|e| {
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
        atomic_write(path, contents.as_bytes())
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
        atomic_write(&report_path, rendered.as_bytes()).map_err(|e| {
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

#[derive(Debug, Deserialize, Default)]
#[serde(default)]
struct DurableFrontmatter {
    facts: Vec<MemoryFact>,
    #[serde(flatten)]
    _extra: BTreeMap<String, JsonValue>,
}

#[derive(Debug, Clone)]
struct EpisodeDoc {
    id: String,
    path: String,
    title: String,
    body: String,
    session_id: String,
    turn_id: String,
    role: String,
    channel: String,
    source_path: String,
    timestamp_secs: i64,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
struct SemanticIndexMeta {
    schema_version: u32,
    provider: String,
    model: String,
    source_hash: String,
    doc_count: usize,
    rebuilt_at: String,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
struct SemanticIndexDoc {
    id: String,
    path: String,
    title: String,
    tier: String,
    tags: Vec<String>,
    body: String,
    source: Option<JsonValue>,
    superseded: bool,
    vector: Vec<f32>,
}

trait EmbeddingProvider {
    fn provider_name(&self) -> &str;
    fn model(&self) -> &str;
    fn embed(&self, text: &str) -> Vec<f32>;
}

struct FakeEmbeddingProvider {
    model: String,
}

impl EmbeddingProvider for FakeEmbeddingProvider {
    fn provider_name(&self) -> &str {
        "fake"
    }

    fn model(&self) -> &str {
        &self.model
    }

    fn embed(&self, text: &str) -> Vec<f32> {
        fake_embedding(text)
    }
}

fn expected_index_doc_count(
    paths: &AllbertPaths,
    config: &MemoryConfig,
    manifest: &MemoryManifest,
) -> Result<usize, KernelError> {
    let staged = list_staging_entries(&paths.memory_staging)?.len();
    let episodes = collect_episode_docs(paths, config)?.len();
    let facts = durable_fact_count(paths, config, manifest)?;
    Ok(manifest.documents.len() + staged + episodes + facts)
}

fn index_source_hash(
    paths: &AllbertPaths,
    config: &MemoryConfig,
    manifest: &MemoryManifest,
) -> Result<String, KernelError> {
    let mut hasher = Sha256::new();
    hasher.update(serde_json::to_vec(manifest).map_err(|e| {
        KernelError::InitFailed(format!("serialize memory source manifest hash: {e}"))
    })?);
    hasher.update(format!("episodes={}", config.episodes.enabled));
    hasher.update(format!("facts={}", config.facts.enabled));
    hash_markdown_sources(&mut hasher, &paths.memory_staging, &paths.memory)?;
    if config.episodes.enabled {
        hash_session_journals(&mut hasher, paths)?;
    }
    Ok(format!("{:x}", hasher.finalize()))
}

fn hash_markdown_sources(hasher: &mut Sha256, dir: &Path, root: &Path) -> Result<(), KernelError> {
    if !dir.exists() {
        return Ok(());
    }
    let mut files = Vec::new();
    collect_markdown_paths(dir, &mut files)?;
    files.sort();
    for path in files {
        let rel = path
            .strip_prefix(root)
            .unwrap_or(&path)
            .to_string_lossy()
            .replace('\\', "/");
        let raw = fs::read(&path)
            .map_err(|e| KernelError::InitFailed(format!("read {}: {e}", path.display())))?;
        hasher.update(rel.as_bytes());
        hasher.update(sha256_hex(&raw).as_bytes());
    }
    Ok(())
}

fn hash_session_journals(hasher: &mut Sha256, paths: &AllbertPaths) -> Result<(), KernelError> {
    for path in session_turn_files(paths)? {
        let rel = path
            .strip_prefix(&paths.sessions)
            .unwrap_or(&path)
            .to_string_lossy()
            .replace('\\', "/");
        let raw = fs::read(&path)
            .map_err(|e| KernelError::InitFailed(format!("read {}: {e}", path.display())))?;
        hasher.update(rel.as_bytes());
        hasher.update(sha256_hex(&raw).as_bytes());
    }
    Ok(())
}

fn collect_markdown_paths(dir: &Path, out: &mut Vec<PathBuf>) -> Result<(), KernelError> {
    for entry in fs::read_dir(dir)
        .map_err(|e| KernelError::InitFailed(format!("read {}: {e}", dir.display())))?
    {
        let entry = entry.map_err(|e| KernelError::InitFailed(e.to_string()))?;
        let path = entry.path();
        let name = entry.file_name();
        if name.to_string_lossy().starts_with('.') {
            continue;
        }
        if path.is_dir() {
            collect_markdown_paths(&path, out)?;
        } else if path.extension().and_then(|value| value.to_str()) == Some("md") {
            out.push(path);
        }
    }
    Ok(())
}

fn session_turn_files(paths: &AllbertPaths) -> Result<Vec<PathBuf>, KernelError> {
    if !paths.sessions.exists() {
        return Ok(Vec::new());
    }
    let mut files = Vec::new();
    for entry in fs::read_dir(&paths.sessions)
        .map_err(|e| KernelError::InitFailed(format!("read {}: {e}", paths.sessions.display())))?
    {
        let entry = entry.map_err(|e| KernelError::InitFailed(e.to_string()))?;
        let path = entry.path();
        let name = entry.file_name();
        if name.to_string_lossy().starts_with('.') || !path.is_dir() {
            continue;
        }
        let turns = path.join("turns.md");
        if turns.exists() {
            files.push(turns);
        }
    }
    files.sort();
    Ok(files)
}

fn collect_episode_docs(
    paths: &AllbertPaths,
    config: &MemoryConfig,
) -> Result<Vec<EpisodeDoc>, KernelError> {
    if !config.episodes.enabled {
        return Ok(Vec::new());
    }
    let mut docs = Vec::new();
    for turns in session_turn_files(paths)? {
        let session_id = turns
            .parent()
            .and_then(Path::file_name)
            .and_then(|value| value.to_str())
            .unwrap_or("unknown-session")
            .to_string();
        let raw = fs::read_to_string(&turns)
            .map_err(|e| KernelError::InitFailed(format!("read {}: {e}", turns.display())))?;
        let channel = extract_journal_channel(&raw);
        let source_path = turns
            .strip_prefix(&paths.sessions)
            .unwrap_or(&turns)
            .to_string_lossy()
            .replace('\\', "/");
        docs.extend(parse_episode_docs_from_journal(
            &session_id,
            &channel,
            &source_path,
            &raw,
            file_timestamp_secs(&turns),
            config.max_journal_tool_output_bytes,
        ));
    }
    Ok(docs)
}

fn parse_episode_docs_from_journal(
    session_id: &str,
    default_channel: &str,
    source_path: &str,
    raw: &str,
    fallback_timestamp_secs: i64,
    max_body_bytes: usize,
) -> Vec<EpisodeDoc> {
    let mut docs = Vec::new();
    let mut turn_ordinal = 0usize;
    let mut timestamp_secs = fallback_timestamp_secs;
    let mut role: Option<String> = None;
    let mut body = String::new();
    let mut turn_id = String::from("turn-0");
    let mut channel = default_channel.to_string();

    for line in raw.lines() {
        let trimmed = line.trim();
        if let Some(rest) = trimmed.strip_prefix("## ") {
            let ctx = EpisodeDocContext {
                session_id,
                channel: &channel,
                source_path,
                max_body_bytes,
            };
            push_episode_doc(
                &mut docs,
                &ctx,
                &turn_id,
                role.take(),
                timestamp_secs,
                &mut body,
            );
            turn_ordinal += 1;
            turn_id = format!("turn-{turn_ordinal}");
            timestamp_secs = OffsetDateTime::parse(rest.trim(), &Rfc3339)
                .map(|value| value.unix_timestamp())
                .unwrap_or(fallback_timestamp_secs);
            continue;
        }
        if let Some(rest) = trimmed.strip_prefix("- channel:") {
            channel = rest.trim().to_ascii_lowercase();
            continue;
        }
        if trimmed == "### user" || trimmed == "### assistant" {
            let ctx = EpisodeDocContext {
                session_id,
                channel: &channel,
                source_path,
                max_body_bytes,
            };
            push_episode_doc(
                &mut docs,
                &ctx,
                &turn_id,
                role.take(),
                timestamp_secs,
                &mut body,
            );
            role = Some(trimmed.trim_start_matches("### ").to_string());
            continue;
        }
        if trimmed.starts_with("### ") {
            let ctx = EpisodeDocContext {
                session_id,
                channel: &channel,
                source_path,
                max_body_bytes,
            };
            push_episode_doc(
                &mut docs,
                &ctx,
                &turn_id,
                role.take(),
                timestamp_secs,
                &mut body,
            );
            continue;
        }
        if role.is_some() {
            body.push_str(line);
            body.push('\n');
        }
    }
    let ctx = EpisodeDocContext {
        session_id,
        channel: &channel,
        source_path,
        max_body_bytes,
    };
    push_episode_doc(
        &mut docs,
        &ctx,
        &turn_id,
        role.take(),
        timestamp_secs,
        &mut body,
    );

    if docs.is_empty() && !raw.trim().is_empty() {
        let plain = markdown_to_plain_text(raw);
        let body = truncate_to_bytes(plain.trim(), max_body_bytes.max(512));
        let id = format!(
            "episode:{}",
            sha256_hex(format!("{session_id}:session:{body}").as_bytes())
        );
        docs.push(EpisodeDoc {
            id,
            path: format!("sessions/{source_path}#session"),
            title: format!("Session {session_id} summary"),
            body,
            session_id: session_id.into(),
            turn_id: "session".into(),
            role: "session".into(),
            channel,
            source_path: source_path.into(),
            timestamp_secs,
        });
    }
    docs
}

struct EpisodeDocContext<'a> {
    session_id: &'a str,
    channel: &'a str,
    source_path: &'a str,
    max_body_bytes: usize,
}

fn push_episode_doc(
    docs: &mut Vec<EpisodeDoc>,
    ctx: &EpisodeDocContext<'_>,
    turn_id: &str,
    role: Option<String>,
    timestamp_secs: i64,
    body: &mut String,
) {
    let Some(role) = role else {
        body.clear();
        return;
    };
    let plain = markdown_to_plain_text(body);
    let trimmed = plain.trim();
    if trimmed.is_empty() {
        body.clear();
        return;
    }
    let rendered_body = truncate_to_bytes(trimmed, ctx.max_body_bytes.max(512));
    let id = format!(
        "episode:{}",
        sha256_hex(format!("{}:{turn_id}:{role}:{rendered_body}", ctx.session_id).as_bytes())
    );
    let index = docs.len() + 1;
    docs.push(EpisodeDoc {
        id,
        path: format!("sessions/{}#{turn_id}-{role}-{index}", ctx.source_path),
        title: format!("Session {} {turn_id} {role}", ctx.session_id),
        body: rendered_body,
        session_id: ctx.session_id.into(),
        turn_id: turn_id.into(),
        role,
        channel: ctx.channel.into(),
        source_path: ctx.source_path.into(),
        timestamp_secs,
    });
    body.clear();
}

fn extract_journal_channel(raw: &str) -> String {
    raw.lines()
        .find_map(|line| {
            line.trim()
                .strip_prefix("- channel:")
                .map(str::trim)
                .map(|value| value.trim_matches('"').to_ascii_lowercase())
        })
        .filter(|value| !value.is_empty())
        .unwrap_or_else(|| "unknown".into())
}

fn durable_fact_count(
    paths: &AllbertPaths,
    config: &MemoryConfig,
    manifest: &MemoryManifest,
) -> Result<usize, KernelError> {
    if !config.facts.enabled {
        return Ok(0);
    }
    let mut count = 0usize;
    for entry in &manifest.documents {
        count += durable_facts_for_entry(paths, entry)?.len();
    }
    Ok(count)
}

fn durable_superseded_fact_ids(
    paths: &AllbertPaths,
    config: &MemoryConfig,
    manifest: &MemoryManifest,
) -> Result<BTreeSet<String>, KernelError> {
    if !config.facts.enabled {
        return Ok(BTreeSet::new());
    }
    let mut ids = BTreeSet::new();
    for entry in &manifest.documents {
        for fact in durable_facts_for_entry(paths, entry)? {
            ids.extend(
                fact.supersedes
                    .into_iter()
                    .filter(|value| !value.is_empty()),
            );
        }
    }
    Ok(ids)
}

fn durable_facts_for_entry(
    paths: &AllbertPaths,
    entry: &MemoryManifestEntry,
) -> Result<Vec<MemoryFact>, KernelError> {
    let full_path = paths.memory.join(&entry.path);
    let raw = fs::read_to_string(&full_path)
        .map_err(|e| KernelError::InitFailed(format!("read {}: {e}", full_path.display())))?;
    let (frontmatter_raw, _) = split_frontmatter_and_body(&raw);
    if frontmatter_raw.is_empty() {
        return Ok(Vec::new());
    }
    let frontmatter: DurableFrontmatter = serde_yaml::from_str(frontmatter_raw).map_err(|e| {
        KernelError::InitFailed(format!("parse {} frontmatter: {e}", full_path.display()))
    })?;
    normalize_facts(frontmatter.facts, usize::MAX)
}

fn normalize_facts(
    facts: Vec<MemoryFact>,
    max_facts: usize,
) -> Result<Vec<MemoryFact>, KernelError> {
    if facts.len() > max_facts {
        return Err(KernelError::InitFailed(format!(
            "memory facts cap exceeded: {} facts > max_facts_per_entry {}",
            facts.len(),
            max_facts
        )));
    }
    let mut normalized = Vec::with_capacity(facts.len());
    for mut fact in facts {
        fact.id = fact.id.trim().to_string();
        fact.subject = fact.subject.trim().to_string();
        fact.predicate = fact.predicate.trim().to_string();
        fact.object = fact.object.trim().to_string();
        fact.supersedes = fact
            .supersedes
            .into_iter()
            .map(|value| value.trim().to_string())
            .filter(|value| !value.is_empty())
            .collect();
        if fact.subject.is_empty() || fact.predicate.is_empty() || fact.object.is_empty() {
            return Err(KernelError::InitFailed(
                "memory facts require non-empty subject, predicate, and object".into(),
            ));
        }
        if fact.id.is_empty() {
            fact.id = format!(
                "fact_{}",
                &sha256_hex(
                    format!("{}:{}:{}", fact.subject, fact.predicate, fact.object).as_bytes()
                )[..12]
            );
        }
        normalized.push(fact);
    }
    Ok(normalized)
}

fn embedding_provider(
    config: &MemoryConfig,
) -> Result<Option<Box<dyn EmbeddingProvider>>, KernelError> {
    if !config.semantic.enabled {
        return Ok(None);
    }
    match config
        .semantic
        .provider
        .trim()
        .to_ascii_lowercase()
        .as_str()
    {
        "fake" => Ok(Some(Box::new(FakeEmbeddingProvider {
            model: if config.semantic.embedding_model.trim().is_empty() {
                "fake-hash-v1".into()
            } else {
                config.semantic.embedding_model.trim().to_string()
            },
        }))),
        "none" | "" => Err(KernelError::InitFailed(
            "memory.semantic.enabled requires memory.semantic.provider = \"fake\" in v0.11".into(),
        )),
        other => Err(KernelError::InitFailed(format!(
            "unsupported memory semantic provider `{other}`; v0.11 ships the fake provider only"
        ))),
    }
}

fn semantic_index_dir(paths: &AllbertPaths, provider: &dyn EmbeddingProvider) -> PathBuf {
    paths
        .memory_index_dir
        .join("semantic")
        .join(safe_path_component(provider.provider_name()))
        .join(safe_path_component(provider.model()))
}

fn safe_path_component(value: &str) -> String {
    let mut out = String::new();
    for ch in value.chars() {
        if ch.is_ascii_alphanumeric() || ch == '-' || ch == '_' || ch == '.' {
            out.push(ch);
        } else if !out.ends_with('-') {
            out.push('-');
        }
    }
    let trimmed = out.trim_matches('-');
    if trimmed.is_empty() {
        "default".into()
    } else {
        trimmed.into()
    }
}

fn ensure_semantic_index(
    paths: &AllbertPaths,
    config: &MemoryConfig,
    manifest: &MemoryManifest,
) -> Result<(), KernelError> {
    let Some(provider) = embedding_provider(config)? else {
        return Ok(());
    };
    let dir = semantic_index_dir(paths, provider.as_ref());
    let meta_path = dir.join("metadata.json");
    let docs_path = dir.join("documents.json");
    let source_hash = index_source_hash(paths, config, manifest)?;
    let expected_doc_count = semantic_source_documents(paths, config, manifest)?.len();
    if let Ok(meta) = load_semantic_meta(&meta_path) {
        if meta.schema_version == SEMANTIC_SCHEMA_VERSION
            && meta.provider == provider.provider_name()
            && meta.model == provider.model()
            && meta.source_hash == source_hash
            && meta.doc_count == expected_doc_count
            && docs_path.exists()
        {
            return Ok(());
        }
    }
    rebuild_semantic_index(paths, config, manifest, provider.as_ref())
}

fn rebuild_semantic_index(
    paths: &AllbertPaths,
    config: &MemoryConfig,
    manifest: &MemoryManifest,
    provider: &dyn EmbeddingProvider,
) -> Result<(), KernelError> {
    let dir = semantic_index_dir(paths, provider);
    fs::create_dir_all(&dir)
        .map_err(|e| KernelError::InitFailed(format!("create {}: {e}", dir.display())))?;
    let docs = semantic_source_documents(paths, config, manifest)?
        .into_iter()
        .map(|mut doc| {
            doc.vector = provider.embed(&format!(
                "{}\n{}\n{}",
                doc.title,
                doc.tags.join(" "),
                doc.body
            ));
            doc
        })
        .collect::<Vec<_>>();
    let meta = SemanticIndexMeta {
        schema_version: SEMANTIC_SCHEMA_VERSION,
        provider: provider.provider_name().into(),
        model: provider.model().into(),
        source_hash: index_source_hash(paths, config, manifest)?,
        doc_count: docs.len(),
        rebuilt_at: now_rfc3339()?,
    };
    atomic_write(
        &dir.join("documents.json"),
        serde_json::to_vec_pretty(&docs)
            .map_err(|e| KernelError::InitFailed(format!("serialize semantic documents: {e}")))?
            .as_slice(),
    )?;
    atomic_write(
        &dir.join("metadata.json"),
        serde_json::to_vec_pretty(&meta)
            .map_err(|e| KernelError::InitFailed(format!("serialize semantic metadata: {e}")))?
            .as_slice(),
    )
}

fn load_semantic_meta(path: &Path) -> Result<SemanticIndexMeta, KernelError> {
    let raw = fs::read_to_string(path)
        .map_err(|e| KernelError::InitFailed(format!("read {}: {e}", path.display())))?;
    serde_json::from_str(&raw)
        .map_err(|e| KernelError::InitFailed(format!("parse {}: {e}", path.display())))
}

fn load_semantic_docs(
    paths: &AllbertPaths,
    provider: &dyn EmbeddingProvider,
) -> Result<Vec<SemanticIndexDoc>, KernelError> {
    let path = semantic_index_dir(paths, provider).join("documents.json");
    let raw = fs::read_to_string(&path)
        .map_err(|e| KernelError::InitFailed(format!("read {}: {e}", path.display())))?;
    serde_json::from_str(&raw)
        .map_err(|e| KernelError::InitFailed(format!("parse {}: {e}", path.display())))
}

fn semantic_source_documents(
    paths: &AllbertPaths,
    config: &MemoryConfig,
    manifest: &MemoryManifest,
) -> Result<Vec<SemanticIndexDoc>, KernelError> {
    let mut docs = Vec::new();
    let superseded_fact_ids = durable_superseded_fact_ids(paths, config, manifest)?;
    for entry in &manifest.documents {
        let full_path = paths.memory.join(&entry.path);
        let raw = fs::read_to_string(&full_path).unwrap_or_default();
        let (_, body_markdown) = split_frontmatter_and_body(&raw);
        let body = markdown_to_plain_text(&body_markdown);
        docs.push(SemanticIndexDoc {
            id: entry.content_hash.clone(),
            path: entry.path.clone(),
            title: entry.title.clone(),
            tier: "durable".into(),
            tags: entry.tags.clone(),
            body,
            source: Some(json!({"kind": "durable_memory", "id": entry.path.clone()})),
            superseded: false,
            vector: Vec::new(),
        });
        if config.facts.enabled {
            for fact in durable_facts_for_entry(paths, entry)? {
                docs.push(SemanticIndexDoc {
                    id: format!("fact:{}", fact.id),
                    path: format!("{}#fact-{}", entry.path, slugify(&fact.id)),
                    title: format!("Fact: {} {} {}", fact.subject, fact.predicate, fact.object),
                    tier: "fact".into(),
                    tags: entry.tags.clone(),
                    body: format!("{} {} {}", fact.subject, fact.predicate, fact.object),
                    source: Some(json!({
                        "kind": "durable_memory",
                        "id": entry.path.clone(),
                        "fact_id": fact.id.clone(),
                    })),
                    superseded: superseded_fact_ids.contains(&fact.id),
                    vector: Vec::new(),
                });
            }
        }
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
        docs.push(SemanticIndexDoc {
            id: sha256_hex(staged.to_string_lossy().as_bytes()),
            path: relative_to_memory(paths, &staged)?,
            title: derive_title(&body_markdown, &staged),
            tier: "staging".into(),
            tags: vec![frontmatter.kind.unwrap_or_else(|| "unknown".into())],
            body: markdown_to_plain_text(&body_markdown),
            source: Some(json!({"kind": "staged_memory"})),
            superseded: false,
            vector: Vec::new(),
        });
    }
    if config.episodes.enabled {
        for episode in collect_episode_docs(paths, config)? {
            docs.push(SemanticIndexDoc {
                id: episode.id,
                path: episode.path,
                title: episode.title,
                tier: "episode".into(),
                tags: vec!["episode".into()],
                body: episode.body,
                source: Some(json!({
                    "kind": "session_working_history",
                    "session_id": episode.session_id,
                    "turn_id": episode.turn_id,
                    "path": episode.source_path,
                })),
                superseded: false,
                vector: Vec::new(),
            });
        }
    }
    Ok(docs)
}

fn apply_semantic_fusion(
    paths: &AllbertPaths,
    config: &MemoryConfig,
    manifest: &MemoryManifest,
    input: &SearchMemoryInput,
    raw_query: &str,
    bm25_hits: Vec<SearchMemoryHit>,
    limit: usize,
) -> Result<Vec<SearchMemoryHit>, KernelError> {
    let Some(provider) = embedding_provider(config)? else {
        return Ok(bm25_hits);
    };
    ensure_semantic_index(paths, config, manifest)?;
    let query_vector = provider.embed(raw_query);
    let mut semantic_scores = load_semantic_docs(paths, provider.as_ref())?
        .into_iter()
        .filter(|doc| semantic_doc_matches_tier(doc, input))
        .filter_map(|doc| {
            let score = cosine_similarity(&query_vector, &doc.vector);
            (score > 0.0).then_some((doc, score))
        })
        .collect::<Vec<_>>();
    semantic_scores.sort_by(|(left_doc, left_score), (right_doc, right_score)| {
        right_score
            .partial_cmp(left_score)
            .unwrap_or(std::cmp::Ordering::Equal)
            .then_with(|| left_doc.path.cmp(&right_doc.path))
    });
    semantic_scores.truncate(limit.saturating_mul(4).max(limit));

    #[derive(Clone)]
    struct Candidate {
        hit: SearchMemoryHit,
        bm25: Option<f32>,
        semantic: Option<f32>,
    }

    let mut candidates = BTreeMap::<String, Candidate>::new();
    for hit in bm25_hits {
        candidates.insert(
            hit.path.clone(),
            Candidate {
                bm25: Some(hit.score),
                semantic: None,
                hit,
            },
        );
    }
    for (doc, score) in semantic_scores {
        let key = doc.path.clone();
        let semantic_hit = SearchMemoryHit {
            path: doc.path,
            title: doc.title,
            tier: doc.tier,
            score,
            tags: doc.tags,
            snippet: make_excerpt(&doc.body, raw_query, 220),
            source: doc.source,
        };
        candidates
            .entry(key)
            .and_modify(|candidate| {
                candidate.semantic = Some(score);
            })
            .or_insert(Candidate {
                hit: semantic_hit,
                bm25: None,
                semantic: Some(score),
            });
    }

    let bm25_range = score_range(candidates.values().filter_map(|candidate| candidate.bm25));
    let semantic_range = score_range(
        candidates
            .values()
            .filter_map(|candidate| candidate.semantic),
    );
    let semantic_weight = config.semantic.hybrid_weight.clamp(0.0, 1.0) as f32;
    let bm25_weight = 1.0 - semantic_weight;
    let mut fused = candidates
        .into_values()
        .map(|mut candidate| {
            let bm25 = candidate
                .bm25
                .map(|score| normalize_score(score, bm25_range))
                .unwrap_or(0.0);
            let semantic = candidate
                .semantic
                .map(|score| normalize_score(score, semantic_range))
                .unwrap_or(0.0);
            candidate.hit.score = (bm25 * bm25_weight) + (semantic * semantic_weight);
            candidate.hit
        })
        .collect::<Vec<_>>();
    fused.sort_by(|left, right| {
        right
            .score
            .partial_cmp(&left.score)
            .unwrap_or(std::cmp::Ordering::Equal)
            .then_with(|| left.path.cmp(&right.path))
    });
    fused.truncate(limit);
    Ok(fused)
}

fn semantic_doc_matches_tier(doc: &SemanticIndexDoc, input: &SearchMemoryInput) -> bool {
    let tier_matches = match input.tier {
        MemoryTier::All => true,
        MemoryTier::Durable => doc.tier == "durable",
        MemoryTier::Staging => doc.tier == "staging",
        MemoryTier::Episode => doc.tier == "episode",
        MemoryTier::Fact => doc.tier == "fact",
    };
    tier_matches && (doc.tier != "fact" || input.include_superseded || !doc.superseded)
}

fn score_range(scores: impl Iterator<Item = f32>) -> Option<(f32, f32)> {
    let mut min = f32::INFINITY;
    let mut max = f32::NEG_INFINITY;
    let mut seen = false;
    for score in scores {
        seen = true;
        min = min.min(score);
        max = max.max(score);
    }
    seen.then_some((min, max))
}

fn normalize_score(score: f32, range: Option<(f32, f32)>) -> f32 {
    let Some((min, max)) = range else {
        return 0.0;
    };
    if (max - min).abs() < f32::EPSILON {
        return 1.0;
    }
    ((score - min) / (max - min)).clamp(0.0, 1.0)
}

fn fake_embedding(text: &str) -> Vec<f32> {
    let mut vector = vec![0.0; FAKE_EMBEDDING_DIM];
    for token in normalized_tokens(text) {
        let hash = sha256_hex(token.as_bytes());
        let bucket = usize::from_str_radix(&hash[..4], 16).unwrap_or_default() % FAKE_EMBEDDING_DIM;
        vector[bucket] += 1.0;
    }
    normalize_vector(vector)
}

fn normalized_tokens(text: &str) -> Vec<String> {
    let mut tokens = Vec::new();
    let mut current = String::new();
    for ch in text.chars() {
        if ch.is_ascii_alphanumeric() {
            current.push(ch.to_ascii_lowercase());
        } else if !current.is_empty() {
            tokens.push(std::mem::take(&mut current));
        }
    }
    if !current.is_empty() {
        tokens.push(current);
    }
    tokens
}

fn normalize_vector(mut vector: Vec<f32>) -> Vec<f32> {
    let magnitude = vector.iter().map(|value| value * value).sum::<f32>().sqrt();
    if magnitude <= f32::EPSILON {
        return vector;
    }
    for value in &mut vector {
        *value /= magnitude;
    }
    vector
}

fn cosine_similarity(left: &[f32], right: &[f32]) -> f32 {
    left.iter()
        .zip(right.iter())
        .map(|(left, right)| left * right)
        .sum::<f32>()
}

fn maybe_rebuild_index(
    paths: &AllbertPaths,
    config: &MemoryConfig,
    manifest: &MemoryManifest,
    force: bool,
    explicit_reason: Option<&str>,
) -> Result<Option<RebuildIndexReport>, KernelError> {
    let manifest_hash = index_source_hash(paths, config, manifest)?;
    let expected_doc_count = expected_index_doc_count(paths, config, manifest)?;
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
            Some("memory-sources-changed".into())
        } else if meta.doc_count != expected_doc_count {
            Some("doc-count-drift".into())
        } else {
            None
        }
    };

    if let Some(reason) = reason {
        Ok(Some(rebuild_index(paths, config, manifest, &reason)?))
    } else {
        Ok(None)
    }
}

fn rebuild_index(
    paths: &AllbertPaths,
    config: &MemoryConfig,
    manifest: &MemoryManifest,
    reason: &str,
) -> Result<RebuildIndexReport, KernelError> {
    let lock = File::options()
        .read(true)
        .write(true)
        .create(true)
        .truncate(false)
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
    let source_kind_f = schema.get_field("source_kind").expect("source_kind field");
    let source_f = schema.get_field("source").expect("source field");
    let session_id_f = schema.get_field("session_id").expect("session_id field");
    let turn_id_f = schema.get_field("turn_id").expect("turn_id field");
    let role_f = schema.get_field("role").expect("role field");
    let channel_f = schema.get_field("channel").expect("channel field");
    let fact_subject_f = schema
        .get_field("fact_subject")
        .expect("fact_subject field");
    let fact_predicate_f = schema
        .get_field("fact_predicate")
        .expect("fact_predicate field");
    let fact_object_f = schema.get_field("fact_object").expect("fact_object field");
    let valid_from_f = schema.get_field("valid_from").expect("valid_from field");
    let valid_until_f = schema.get_field("valid_until").expect("valid_until field");
    let superseded_f = schema.get_field("superseded").expect("superseded field");
    let mut doc_count = 0usize;
    let superseded_fact_ids = durable_superseded_fact_ids(paths, config, manifest)?;

    for entry in &manifest.documents {
        let full_path = paths.memory.join(&entry.path);
        let raw = fs::read_to_string(&full_path).unwrap_or_default();
        let (_, body_markdown) = split_frontmatter_and_body(&raw);
        let body = markdown_to_plain_text(&body_markdown);
        let source = json!({
            "kind": "durable_memory",
            "id": entry.path.clone(),
        });
        writer
            .add_document(doc!(
                id_f => entry.content_hash.clone(),
                path_f => entry.path.clone(),
                title_f => entry.title.clone(),
                body_f => body,
                tags_f => entry.tags.clone().join(","),
                tier_f => "durable",
                source_kind_f => "durable_memory",
                source_f => serde_json::to_string(&source).unwrap_or_else(|_| "{}".into()),
                date_f => tantivy::DateTime::from_timestamp_secs(file_timestamp_secs(&full_path)),
            ))
            .map_err(|e| {
                KernelError::InitFailed(format!("index document {}: {e}", full_path.display()))
            })?;
        doc_count += 1;

        if config.facts.enabled {
            for fact in durable_facts_for_entry(paths, entry)? {
                let source = json!({
                    "kind": "durable_memory",
                    "id": entry.path.clone(),
                    "fact_id": fact.id.clone(),
                });
                let fact_body = format!("{} {} {}", fact.subject, fact.predicate, fact.object);
                let superseded = superseded_fact_ids.contains(&fact.id);
                writer
                    .add_document(doc!(
                        id_f => format!("fact:{}", fact.id),
                        path_f => format!("{}#fact-{}", entry.path, slugify(&fact.id)),
                        title_f => format!("Fact: {} {} {}", fact.subject, fact.predicate, fact.object),
                        body_f => fact_body,
                        tags_f => entry.tags.clone().join(","),
                        tier_f => "fact",
                        source_kind_f => "durable_memory",
                        source_f => serde_json::to_string(&source).unwrap_or_else(|_| "{}".into()),
                        fact_subject_f => fact.subject.clone(),
                        fact_predicate_f => fact.predicate.clone(),
                        fact_object_f => fact.object.clone(),
                        valid_from_f => fact.valid_from.clone().unwrap_or_default(),
                        valid_until_f => fact.valid_until.clone().unwrap_or_default(),
                        superseded_f => superseded.to_string(),
                        date_f => tantivy::DateTime::from_timestamp_secs(file_timestamp_secs(&full_path)),
                    ))
                    .map_err(|e| {
                        KernelError::InitFailed(format!(
                            "index fact {} from {}: {e}",
                            fact.id,
                            full_path.display()
                        ))
                    })?;
                doc_count += 1;
            }
        }
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
                source_kind_f => "staged_memory",
                source_f => serde_json::to_string(&json!({"kind": "staged_memory"})).unwrap_or_else(|_| "{}".into()),
                date_f => tantivy::DateTime::from_timestamp_secs(file_timestamp_secs(&staged)),
            ))
            .map_err(|e| {
                KernelError::InitFailed(format!("index staged entry {}: {e}", staged.display()))
            })?;
        doc_count += 1;
    }

    if config.episodes.enabled {
        for episode in collect_episode_docs(paths, config)? {
            let source = json!({
                "kind": "session_working_history",
                "session_id": episode.session_id.clone(),
                "turn_id": episode.turn_id.clone(),
                "path": episode.source_path.clone(),
            });
            writer
                .add_document(doc!(
                    id_f => episode.id.clone(),
                    path_f => episode.path.clone(),
                    title_f => episode.title.clone(),
                    body_f => episode.body.clone(),
                    tags_f => "episode",
                    tier_f => "episode",
                    source_kind_f => "session_working_history",
                    source_f => serde_json::to_string(&source).unwrap_or_else(|_| "{}".into()),
                    session_id_f => episode.session_id.clone(),
                    turn_id_f => episode.turn_id.clone(),
                    role_f => episode.role.clone(),
                    channel_f => episode.channel.clone(),
                    date_f => tantivy::DateTime::from_timestamp_secs(episode.timestamp_secs),
                ))
                .map_err(|e| {
                    KernelError::InitFailed(format!(
                        "index session episode {}: {e}",
                        episode.source_path
                    ))
                })?;
            doc_count += 1;
        }
    }

    writer
        .commit()
        .map_err(|e| KernelError::InitFailed(format!("commit tantivy index: {e}")))?;
    if let Some(provider) = embedding_provider(config)? {
        rebuild_semantic_index(paths, config, manifest, provider.as_ref())?;
    }

    let elapsed_ms = start.elapsed().as_millis();
    let meta = MemoryIndexMeta {
        schema_version: INDEX_SCHEMA_VERSION,
        tantivy_version: TANTIVY_VERSION.into(),
        last_rebuild_at: now_rfc3339()?,
        last_rebuild_reason: reason.into(),
        doc_count,
        manifest_hash: index_source_hash(paths, config, manifest)?,
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

fn write_reconcile_meta(
    paths: &AllbertPaths,
    meta: &MemoryReconcileMeta,
) -> Result<(), KernelError> {
    let rendered = serde_json::to_vec_pretty(meta)
        .map_err(|e| KernelError::InitFailed(format!("serialize reconcile meta: {e}")))?;
    atomic_write(&paths.memory_reconcile_meta, &rendered)
}

fn load_index_meta(paths: &AllbertPaths) -> Result<MemoryIndexMeta, KernelError> {
    let raw = fs::read_to_string(&paths.memory_index_meta).map_err(|e| {
        KernelError::InitFailed(format!("read {}: {e}", paths.memory_index_meta.display()))
    })?;
    serde_json::from_str(&raw).map_err(|e| {
        KernelError::InitFailed(format!("parse {}: {e}", paths.memory_index_meta.display()))
    })
}

fn load_reconcile_meta(paths: &AllbertPaths) -> Result<MemoryReconcileMeta, KernelError> {
    let raw = fs::read_to_string(&paths.memory_reconcile_meta).map_err(|e| {
        KernelError::InitFailed(format!(
            "read {}: {e}",
            paths.memory_reconcile_meta.display()
        ))
    })?;
    serde_json::from_str(&raw).map_err(|e| {
        KernelError::InitFailed(format!(
            "parse {}: {e}",
            paths.memory_reconcile_meta.display()
        ))
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
        facts: frontmatter.facts,
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

fn render_promoted_durable_note(
    preview: &MemoryPromotionPreview,
    record: &StagedMemoryRecord,
    frontmatter: &StageFrontmatter,
) -> Result<String, KernelError> {
    let mut durable = frontmatter.extra.clone();
    durable.insert("summary".into(), JsonValue::String(preview.summary.clone()));
    if !record.tags.is_empty() {
        durable.insert(
            "tags".into(),
            serde_json::to_value(&record.tags)
                .map_err(|e| KernelError::InitFailed(format!("serialize tags: {e}")))?,
        );
    }
    if !record.facts.is_empty() {
        durable.insert(
            "facts".into(),
            serde_json::to_value(&record.facts)
                .map_err(|e| KernelError::InitFailed(format!("serialize facts: {e}")))?,
        );
    }
    if let Some(provenance) = &record.provenance {
        durable.insert("provenance".into(), provenance.clone());
    }
    durable.insert(
        "source".into(),
        json!({
            "kind": "staged_memory",
            "id": record.id.clone(),
            "agent": record.agent.clone(),
            "session_id": record.session_id.clone(),
            "turn_id": record.turn_id.clone(),
            "promoted_at": now_rfc3339()?,
        }),
    );

    let title_and_body = format!("# {}\n\n{}\n", preview.title.trim(), record.body.trim());
    if durable.is_empty() {
        return Ok(title_and_body);
    }
    let yaml = serde_yaml::to_string(&durable)
        .map_err(|e| KernelError::InitFailed(format!("serialize durable frontmatter: {e}")))?;
    Ok(format!("---\n{}---\n\n{}", yaml, title_and_body))
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

fn truncate_to_bytes(input: &str, max_bytes: usize) -> String {
    if input.len() <= max_bytes {
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

fn sanitize_query(input: &str) -> String {
    let mut parts = Vec::new();
    let mut current = String::new();
    for ch in input.chars() {
        if ch.is_ascii_alphanumeric() || ch == '_' || ch == '-' {
            current.push(ch);
        } else if !current.is_empty() {
            parts.push(std::mem::take(&mut current));
        }
    }
    if !current.is_empty() {
        parts.push(current);
    }
    if parts.is_empty() {
        "memory".into()
    } else {
        parts.join(" ")
    }
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

fn render_turn_memory_sections(
    memory_head: &str,
    daily_head: &str,
    yesterday_tail: Option<&str>,
    ephemeral_summary: &str,
    prefetch_hits: &[SearchMemoryHit],
) -> Vec<String> {
    let mut sections = Vec::new();
    if !memory_head.trim().is_empty() {
        sections.push(format!("## MEMORY.md\n{}", memory_head.trim()));
    }
    if !daily_head.trim().is_empty() {
        sections.push(format!("## Today's daily note\n{}", daily_head.trim()));
    }
    if let Some(yesterday_tail) = yesterday_tail.filter(|value| !value.trim().is_empty()) {
        sections.push(format!(
            "## Yesterday's daily note (tail)\n{}",
            yesterday_tail.trim()
        ));
    }
    if !ephemeral_summary.trim().is_empty() {
        sections.push(format!(
            "## Session working memory\n{}",
            ephemeral_summary.trim()
        ));
    }
    if !prefetch_hits.is_empty() {
        let mut rendered = String::from("## Retrieved memory\n");
        for hit in prefetch_hits {
            rendered.push_str(&format!(
                "- {} ({})\n  {}\n",
                hit.title,
                hit.path,
                hit.snippet.trim()
            ));
        }
        sections.push(rendered.trim_end().to_string());
    }
    sections
}

fn rendered_sections_bytes(sections: &[String]) -> usize {
    if sections.is_empty() {
        0
    } else {
        sections.iter().map(|section| section.len()).sum::<usize>() + ((sections.len() - 1) * 2)
    }
}

fn read_memory_head(paths: &AllbertPaths, max_bytes: usize) -> Result<String, KernelError> {
    let raw = fs::read_to_string(&paths.memory_index).map_err(|e| {
        KernelError::InitFailed(format!("read {}: {e}", paths.memory_index.display()))
    })?;
    Ok(truncate_to_bytes(raw.trim(), max_bytes))
}

fn read_daily_head(paths: &AllbertPaths, max_bytes: usize) -> Result<String, KernelError> {
    let path = daily_note_path(
        paths,
        OffsetDateTime::now_local().unwrap_or_else(|_| OffsetDateTime::now_utc()),
    );
    if !path.exists() {
        return Ok(String::new());
    }
    let raw = fs::read_to_string(&path)
        .map_err(|e| KernelError::InitFailed(format!("read {}: {e}", path.display())))?;
    Ok(truncate_to_bytes(raw.trim(), max_bytes))
}

fn read_yesterday_tail(
    paths: &AllbertPaths,
    max_bytes: usize,
) -> Result<Option<String>, KernelError> {
    let yesterday = OffsetDateTime::now_local().unwrap_or_else(|_| OffsetDateTime::now_utc())
        - time::Duration::days(1);
    let path = daily_note_path(paths, yesterday);
    if !path.exists() {
        return Ok(None);
    }
    let raw = fs::read_to_string(&path)
        .map_err(|e| KernelError::InitFailed(format!("read {}: {e}", path.display())))?;
    Ok(Some(truncate_tail_to_bytes(raw.trim(), max_bytes)))
}

fn truncate_tail_to_bytes(input: &str, max_bytes: usize) -> String {
    if input.len() <= max_bytes {
        return input.to_string();
    }

    let mut start = input.len();
    for (idx, _) in input.char_indices().rev() {
        let slice = &input[idx..];
        if slice.len() > max_bytes {
            break;
        }
        start = idx;
    }
    input[start..].to_string()
}

fn daily_note_path(paths: &AllbertPaths, timestamp: OffsetDateTime) -> PathBuf {
    let format = time::macros::format_description!("[year]-[month]-[day]");
    let file = timestamp
        .format(&format)
        .unwrap_or_else(|_| "1970-01-01".to_string());
    paths.memory_daily.join(format!("{file}.md"))
}

fn build_schema() -> Schema {
    let mut builder = Schema::builder();
    builder.add_text_field("id", STRING | STORED);
    builder.add_text_field("path", STRING | STORED);
    builder.add_text_field("title", TEXT | STORED);
    builder.add_text_field("body", TEXT | STORED);
    builder.add_text_field("tags", STRING | STORED);
    builder.add_text_field("tier", STRING | STORED);
    builder.add_text_field("source_kind", STRING | STORED);
    builder.add_text_field("source", STRING | STORED);
    builder.add_text_field("session_id", STRING | STORED);
    builder.add_text_field("turn_id", STRING | STORED);
    builder.add_text_field("role", STRING | STORED);
    builder.add_text_field("channel", STRING | STORED);
    builder.add_text_field("fact_subject", TEXT | STORED);
    builder.add_text_field("fact_predicate", STRING | STORED);
    builder.add_text_field("fact_object", TEXT | STORED);
    builder.add_text_field("valid_from", STRING | STORED);
    builder.add_text_field("valid_until", STRING | STORED);
    builder.add_text_field("superseded", STRING | STORED);
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
    let (_, body) = split_frontmatter_and_body(raw);
    let title_source = if raw.starts_with("---\n") {
        body.as_str()
    } else {
        raw
    };
    for line in title_source.lines() {
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
    crate::atomic_write(path, bytes)
        .map_err(|e| KernelError::InitFailed(format!("write {}: {e}", path.display())))
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
                fingerprint_basis: None,
                facts: Vec::new(),
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
                include_superseded: false,
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
                include_superseded: false,
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
                fingerprint_basis: None,
                facts: Vec::new(),
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
                include_superseded: false,
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
                fingerprint_basis: None,
                facts: Vec::new(),
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
                include_superseded: false,
            },
        )
        .unwrap();
        assert!(results.is_empty());
    }

    #[test]
    fn rejected_staged_memory_can_be_reconsidered() {
        let temp = TempRoot::new();
        let paths = temp.paths();
        paths.ensure().unwrap();
        bootstrap_curated_memory(&paths, &MemoryConfig::default()).unwrap();
        let staged = stage_memory(
            &paths,
            &MemoryConfig::default(),
            StageMemoryRequest {
                session_id: "sess-reconsider".into(),
                turn_id: "turn-1".into(),
                agent: "allbert/root".into(),
                source: "channel".into(),
                content: "Reconsider this durable candidate.".into(),
                kind: StagedMemoryKind::ExplicitRequest,
                summary: "Reconsider candidate".into(),
                tags: vec!["recovery".into()],
                provenance: None,
                fingerprint_basis: None,
                facts: Vec::new(),
            },
        )
        .unwrap();
        let rejected_path =
            reject_staged_memory(&paths, &MemoryConfig::default(), &staged.id, None).unwrap();
        assert!(paths.memory.join(&rejected_path).exists());

        let restored =
            reconsider_staged_memory(&paths, &MemoryConfig::default(), &staged.id).unwrap();
        assert!(paths.memory.join(&restored).exists());
        assert!(!paths.memory.join(&rejected_path).exists());

        let entry = get_staged_memory(&paths, &MemoryConfig::default(), &staged.id).unwrap();
        assert_eq!(entry.summary, "Reconsider candidate");
    }

    #[test]
    fn forgotten_memory_can_be_restored_from_trash() {
        let temp = TempRoot::new();
        let paths = temp.paths();
        paths.ensure().unwrap();
        fs::create_dir_all(paths.memory_notes.join("projects")).unwrap();
        fs::write(
            paths.memory_notes.join("projects/restorable.md"),
            "# Restorable\n\nThis note should survive trash roundtrip.\n",
        )
        .unwrap();
        bootstrap_curated_memory(&paths, &MemoryConfig::default()).unwrap();
        let preview = preview_forget_memory(
            &paths,
            &MemoryConfig::default(),
            "notes/projects/restorable.md",
        )
        .unwrap();
        let forgotten = forget_memory(&paths, &MemoryConfig::default(), &preview).unwrap();
        assert_eq!(forgotten, vec!["notes/projects/restorable.md"]);
        assert!(!paths.memory_notes.join("projects/restorable.md").exists());
        assert_eq!(
            list_markdown_recursive(&paths.memory_trash).unwrap().len(),
            1
        );

        let restored = restore_memory(&paths, &MemoryConfig::default(), "restorable").unwrap();
        assert_eq!(restored, "notes/projects/restorable.md");
        let raw = fs::read_to_string(paths.memory_notes.join("projects/restorable.md")).unwrap();
        assert!(raw.contains("trash roundtrip"));
        assert!(list_markdown_recursive(&paths.memory_trash)
            .unwrap()
            .is_empty());
    }

    #[test]
    fn recovery_gc_removes_expired_trash_and_rejections() {
        let temp = TempRoot::new();
        let paths = temp.paths();
        paths.ensure().unwrap();
        bootstrap_curated_memory(&paths, &MemoryConfig::default()).unwrap();
        let trash = TrashEnvelope {
            trash: TrashMetadata {
                original_id: "old-memory".into(),
                original_path: "notes/old-memory.md".into(),
                deleted_at: "2000-01-01T00:00:00Z".into(),
                delete_reason: Some("test".into()),
            },
        };
        let trash_yaml = serde_yaml::to_string(&trash).unwrap();
        atomic_write(
            &paths.memory_trash.join("old-memory.md"),
            format!("---\n{}---\n\n# Old\n", trash_yaml).as_bytes(),
        )
        .unwrap();
        fs::create_dir_all(paths.memory_staging_rejected.join("session")).unwrap();
        let rejection = RejectedStageEnvelope {
            rejection: RejectedStageMetadata {
                original_id: "old-stage".into(),
                source_session: "session".into(),
                rejected_at: "2000-01-01T00:00:00Z".into(),
                reason: "test".into(),
            },
        };
        let rejection_yaml = serde_yaml::to_string(&rejection).unwrap();
        atomic_write(
            &paths.memory_staging_rejected.join("session/old-stage.md"),
            format!("---\n{}---\n\n# Old staged\n", rejection_yaml).as_bytes(),
        )
        .unwrap();

        let config = MemoryConfig {
            trash_retention_days: 1,
            rejected_retention_days: 1,
            ..MemoryConfig::default()
        };
        assert_eq!(gc_memory_recovery(&paths, &config).unwrap(), 2);
        assert!(list_markdown_recursive(&paths.memory_trash)
            .unwrap()
            .is_empty());
        assert!(list_markdown_recursive(&paths.memory_staging_rejected)
            .unwrap()
            .is_empty());
    }

    #[test]
    fn episode_journal_indexes_search_and_removes_on_rebuild() {
        let temp = TempRoot::new();
        let paths = temp.paths();
        paths.ensure().unwrap();
        let session_dir = paths.sessions.join("episode-session");
        fs::create_dir_all(&session_dir).unwrap();
        fs::write(
            session_dir.join("turns.md"),
            "# Session episode-session\n\n- channel: cli\n- started_at: 2026-04-20T00:00:00Z\n\n## 2026-04-20T01:02:03Z\n- channel: cli\n- cost_delta_usd: 0.000000\n\n### user\n\nPlease remember the blue notebook lives on shelf seven.\n\n### assistant\n\nI noted the shelf-seven notebook detail as working history.\n",
        )
        .unwrap();

        bootstrap_curated_memory(&paths, &MemoryConfig::default()).unwrap();
        let hits = search_memory(
            &paths,
            &MemoryConfig::default(),
            SearchMemoryInput {
                query: "blue notebook".into(),
                tier: MemoryTier::Episode,
                limit: Some(5),
                include_superseded: false,
            },
        )
        .unwrap();
        assert!(!hits.is_empty());
        assert!(hits.iter().all(|hit| hit.tier == "episode"));
        assert_eq!(
            hits[0]
                .source
                .as_ref()
                .and_then(|source| source.get("kind"))
                .and_then(JsonValue::as_str),
            Some("session_working_history")
        );

        let prefetch = build_turn_memory_snapshot(
            &paths,
            &MemoryConfig::default(),
            "",
            Some("blue notebook"),
            5,
        )
        .unwrap();
        assert!(
            prefetch.prefetch_hits.is_empty(),
            "durable prefetch must not inject episode working history by default"
        );

        fs::remove_dir_all(&session_dir).unwrap();
        rebuild_memory_index(&paths, &MemoryConfig::default(), true).unwrap();
        let removed = search_memory(
            &paths,
            &MemoryConfig::default(),
            SearchMemoryInput {
                query: "blue notebook".into(),
                tier: MemoryTier::Episode,
                limit: Some(5),
                include_superseded: false,
            },
        )
        .unwrap();
        assert!(removed.is_empty());
    }

    #[test]
    fn fact_metadata_roundtrips_promotes_and_indexes_only_after_review() {
        let temp = TempRoot::new();
        let paths = temp.paths();
        paths.ensure().unwrap();
        bootstrap_curated_memory(&paths, &MemoryConfig::default()).unwrap();
        let fact = MemoryFact {
            id: "fact_primary_database".into(),
            subject: "Allbert production database".into(),
            predicate: "uses".into(),
            object: "Postgres".into(),
            valid_from: Some("2026-04-20T00:00:00Z".into()),
            valid_until: None,
            supersedes: Vec::new(),
            source: Some(json!({"kind": "operator_review"})),
        };
        let staged = stage_memory(
            &paths,
            &MemoryConfig::default(),
            StageMemoryRequest {
                session_id: "fact-session".into(),
                turn_id: "turn-1".into(),
                agent: "allbert/root".into(),
                source: "channel".into(),
                content: "We use Postgres for production data.".into(),
                kind: StagedMemoryKind::LearnedFact,
                summary: "Production database fact".into(),
                tags: vec!["database".into()],
                provenance: None,
                fingerprint_basis: None,
                facts: vec![fact],
            },
        )
        .unwrap();
        assert_eq!(staged.facts.len(), 1);

        let staged_fact_hits = search_memory(
            &paths,
            &MemoryConfig::default(),
            SearchMemoryInput {
                query: "Postgres".into(),
                tier: MemoryTier::Fact,
                limit: Some(5),
                include_superseded: false,
            },
        )
        .unwrap();
        assert!(
            staged_fact_hits.is_empty(),
            "staged facts must not appear as approved fact-tier results"
        );

        let preview = preview_promote_staged_memory(
            &paths,
            &MemoryConfig::default(),
            &staged.id,
            Some("notes/facts/production-db.md"),
            None,
        )
        .unwrap();
        promote_staged_memory(&paths, &MemoryConfig::default(), &preview).unwrap();
        let durable =
            fs::read_to_string(paths.memory.join("notes/facts/production-db.md")).unwrap();
        assert!(durable.contains("facts:"));
        assert!(durable.contains("fact_primary_database"));

        let fact_hits = search_memory(
            &paths,
            &MemoryConfig::default(),
            SearchMemoryInput {
                query: "Postgres".into(),
                tier: MemoryTier::Fact,
                limit: Some(5),
                include_superseded: false,
            },
        )
        .unwrap();
        assert_eq!(fact_hits.len(), 1);
        assert_eq!(fact_hits[0].tier, "fact");
        assert_eq!(
            fact_hits[0]
                .source
                .as_ref()
                .and_then(|source| source.get("kind"))
                .and_then(JsonValue::as_str),
            Some("durable_memory")
        );
    }

    #[test]
    fn fact_cap_and_superseded_filter_are_enforced() {
        let temp = TempRoot::new();
        let paths = temp.paths();
        paths.ensure().unwrap();
        let mut config = MemoryConfig::default();
        config.facts.max_facts_per_entry = 1;
        bootstrap_curated_memory(&paths, &config).unwrap();
        let err = stage_memory(
            &paths,
            &config,
            StageMemoryRequest {
                session_id: "fact-session".into(),
                turn_id: "turn-2".into(),
                agent: "allbert/root".into(),
                source: "channel".into(),
                content: "Two facts are too many for this profile.".into(),
                kind: StagedMemoryKind::LearnedFact,
                summary: "Too many facts".into(),
                tags: vec![],
                provenance: None,
                fingerprint_basis: None,
                facts: vec![
                    MemoryFact {
                        subject: "A".into(),
                        predicate: "is".into(),
                        object: "one".into(),
                        ..MemoryFact::default()
                    },
                    MemoryFact {
                        subject: "B".into(),
                        predicate: "is".into(),
                        object: "two".into(),
                        ..MemoryFact::default()
                    },
                ],
            },
        )
        .unwrap_err();
        assert!(err.to_string().contains("facts cap exceeded"));

        fs::create_dir_all(paths.memory_notes.join("facts")).unwrap();
        fs::write(
            paths.memory_notes.join("facts/supersession.md"),
            "---\nfacts:\n  - id: old_fact\n    subject: Preferred local database\n    predicate: was\n    object: SQLite\n  - id: new_fact\n    subject: Preferred local database\n    predicate: is\n    object: Postgres\n    supersedes:\n      - old_fact\n---\n\n# Preferred local database\n\nPostgres supersedes SQLite.\n",
        )
        .unwrap();
        rebuild_memory_index(&paths, &MemoryConfig::default(), true).unwrap();
        let current_only = search_memory(
            &paths,
            &MemoryConfig::default(),
            SearchMemoryInput {
                query: "SQLite".into(),
                tier: MemoryTier::Fact,
                limit: Some(5),
                include_superseded: false,
            },
        )
        .unwrap();
        assert!(current_only.is_empty());
        let with_superseded = search_memory(
            &paths,
            &MemoryConfig::default(),
            SearchMemoryInput {
                query: "SQLite".into(),
                tier: MemoryTier::Fact,
                limit: Some(5),
                include_superseded: true,
            },
        )
        .unwrap();
        assert_eq!(with_superseded.len(), 1);
    }

    #[test]
    fn semantic_disabled_config_makes_no_embedding_index() {
        let temp = TempRoot::new();
        let paths = temp.paths();
        paths.ensure().unwrap();
        fs::create_dir_all(paths.memory_notes.join("projects")).unwrap();
        fs::write(
            paths.memory_notes.join("projects/search.md"),
            "# Search\n\nBM25 remains the default retrieval engine.\n",
        )
        .unwrap();
        bootstrap_curated_memory(&paths, &MemoryConfig::default()).unwrap();
        let hits = search_memory(
            &paths,
            &MemoryConfig::default(),
            SearchMemoryInput {
                query: "BM25 retrieval".into(),
                tier: MemoryTier::Durable,
                limit: Some(5),
                include_superseded: false,
            },
        )
        .unwrap();
        assert_eq!(hits[0].path, "notes/projects/search.md");
        assert!(
            !paths.memory_index_dir.join("semantic").exists(),
            "disabled semantic config must not create a derived embedding index"
        );
    }

    #[test]
    fn semantic_fake_embeddings_are_stable_and_rebuildable() {
        let temp = TempRoot::new();
        let paths = temp.paths();
        paths.ensure().unwrap();
        fs::create_dir_all(paths.memory_notes.join("projects")).unwrap();
        fs::write(
            paths.memory_notes.join("projects/semantic.md"),
            "# Semantic Retrieval\n\nVector embeddings support semantic retrieval and hybrid search.\n",
        )
        .unwrap();
        fs::write(
            paths.memory_notes.join("projects/shell.md"),
            "# Shell Notes\n\nThe TUI status line shows model and token telemetry.\n",
        )
        .unwrap();
        let mut config = MemoryConfig::default();
        config.semantic.enabled = true;
        config.semantic.provider = "fake".into();
        config.semantic.embedding_model = "fake-test".into();
        config.semantic.hybrid_weight = 0.65;

        rebuild_memory_index(&paths, &config, true).unwrap();
        let semantic_dir = paths
            .memory_index_dir
            .join("semantic")
            .join("fake")
            .join("fake-test");
        let meta: SemanticIndexMeta =
            serde_json::from_str(&fs::read_to_string(semantic_dir.join("metadata.json")).unwrap())
                .unwrap();
        assert_eq!(meta.schema_version, SEMANTIC_SCHEMA_VERSION);
        assert_eq!(meta.provider, "fake");
        assert_eq!(meta.model, "fake-test");
        assert_eq!(meta.doc_count, 2);

        let first = search_memory(
            &paths,
            &config,
            SearchMemoryInput {
                query: "embedding hybrid retrieval".into(),
                tier: MemoryTier::Durable,
                limit: Some(2),
                include_superseded: false,
            },
        )
        .unwrap();
        let second = search_memory(
            &paths,
            &config,
            SearchMemoryInput {
                query: "embedding hybrid retrieval".into(),
                tier: MemoryTier::Durable,
                limit: Some(2),
                include_superseded: false,
            },
        )
        .unwrap();
        assert_eq!(
            first.iter().map(|hit| &hit.path).collect::<Vec<_>>(),
            second.iter().map(|hit| &hit.path).collect::<Vec<_>>()
        );
        assert_eq!(first[0].path, "notes/projects/semantic.md");

        fs::remove_dir_all(&semantic_dir).unwrap();
        let rebuilt = search_memory(
            &paths,
            &config,
            SearchMemoryInput {
                query: "embedding hybrid retrieval".into(),
                tier: MemoryTier::Durable,
                limit: Some(2),
                include_superseded: false,
            },
        )
        .unwrap();
        assert_eq!(rebuilt[0].path, "notes/projects/semantic.md");
        assert!(semantic_dir.join("documents.json").exists());
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
            fingerprint_basis: None,
            facts: Vec::new(),
        };
        stage_memory(&paths, &MemoryConfig::default(), request.clone()).unwrap();
        let err = stage_memory(&paths, &MemoryConfig::default(), request).unwrap_err();
        assert!(err.to_string().contains("duplicate"));
    }

    #[test]
    fn research_stage_memory_can_dedup_on_custom_fingerprint_basis() {
        let temp = TempRoot::new();
        let paths = temp.paths();
        paths.ensure().unwrap();
        bootstrap_curated_memory(&paths, &MemoryConfig::default()).unwrap();
        let request = StageMemoryRequest {
            session_id: "sess-5".into(),
            turn_id: "turn-1".into(),
            agent: "allbert/root".into(),
            source: "channel".into(),
            content: "First fetched body".into(),
            kind: StagedMemoryKind::Research,
            summary: "Remember this article".into(),
            tags: vec!["research".into()],
            provenance: Some(json!({"source_url": "https://example.com/article"})),
            fingerprint_basis: Some("Remember this article\nhttps://example.com/article".into()),
            facts: Vec::new(),
        };
        stage_memory(&paths, &MemoryConfig::default(), request.clone()).unwrap();

        let mut duplicate = request;
        duplicate.content = "Second fetched body with different text".into();
        let err = stage_memory(&paths, &MemoryConfig::default(), duplicate).unwrap_err();
        assert!(err.to_string().contains("duplicate"));
    }
}
