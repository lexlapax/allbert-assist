use std::collections::{BTreeMap, HashMap, HashSet, VecDeque};
use std::fs;
use std::net::{IpAddr, ToSocketAddrs};
use std::path::{Path, PathBuf};
use std::sync::atomic::{AtomicUsize, Ordering};
use std::thread;
use std::time::{Duration, Instant};

pub use allbert_kernel_core::rag::*;
use rusqlite::{params, Connection, OptionalExtension};
use serde::{Deserialize, Serialize};
use serde_json::json;
use sha2::{Digest, Sha256};
use uuid::Uuid;

use crate::{
    atomic_write, command_catalog, memory, security, settings_catalog, AllbertPaths, Config,
    KernelError, SettingDescriptor, SkillStore,
};

pub const RAG_SCHEMA_VERSION: u32 = 2;
static ACTIVE_VECTOR_QUERIES: AtomicUsize = AtomicUsize::new(0);
const RAG_REBUILD_CANCELLED: &str = "__rag_rebuild_cancelled__";
const SYSTEM_COLLECTION_KINDS: [RagSourceKind; 9] = [
    RagSourceKind::OperatorDocs,
    RagSourceKind::CommandCatalog,
    RagSourceKind::SettingsCatalog,
    RagSourceKind::SkillsMetadata,
    RagSourceKind::DurableMemory,
    RagSourceKind::FactMemory,
    RagSourceKind::EpisodeRecall,
    RagSourceKind::SessionSummary,
    RagSourceKind::StagedMemoryReview,
];

type SqliteExtensionInit = unsafe extern "C" fn(
    *mut rusqlite::ffi::sqlite3,
    *mut *mut std::ffi::c_char,
    *const rusqlite::ffi::sqlite3_api_routines,
) -> std::ffi::c_int;

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq, Eq)]
pub struct RagRebuildRequest {
    pub stale_only: bool,
    pub sources: Vec<RagSourceKind>,
    pub collection_type: Option<RagCollectionType>,
    pub collections: Vec<String>,
    pub include_vectors: bool,
    pub trigger: String,
}

impl Default for RagRebuildRequest {
    fn default() -> Self {
        Self {
            stale_only: true,
            sources: Vec::new(),
            collection_type: None,
            collections: Vec::new(),
            include_vectors: false,
            trigger: "operator-request".into(),
        }
    }
}

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq, Eq)]
pub struct RagRebuildSummary {
    pub run_id: String,
    pub status: RagIndexRunStatus,
    pub source_count: usize,
    pub chunk_count: usize,
    pub vector_count: usize,
    pub skipped_count: usize,
    pub elapsed_ms: u64,
    pub db_path: PathBuf,
    pub message: String,
}

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq, Eq)]
pub struct RagDoctorReport {
    pub ok: bool,
    pub db_path: PathBuf,
    pub db_exists: bool,
    pub schema_version: Option<String>,
    pub source_count: usize,
    pub chunk_count: usize,
    pub vector_count: usize,
    pub vector_posture: RagVectorPosture,
    pub issues: Vec<String>,
}

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq, Eq)]
pub struct RagGcSummary {
    pub dry_run: bool,
    pub orphan_chunks: usize,
    pub vacuumed: bool,
}

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq, Eq)]
pub struct RagCollectionMutationSummary {
    pub collection_type: RagCollectionType,
    pub collection_name: String,
    pub manifest_path: Option<PathBuf>,
    pub source_uris: Vec<String>,
    pub stale: bool,
    pub message: String,
}

#[derive(Debug, Clone)]
struct CollectedSource {
    collection_type: RagCollectionType,
    collection_name: String,
    kind: RagSourceKind,
    source_id: String,
    source_uri: String,
    source_path: Option<String>,
    title: String,
    tags: Vec<String>,
    text: String,
    privacy_tier: &'static str,
    prompt_eligible: bool,
    review_only: bool,
    ingest_state: &'static str,
    http_status: Option<i64>,
    http_etag: Option<String>,
    http_last_modified: Option<String>,
    http_content_type: Option<String>,
    final_url: Option<String>,
    robots_allowed: Option<bool>,
    last_error: Option<String>,
}

#[derive(Debug, Clone)]
struct RagChunk {
    chunk_id: String,
    ordinal: usize,
    title: String,
    heading_path: Option<String>,
    text: String,
    tags: Vec<String>,
    labels: Vec<String>,
    prompt_eligible: bool,
    review_only: bool,
    content_hash: String,
}

struct RunWrite<'a> {
    status: RagIndexRunStatus,
    source_count: usize,
    chunk_count: usize,
    vector_count: usize,
    skipped_count: usize,
    elapsed_ms: u64,
    error: Option<&'a str>,
}

#[derive(Debug, Clone)]
struct CollectionCatalogEntry {
    collection_type: RagCollectionType,
    collection_name: String,
    source_uri: String,
    title: String,
    description: String,
    privacy_tier: String,
    prompt_eligible: bool,
    review_only: bool,
    manifest_path: Option<String>,
    manifest_hash: String,
    fetch_policy_json: String,
}

#[derive(Debug, Clone, Copy)]
enum SourceUriKind {
    File,
    Dir,
    Web,
}

#[derive(Debug)]
struct EmbeddingError {
    message: String,
}

impl EmbeddingError {
    fn new(message: impl Into<String>) -> Self {
        Self {
            message: message.into(),
        }
    }
}

trait EmbeddingProvider {
    fn provider(&self) -> RagEmbeddingProvider;
    fn model(&self) -> &str;
    fn embed_batch(&self, inputs: &[String]) -> Result<Vec<Vec<f32>>, EmbeddingError>;

    fn model_key(&self, dimension: usize) -> String {
        format!("{}:{}:{dimension}", self.provider().label(), self.model())
    }
}

struct FakeEmbeddingProvider {
    model: String,
    dimension: usize,
}

struct OllamaEmbeddingProvider {
    model: String,
    base_url: String,
    timeout: Duration,
}

#[derive(Debug, Deserialize)]
struct OllamaEmbedResponse {
    embeddings: Vec<Vec<f32>>,
}

#[derive(Debug, Deserialize)]
struct OllamaTagsResponse {
    models: Vec<OllamaTagModel>,
}

#[derive(Debug, Deserialize)]
struct OllamaTagModel {
    name: String,
}

struct VectorQueryPermit;

impl Drop for VectorQueryPermit {
    fn drop(&mut self) {
        ACTIVE_VECTOR_QUERIES.fetch_sub(1, Ordering::AcqRel);
    }
}

pub fn sqlite_vec_dependency_probe() -> Result<String, rusqlite::Error> {
    register_sqlite_vec();
    let db = rusqlite::Connection::open_in_memory()?;
    db.query_row("select vec_version()", [], |row| row.get(0))
}

impl EmbeddingProvider for FakeEmbeddingProvider {
    fn provider(&self) -> RagEmbeddingProvider {
        RagEmbeddingProvider::Fake
    }

    fn model(&self) -> &str {
        &self.model
    }

    fn embed_batch(&self, inputs: &[String]) -> Result<Vec<Vec<f32>>, EmbeddingError> {
        Ok(inputs
            .iter()
            .map(|input| fake_embedding(input, self.dimension))
            .collect())
    }
}

impl EmbeddingProvider for OllamaEmbeddingProvider {
    fn provider(&self) -> RagEmbeddingProvider {
        RagEmbeddingProvider::Ollama
    }

    fn model(&self) -> &str {
        &self.model
    }

    fn embed_batch(&self, inputs: &[String]) -> Result<Vec<Vec<f32>>, EmbeddingError> {
        let model = self.model.clone();
        let base_url = self.base_url.clone();
        let timeout = self.timeout;
        let inputs = inputs.to_vec();
        run_blocking_http(
            move || ollama_embed_batch_blocking(model, base_url, timeout, inputs),
            EmbeddingError::new,
        )
    }
}

fn run_blocking_http<T, E, F, M>(work: F, map_panic: M) -> Result<T, E>
where
    T: Send + 'static,
    E: Send + 'static,
    F: FnOnce() -> Result<T, E> + Send + 'static,
    M: FnOnce(String) -> E,
{
    if tokio::runtime::Handle::try_current().is_ok() {
        thread::spawn(work)
            .join()
            .unwrap_or_else(|_| Err(map_panic("blocking HTTP worker panicked".into())))
    } else {
        work()
    }
}

fn ollama_embed_batch_blocking(
    model: String,
    base_url: String,
    timeout: Duration,
    inputs: Vec<String>,
) -> Result<Vec<Vec<f32>>, EmbeddingError> {
    let client = reqwest::blocking::Client::builder()
        .timeout(timeout)
        .build()
        .map_err(|e| EmbeddingError::new(format!("build Ollama client: {e}")))?;
    let url = format!("{}/api/embed", base_url.trim_end_matches('/'));
    let response = client
        .post(url)
        .json(&json!({
            "model": model,
            "input": inputs,
        }))
        .send()
        .and_then(|response| response.error_for_status())
        .map_err(|e| EmbeddingError::new(format!("Ollama embed request failed: {e}")))?;
    let parsed = response
        .json::<OllamaEmbedResponse>()
        .map_err(|e| EmbeddingError::new(format!("parse Ollama embed response: {e}")))?;
    if parsed.embeddings.len() != inputs.len() {
        return Err(EmbeddingError::new(format!(
            "Ollama returned {} embeddings for {} inputs",
            parsed.embeddings.len(),
            inputs.len()
        )));
    }
    Ok(parsed.embeddings)
}

pub fn rag_status(paths: &AllbertPaths, config: &Config) -> Result<RagStatusSnapshot, KernelError> {
    if !paths.rag_db.exists() {
        return Ok(RagStatusSnapshot {
            enabled: config.rag.enabled,
            mode: config.rag.mode,
            collection_count: 0,
            source_count: 0,
            chunk_count: 0,
            vector_count: 0,
            vector_posture: if config.rag.vector.enabled {
                RagVectorPosture::Unavailable
            } else {
                RagVectorPosture::Disabled
            },
            active_provider: Some(config.rag.vector.provider),
            active_model: Some(config.rag.vector.model.clone()),
            active_dimension: None,
            last_run_id: None,
            degraded_reason: Some("rag.sqlite is missing; run `allbert-cli rag rebuild`".into()),
        });
    }

    let conn = open_rag_db(paths)?;
    let collection_count = if table_exists(&conn, "rag_collections")? {
        count_table(&conn, "rag_collections")?
    } else {
        0
    };
    let source_count = count_table(&conn, "rag_sources")?;
    let chunk_count = count_table(&conn, "rag_chunks")?;
    let vector_count = if table_exists(&conn, "rag_embeddings")? {
        count_vectors(&conn)?
    } else {
        0
    };
    let active_dimension =
        get_meta(&conn, "embedding_dimension")?.and_then(|value| value.parse::<usize>().ok());
    let expected_key = active_dimension.map(|dimension| {
        format!(
            "{}:{}:{dimension}",
            config.rag.vector.provider.label(),
            config.rag.vector.model
        )
    });
    let stored_key = get_meta(&conn, "embedding_model_key")?;
    let vector_posture = if !config.rag.vector.enabled {
        RagVectorPosture::Disabled
    } else if vector_count == 0
        || active_dimension.is_none()
        || (expected_key.is_some() && stored_key != expected_key)
    {
        RagVectorPosture::Stale
    } else {
        RagVectorPosture::Healthy
    };
    let last_run_id = conn
        .query_row(
            "SELECT run_id FROM rag_index_runs ORDER BY started_at DESC LIMIT 1",
            [],
            |row| row.get(0),
        )
        .optional()
        .map_err(sql_err)?;
    Ok(RagStatusSnapshot {
        enabled: config.rag.enabled,
        mode: config.rag.mode,
        collection_count,
        source_count,
        chunk_count,
        vector_count,
        vector_posture,
        active_provider: Some(config.rag.vector.provider),
        active_model: Some(config.rag.vector.model.clone()),
        active_dimension,
        last_run_id,
        degraded_reason: if config.rag.vector.enabled && vector_posture != RagVectorPosture::Healthy
        {
            Some("vector index is missing or stale; run `allbert-cli rag rebuild --vectors`".into())
        } else {
            None
        },
    })
}

pub fn rebuild_rag_index(
    paths: &AllbertPaths,
    config: &Config,
    request: RagRebuildRequest,
) -> Result<RagRebuildSummary, KernelError> {
    rebuild_rag_index_inner(paths, config, request, None, &|| false)
}

pub fn rebuild_rag_index_with_control<F>(
    paths: &AllbertPaths,
    config: &Config,
    request: RagRebuildRequest,
    run_id: String,
    should_cancel: F,
) -> Result<RagRebuildSummary, KernelError>
where
    F: Fn() -> bool,
{
    rebuild_rag_index_inner(paths, config, request, Some(run_id), &should_cancel)
}

fn cancelled_rebuild_summary(
    paths: &AllbertPaths,
    run_id: String,
    source_count: usize,
    elapsed_ms: u64,
) -> RagRebuildSummary {
    RagRebuildSummary {
        run_id,
        status: RagIndexRunStatus::Cancelled,
        source_count,
        chunk_count: 0,
        vector_count: 0,
        skipped_count: 0,
        elapsed_ms,
        db_path: paths.rag_db.clone(),
        message: "RAG rebuild cancelled before publishing a new index".into(),
    }
}

fn record_cancelled_run_if_possible(
    paths: &AllbertPaths,
    run_id: &str,
    request: &RagRebuildRequest,
    requested_sources_json: &str,
    requested_collections_json: &str,
    source_count: usize,
    elapsed_ms: u64,
) -> Result<(), KernelError> {
    if !paths.rag_db.exists() {
        return Ok(());
    }
    let conn = open_rag_db(paths)?;
    insert_run(
        &conn,
        run_id,
        request,
        requested_sources_json,
        requested_collections_json,
        RunWrite {
            status: RagIndexRunStatus::Cancelled,
            source_count,
            chunk_count: 0,
            vector_count: 0,
            skipped_count: 0,
            elapsed_ms,
            error: Some("cancelled"),
        },
    )
}

fn rebuild_rag_index_inner<F>(
    paths: &AllbertPaths,
    config: &Config,
    request: RagRebuildRequest,
    run_id: Option<String>,
    should_cancel: &F,
) -> Result<RagRebuildSummary, KernelError>
where
    F: Fn() -> bool,
{
    paths.ensure()?;
    fs::create_dir_all(&paths.rag_index).map_err(|e| {
        KernelError::InitFailed(format!("create {}: {e}", paths.rag_index.display()))
    })?;

    let started = Instant::now();
    let run_id = run_id.unwrap_or_else(|| format!("rag-{}", Uuid::new_v4()));
    let sources = collect_sources(paths, config, &request)?;
    let corpus_hash = hash_sources(&sources);
    let requested_sources_json = serde_json::to_string(
        &request
            .sources
            .iter()
            .map(|source| source.label())
            .collect::<Vec<_>>(),
    )
    .map_err(|e| KernelError::InitFailed(format!("serialize requested sources: {e}")))?;
    let requested_collections_json = serde_json::to_string(&request.collections)
        .map_err(|e| KernelError::InitFailed(format!("serialize requested collections: {e}")))?;

    if should_cancel() {
        record_cancelled_run_if_possible(
            paths,
            &run_id,
            &request,
            &requested_sources_json,
            &requested_collections_json,
            sources.len(),
            started.elapsed().as_millis() as u64,
        )?;
        return Ok(cancelled_rebuild_summary(
            paths,
            run_id,
            sources.len(),
            started.elapsed().as_millis() as u64,
        ));
    }

    if request.stale_only && paths.rag_db.exists() {
        let conn = open_rag_db(paths)?;
        let previous = get_meta(&conn, "source_hash")?;
        let vectors_satisfied = !request.include_vectors
            || !config.rag.vector.enabled
            || vectors_current(&conn, config)?;
        if previous.as_deref() == Some(&corpus_hash) && vectors_satisfied {
            insert_run(
                &conn,
                &run_id,
                &request,
                &requested_sources_json,
                &requested_collections_json,
                RunWrite {
                    status: RagIndexRunStatus::Skipped,
                    source_count: sources.len(),
                    chunk_count: 0,
                    vector_count: 0,
                    skipped_count: sources.len(),
                    elapsed_ms: started.elapsed().as_millis() as u64,
                    error: Some("nothing_stale"),
                },
            )?;
            return Ok(RagRebuildSummary {
                run_id,
                status: RagIndexRunStatus::Skipped,
                source_count: sources.len(),
                chunk_count: 0,
                vector_count: 0,
                skipped_count: sources.len(),
                elapsed_ms: started.elapsed().as_millis() as u64,
                db_path: paths.rag_db.clone(),
                message: "nothing stale".into(),
            });
        }
    }

    let tmp = paths.rag_index.join(format!("{run_id}.sqlite.tmp"));
    if tmp.exists() {
        fs::remove_file(&tmp)
            .map_err(|e| KernelError::InitFailed(format!("remove {}: {e}", tmp.display())))?;
    }
    let mut conn = open_path(&tmp)?;
    init_schema(&conn)?;
    insert_run(
        &conn,
        &run_id,
        &request,
        &requested_sources_json,
        &requested_collections_json,
        RunWrite {
            status: RagIndexRunStatus::Running,
            source_count: 0,
            chunk_count: 0,
            vector_count: 0,
            skipped_count: 0,
            elapsed_ms: 0,
            error: None,
        },
    )?;

    let chunk_count = match write_sources(&mut conn, config, &sources, should_cancel) {
        Ok(chunk_count) => chunk_count,
        Err(KernelError::Request(message)) if message == RAG_REBUILD_CANCELLED => {
            finish_run(
                &conn,
                &run_id,
                RunWrite {
                    status: RagIndexRunStatus::Cancelled,
                    source_count: sources.len(),
                    chunk_count: 0,
                    vector_count: 0,
                    skipped_count: 0,
                    elapsed_ms: started.elapsed().as_millis() as u64,
                    error: Some("cancelled"),
                },
            )?;
            drop(conn);
            let _ = fs::remove_file(&tmp);
            record_cancelled_run_if_possible(
                paths,
                &run_id,
                &request,
                &requested_sources_json,
                &requested_collections_json,
                sources.len(),
                started.elapsed().as_millis() as u64,
            )?;
            return Ok(cancelled_rebuild_summary(
                paths,
                run_id,
                sources.len(),
                started.elapsed().as_millis() as u64,
            ));
        }
        Err(error) => return Err(error),
    };
    let mut vector_count = 0usize;
    let mut vector_note = String::new();
    if request.include_vectors && config.rag.vector.enabled {
        match index_vectors(&mut conn, config, should_cancel) {
            Ok(count) => {
                vector_count = count;
                vector_note = format!("; indexed {count} vectors");
            }
            Err(err) if err.message == RAG_REBUILD_CANCELLED => {
                finish_run(
                    &conn,
                    &run_id,
                    RunWrite {
                        status: RagIndexRunStatus::Cancelled,
                        source_count: sources.len(),
                        chunk_count,
                        vector_count,
                        skipped_count: 0,
                        elapsed_ms: started.elapsed().as_millis() as u64,
                        error: Some("cancelled"),
                    },
                )?;
                drop(conn);
                let _ = fs::remove_file(&tmp);
                record_cancelled_run_if_possible(
                    paths,
                    &run_id,
                    &request,
                    &requested_sources_json,
                    &requested_collections_json,
                    sources.len(),
                    started.elapsed().as_millis() as u64,
                )?;
                return Ok(cancelled_rebuild_summary(
                    paths,
                    run_id,
                    sources.len(),
                    started.elapsed().as_millis() as u64,
                ));
            }
            Err(err) => {
                vector_note = format!("; vector indexing skipped: {}", err.message);
                set_meta(&conn, "vector_posture", RagVectorPosture::Degraded.label())?;
                set_meta(&conn, "vector_degraded_reason", &err.message)?;
            }
        }
    } else {
        set_meta(&conn, "vector_posture", RagVectorPosture::Disabled.label())?;
    }
    set_meta(&conn, "schema_version", &RAG_SCHEMA_VERSION.to_string())?;
    set_meta(&conn, "source_hash", &corpus_hash)?;
    set_meta(
        &conn,
        "sqlite_vec_version",
        &sqlite_vec_dependency_probe().unwrap_or_default(),
    )?;
    if should_cancel() {
        finish_run(
            &conn,
            &run_id,
            RunWrite {
                status: RagIndexRunStatus::Cancelled,
                source_count: sources.len(),
                chunk_count,
                vector_count,
                skipped_count: 0,
                elapsed_ms: started.elapsed().as_millis() as u64,
                error: Some("cancelled"),
            },
        )?;
        drop(conn);
        let _ = fs::remove_file(&tmp);
        record_cancelled_run_if_possible(
            paths,
            &run_id,
            &request,
            &requested_sources_json,
            &requested_collections_json,
            sources.len(),
            started.elapsed().as_millis() as u64,
        )?;
        return Ok(cancelled_rebuild_summary(
            paths,
            run_id,
            sources.len(),
            started.elapsed().as_millis() as u64,
        ));
    }
    finish_run(
        &conn,
        &run_id,
        RunWrite {
            status: RagIndexRunStatus::Succeeded,
            source_count: sources.len(),
            chunk_count,
            vector_count,
            skipped_count: 0,
            elapsed_ms: started.elapsed().as_millis() as u64,
            error: None,
        },
    )?;
    drop(conn);

    fs::rename(&tmp, &paths.rag_db).map_err(|e| {
        KernelError::InitFailed(format!(
            "replace {} with {}: {e}",
            paths.rag_db.display(),
            tmp.display()
        ))
    })?;

    Ok(RagRebuildSummary {
        run_id,
        status: RagIndexRunStatus::Succeeded,
        source_count: sources.len(),
        chunk_count,
        vector_count,
        skipped_count: 0,
        elapsed_ms: started.elapsed().as_millis() as u64,
        db_path: paths.rag_db.clone(),
        message: format!("lexical RAG rebuilt{vector_note}"),
    })
}

pub fn search_rag(
    paths: &AllbertPaths,
    config: &Config,
    request: RagSearchRequest,
) -> Result<RagSearchResponse, KernelError> {
    if !paths.rag_db.exists() {
        return Ok(RagSearchResponse {
            query: request.query,
            mode: request.mode.unwrap_or(config.rag.mode),
            vector_posture: RagVectorPosture::Unavailable,
            degraded_reason: Some("rag.sqlite is missing; run `allbert-cli rag rebuild`".into()),
            results: Vec::new(),
        });
    }
    let conn = open_rag_db(paths)?;
    let requested_mode = request.mode.unwrap_or(config.rag.mode);
    let limit = request.limit.unwrap_or(10).clamp(1, 50);
    let match_expr = fts_match_expression(&request.query);
    if match_expr.is_empty() {
        return Ok(RagSearchResponse {
            query: request.query,
            mode: requested_mode,
            vector_posture: RagVectorPosture::Disabled,
            degraded_reason: None,
            results: Vec::new(),
        });
    }
    let lexical = lexical_search(&conn, config, &request, &match_expr, limit * 4)?;
    let vector_attempt = if matches!(
        requested_mode,
        RagRetrievalMode::Hybrid | RagRetrievalMode::Vector
    ) && config.rag.vector.enabled
    {
        vector_search(&conn, config, &request, limit * 4).map_err(|err| err.message)
    } else {
        Err("vectors disabled".into())
    };

    let (mode, vector_posture, degraded_reason, results) = match (requested_mode, vector_attempt) {
        (RagRetrievalMode::Vector, Ok(vector)) => (
            RagRetrievalMode::Vector,
            RagVectorPosture::Healthy,
            None,
            cap_results(vector, limit),
        ),
        (RagRetrievalMode::Hybrid, Ok(vector)) => (
            RagRetrievalMode::Hybrid,
            RagVectorPosture::Healthy,
            None,
            fuse_hybrid(
                lexical,
                vector,
                config.rag.vector.fusion_vector_weight,
                limit,
            ),
        ),
        (RagRetrievalMode::Hybrid, Err(reason)) if reason == "vectors disabled" => (
            RagRetrievalMode::Lexical,
            RagVectorPosture::Disabled,
            None,
            cap_results(lexical, limit),
        ),
        (RagRetrievalMode::Vector, Err(reason))
            if reason == "vectors disabled" && config.rag.vector.fallback_to_lexical =>
        {
            (
                RagRetrievalMode::Lexical,
                RagVectorPosture::Disabled,
                Some("vector search disabled; used lexical fallback".into()),
                cap_results(lexical, limit),
            )
        }
        (RagRetrievalMode::Vector, Err(reason)) if config.rag.vector.fallback_to_lexical => (
            RagRetrievalMode::Lexical,
            RagVectorPosture::Degraded,
            Some(format!(
                "vector search degraded: {reason}; used lexical fallback"
            )),
            cap_results(lexical, limit),
        ),
        (RagRetrievalMode::Hybrid, Err(reason)) => (
            RagRetrievalMode::Lexical,
            RagVectorPosture::Degraded,
            Some(format!(
                "vector search degraded: {reason}; used lexical fallback"
            )),
            cap_results(lexical, limit),
        ),
        (RagRetrievalMode::Vector, Err(reason)) => (
            RagRetrievalMode::Vector,
            RagVectorPosture::Degraded,
            Some(format!("vector search degraded: {reason}")),
            Vec::new(),
        ),
        (RagRetrievalMode::Lexical, _) => (
            RagRetrievalMode::Lexical,
            RagVectorPosture::Disabled,
            None,
            cap_results(lexical, limit),
        ),
    };

    record_rag_access(&conn, &results)?;
    Ok(RagSearchResponse {
        query: request.query,
        mode,
        vector_posture,
        degraded_reason,
        results,
    })
}

pub fn rag_doctor(paths: &AllbertPaths, config: &Config) -> Result<RagDoctorReport, KernelError> {
    let db_exists = paths.rag_db.exists();
    let mut issues = Vec::new();
    if !db_exists {
        issues.push("rag.sqlite is missing; run `allbert-cli rag rebuild`".into());
        return Ok(RagDoctorReport {
            ok: false,
            db_path: paths.rag_db.clone(),
            db_exists,
            schema_version: None,
            source_count: 0,
            chunk_count: 0,
            vector_count: 0,
            vector_posture: RagVectorPosture::Unavailable,
            issues,
        });
    }
    let conn = open_rag_db(paths)?;
    let schema_version = get_meta(&conn, "schema_version")?;
    if schema_version.as_deref() != Some(&RAG_SCHEMA_VERSION.to_string()) {
        issues.push(format!(
            "schema_version is {}; expected {}",
            schema_version.as_deref().unwrap_or("missing"),
            RAG_SCHEMA_VERSION
        ));
    }
    let source_count = count_table(&conn, "rag_sources")?;
    let chunk_count = count_table(&conn, "rag_chunks")?;
    if source_count == 0 {
        issues.push("no RAG sources indexed".into());
    }
    if chunk_count == 0 {
        issues.push("no RAG chunks indexed".into());
    }
    let vector_count = if table_exists(&conn, "rag_embeddings")? {
        count_vectors(&conn)?
    } else {
        0
    };
    let vector_posture = if !config.rag.vector.enabled {
        RagVectorPosture::Disabled
    } else if !table_exists(&conn, "rag_embeddings")? {
        issues.push("vector table is missing; run `allbert-cli rag rebuild --vectors`".into());
        RagVectorPosture::Stale
    } else if vector_count == 0 {
        issues.push("vector table is empty; run `allbert-cli rag rebuild --vectors`".into());
        RagVectorPosture::Stale
    } else if !vectors_current(&conn, config)? {
        issues.push(
            "vector metadata is stale for the configured provider/model; rebuild vectors".into(),
        );
        RagVectorPosture::Stale
    } else if let Err(issue) = check_embedding_provider(config) {
        issues.push(issue);
        RagVectorPosture::Degraded
    } else {
        RagVectorPosture::Healthy
    };
    Ok(RagDoctorReport {
        ok: issues.is_empty(),
        db_path: paths.rag_db.clone(),
        db_exists,
        schema_version,
        source_count,
        chunk_count,
        vector_count,
        vector_posture,
        issues,
    })
}

pub fn rag_gc(paths: &AllbertPaths, dry_run: bool) -> Result<RagGcSummary, KernelError> {
    if !paths.rag_db.exists() {
        return Ok(RagGcSummary {
            dry_run,
            orphan_chunks: 0,
            vacuumed: false,
        });
    }
    let conn = open_rag_db(paths)?;
    let orphan_chunks: usize = conn
        .query_row(
            "SELECT COUNT(*) FROM rag_chunks
             WHERE source_fk NOT IN (SELECT id FROM rag_sources)",
            [],
            |row| row.get::<_, i64>(0),
        )
        .map_err(sql_err)? as usize;
    let mut vacuumed = false;
    if !dry_run {
        conn.execute(
            "DELETE FROM rag_chunks
             WHERE source_fk NOT IN (SELECT id FROM rag_sources)",
            [],
        )
        .map_err(sql_err)?;
        conn.execute_batch("VACUUM").map_err(sql_err)?;
        vacuumed = true;
    }
    Ok(RagGcSummary {
        dry_run,
        orphan_chunks,
        vacuumed,
    })
}

fn lexical_search(
    conn: &Connection,
    config: &Config,
    request: &RagSearchRequest,
    match_expr: &str,
    limit: usize,
) -> Result<Vec<RagSearchResult>, KernelError> {
    let allowed_sources = request
        .sources
        .iter()
        .map(|source| source.label().to_string())
        .collect::<Vec<_>>();
    let mut stmt = conn
        .prepare(
            "SELECT c.chunk_id, c.title, c.text, c.source_kind, s.source_id,
                    s.source_path, c.collection_type, c.collection_name,
                    bm25(rag_chunks_fts) AS rank
             FROM rag_chunks_fts
             JOIN rag_chunks c ON c.id = rag_chunks_fts.rowid
             JOIN rag_sources s ON s.id = c.source_fk
             WHERE rag_chunks_fts MATCH ?1
               AND (?2 OR c.review_only = 0)
             ORDER BY rank
             LIMIT ?3",
        )
        .map_err(sql_err)?;
    let rows = stmt
        .query_map(
            params![match_expr, request.include_review_only, limit as i64],
            |row| {
                let source_kind: String = row.get(3)?;
                Ok((
                    row.get::<_, String>(0)?,
                    row.get::<_, String>(1)?,
                    row.get::<_, String>(2)?,
                    source_kind,
                    row.get::<_, String>(4)?,
                    row.get::<_, Option<String>>(5)?,
                    row.get::<_, String>(6)?,
                    row.get::<_, String>(7)?,
                    row.get::<_, f64>(8)?,
                ))
            },
        )
        .map_err(sql_err)?;

    let mut results = Vec::new();
    for row in rows {
        let (
            chunk_id,
            title,
            text,
            source_kind,
            source_id,
            path,
            collection_type,
            collection_name,
            rank,
        ) = row.map_err(sql_err)?;
        if !allowed_sources.is_empty() && !allowed_sources.iter().any(|kind| kind == &source_kind) {
            continue;
        }
        let Some(kind) = RagSourceKind::parse(&source_kind) else {
            continue;
        };
        let Some(collection_type) = RagCollectionType::parse(&collection_type) else {
            continue;
        };
        if !collection_allowed(request, collection_type, &collection_name) {
            continue;
        }
        results.push(RagSearchResult {
            collection_type,
            collection_name,
            source_kind: kind,
            source_id,
            chunk_id,
            title,
            path,
            snippet: truncate_to_bytes(text.trim(), config.rag.max_chunk_bytes),
            mode: RagRetrievalMode::Lexical,
            score: -rank,
            vector_posture: RagVectorPosture::Disabled,
            score_explanation: Some("sqlite fts bm25".into()),
        });
    }
    Ok(results)
}

fn vector_search(
    conn: &Connection,
    config: &Config,
    request: &RagSearchRequest,
    limit: usize,
) -> Result<Vec<RagSearchResult>, EmbeddingError> {
    if !table_exists(conn, "rag_embeddings").map_err(|e| EmbeddingError::new(e.to_string()))? {
        return Err(EmbeddingError::new("rag_embeddings table is missing"));
    }
    let dimension = get_meta(conn, "embedding_dimension")
        .map_err(|e| EmbeddingError::new(e.to_string()))?
        .and_then(|value| value.parse::<usize>().ok())
        .ok_or_else(|| EmbeddingError::new("embedding dimension metadata is missing"))?;
    let expected_key = format!(
        "{}:{}:{dimension}",
        config.rag.vector.provider.label(),
        config.rag.vector.model
    );
    let stored_key =
        get_meta(conn, "embedding_model_key").map_err(|e| EmbeddingError::new(e.to_string()))?;
    if stored_key.as_deref() != Some(expected_key.as_str()) {
        return Err(EmbeddingError::new("embedding model key is stale"));
    }
    let _permit = acquire_vector_query_permit(config.rag.vector.max_concurrent_queries)?;
    let provider = embedding_provider(
        config,
        Duration::from_secs(config.rag.vector.query_timeout_s),
    );
    let query = truncate_to_bytes(&request.query, config.rag.vector.max_query_bytes);
    let embedding = embed_with_retry(provider.as_ref(), &[query], config)?
        .into_iter()
        .next()
        .ok_or_else(|| EmbeddingError::new("embedding provider returned no query vector"))?;
    if embedding.len() != dimension {
        return Err(EmbeddingError::new(format!(
            "query dimension {} does not match stored dimension {dimension}",
            embedding.len()
        )));
    }
    let allowed_sources = request
        .sources
        .iter()
        .map(|source| source.label().to_string())
        .collect::<Vec<_>>();
    let blob = vector_blob(&embedding);
    let mut stmt = conn
        .prepare(
            "WITH knn AS (
               SELECT rowid, distance
               FROM rag_embeddings
               WHERE embedding MATCH ?1 AND k = ?2
               ORDER BY distance
             )
             SELECT c.chunk_id, c.title, c.text, c.source_kind, s.source_id,
                    s.source_path, c.collection_type, c.collection_name,
                    knn.distance
             FROM knn
             JOIN rag_chunks c ON c.id = knn.rowid
             JOIN rag_sources s ON s.id = c.source_fk
             WHERE (?3 OR c.review_only = 0)
             ORDER BY knn.distance",
        )
        .map_err(|e| EmbeddingError::new(format!("prepare vector search: {e}")))?;
    let rows = stmt
        .query_map(
            params![blob, limit as i64, request.include_review_only],
            |row| {
                let source_kind: String = row.get(3)?;
                Ok((
                    row.get::<_, String>(0)?,
                    row.get::<_, String>(1)?,
                    row.get::<_, String>(2)?,
                    source_kind,
                    row.get::<_, String>(4)?,
                    row.get::<_, Option<String>>(5)?,
                    row.get::<_, String>(6)?,
                    row.get::<_, String>(7)?,
                    row.get::<_, f64>(8)?,
                ))
            },
        )
        .map_err(|e| EmbeddingError::new(format!("query vector search: {e}")))?;
    let mut results = Vec::new();
    for row in rows {
        let (
            chunk_id,
            title,
            text,
            source_kind,
            source_id,
            path,
            collection_type,
            collection_name,
            distance,
        ) = row.map_err(|e| EmbeddingError::new(format!("read vector row: {e}")))?;
        if !allowed_sources.is_empty() && !allowed_sources.iter().any(|kind| kind == &source_kind) {
            continue;
        }
        let Some(kind) = RagSourceKind::parse(&source_kind) else {
            continue;
        };
        let Some(collection_type) = RagCollectionType::parse(&collection_type) else {
            continue;
        };
        if !collection_allowed(request, collection_type, &collection_name) {
            continue;
        }
        results.push(RagSearchResult {
            collection_type,
            collection_name,
            source_kind: kind,
            source_id,
            chunk_id,
            title,
            path,
            snippet: truncate_to_bytes(text.trim(), config.rag.max_chunk_bytes),
            mode: RagRetrievalMode::Vector,
            score: 1.0 / (1.0 + distance.max(0.0)),
            vector_posture: RagVectorPosture::Healthy,
            score_explanation: Some(format!("sqlite-vec cosine distance {distance:.6}")),
        });
    }
    Ok(results)
}

fn cap_results(mut results: Vec<RagSearchResult>, limit: usize) -> Vec<RagSearchResult> {
    results.truncate(limit);
    results
}

fn record_rag_access(conn: &Connection, results: &[RagSearchResult]) -> Result<(), KernelError> {
    if results.is_empty() {
        return Ok(());
    }
    let now = chrono::Utc::now().to_rfc3339();
    let mut seen_collections = HashSet::new();
    let mut seen_sources = HashSet::new();
    for result in results {
        if seen_collections.insert((
            result.collection_type.label().to_string(),
            result.collection_name.clone(),
        )) {
            conn.execute(
                "UPDATE rag_collections
                 SET last_accessed_at = ?3
                 WHERE collection_type = ?1 AND collection_name = ?2",
                params![
                    result.collection_type.label(),
                    result.collection_name.as_str(),
                    now.as_str(),
                ],
            )
            .map_err(sql_err)?;
        }
        if seen_sources.insert((
            result.collection_type.label().to_string(),
            result.collection_name.clone(),
            result.source_kind.label().to_string(),
            result.source_id.clone(),
        )) {
            conn.execute(
                "UPDATE rag_sources
                 SET last_accessed_at = ?5
                 WHERE collection_fk = (
                   SELECT id FROM rag_collections
                   WHERE collection_type = ?1 AND collection_name = ?2
                 )
                   AND source_kind = ?3
                   AND source_id = ?4",
                params![
                    result.collection_type.label(),
                    result.collection_name.as_str(),
                    result.source_kind.label(),
                    result.source_id.as_str(),
                    now.as_str(),
                ],
            )
            .map_err(sql_err)?;
        }
    }
    Ok(())
}

fn collection_allowed(
    request: &RagSearchRequest,
    collection_type: RagCollectionType,
    collection_name: &str,
) -> bool {
    if request
        .collection_type
        .is_some_and(|wanted| wanted != collection_type)
    {
        return false;
    }
    if request.collections.is_empty() {
        return true;
    }
    let normalized = normalize_collection_name(collection_name);
    request
        .collections
        .iter()
        .any(|wanted| normalize_collection_name(wanted) == normalized)
}

fn fuse_hybrid(
    lexical: Vec<RagSearchResult>,
    vector: Vec<RagSearchResult>,
    vector_weight: f64,
    limit: usize,
) -> Vec<RagSearchResult> {
    let mut fused: HashMap<String, (RagSearchResult, f64)> = HashMap::new();
    for (idx, result) in lexical.into_iter().enumerate() {
        let score = (1.0 - vector_weight) / (60.0 + idx as f64 + 1.0);
        fused
            .entry(result.chunk_id.clone())
            .and_modify(|(_, total)| *total += score)
            .or_insert((result, score));
    }
    for (idx, mut result) in vector.into_iter().enumerate() {
        let score = vector_weight / (60.0 + idx as f64 + 1.0);
        result.mode = RagRetrievalMode::Hybrid;
        result.score_explanation = Some("hybrid reciprocal-rank fusion".into());
        fused
            .entry(result.chunk_id.clone())
            .and_modify(|(existing, total)| {
                existing.mode = RagRetrievalMode::Hybrid;
                existing.vector_posture = RagVectorPosture::Healthy;
                existing.score_explanation = Some("hybrid reciprocal-rank fusion".into());
                *total += score;
            })
            .or_insert((result, score));
    }
    let mut results = fused
        .into_values()
        .map(|(mut result, score)| {
            result.score = score;
            result
        })
        .collect::<Vec<_>>();
    results.sort_by(|a, b| {
        b.score
            .partial_cmp(&a.score)
            .unwrap_or(std::cmp::Ordering::Equal)
    });
    results.truncate(limit);
    results
}

fn index_vectors<F>(
    conn: &mut Connection,
    config: &Config,
    should_cancel: &F,
) -> Result<usize, EmbeddingError>
where
    F: Fn() -> bool,
{
    let mut stmt = conn
        .prepare(
            "SELECT id, text
             FROM rag_chunks
             ORDER BY id
             LIMIT ?1",
        )
        .map_err(|e| EmbeddingError::new(format!("prepare vector chunk scan: {e}")))?;
    let rows = stmt
        .query_map(params![config.rag.index.max_chunks_per_run as i64], |row| {
            Ok((row.get::<_, i64>(0)?, row.get::<_, String>(1)?))
        })
        .map_err(|e| EmbeddingError::new(format!("query vector chunks: {e}")))?;
    let mut chunks = Vec::new();
    for row in rows {
        chunks.push(row.map_err(|e| EmbeddingError::new(format!("read vector chunk: {e}")))?);
    }
    drop(stmt);

    if chunks.is_empty() {
        set_meta(conn, "vector_posture", RagVectorPosture::Disabled.label())
            .map_err(|e| EmbeddingError::new(e.to_string()))?;
        return Ok(0);
    }

    let provider = embedding_provider(
        config,
        Duration::from_secs(config.rag.vector.index_timeout_s),
    );
    let mut indexed = Vec::with_capacity(chunks.len());
    let mut dimension = None;
    for batch in chunks.chunks(config.rag.vector.batch_size) {
        if should_cancel() {
            return Err(EmbeddingError::new(RAG_REBUILD_CANCELLED));
        }
        let inputs = batch
            .iter()
            .map(|(_, text)| truncate_to_bytes(text, config.rag.vector.max_query_bytes))
            .collect::<Vec<_>>();
        let embeddings = embed_with_retry(provider.as_ref(), &inputs, config)?;
        if embeddings.len() != batch.len() {
            return Err(EmbeddingError::new(format!(
                "embedding provider returned {} vectors for {} chunks",
                embeddings.len(),
                batch.len()
            )));
        }
        for ((rowid, _), embedding) in batch.iter().zip(embeddings) {
            if embedding.is_empty() {
                return Err(EmbeddingError::new(
                    "embedding provider returned an empty vector",
                ));
            }
            match dimension {
                Some(expected) if embedding.len() != expected => {
                    return Err(EmbeddingError::new(format!(
                        "embedding dimension changed from {expected} to {}",
                        embedding.len()
                    )));
                }
                None => dimension = Some(embedding.len()),
                _ => {}
            }
            indexed.push((*rowid, normalize_vector(embedding)));
        }
    }

    let dimension =
        dimension.ok_or_else(|| EmbeddingError::new("embedding provider returned no vectors"))?;
    create_vector_table(conn, dimension)?;
    let model_key = provider.model_key(dimension);
    let tx = conn
        .transaction()
        .map_err(|e| EmbeddingError::new(format!("begin vector transaction: {e}")))?;
    {
        let mut insert = tx
            .prepare("INSERT INTO rag_embeddings(rowid, embedding) VALUES (?1, ?2)")
            .map_err(|e| EmbeddingError::new(format!("prepare vector insert: {e}")))?;
        let mut update = tx
            .prepare(
                "UPDATE rag_chunks
                 SET embedding_model_key = ?1,
                     embedding_state = 'indexed',
                     updated_at = ?2
                 WHERE id = ?3",
            )
            .map_err(|e| EmbeddingError::new(format!("prepare chunk vector update: {e}")))?;
        let now = chrono::Utc::now().to_rfc3339();
        for (rowid, embedding) in &indexed {
            if should_cancel() {
                return Err(EmbeddingError::new(RAG_REBUILD_CANCELLED));
            }
            insert
                .execute(params![rowid, vector_blob(embedding)])
                .map_err(|e| EmbeddingError::new(format!("insert vector row {rowid}: {e}")))?;
            update
                .execute(params![model_key, now, rowid])
                .map_err(|e| EmbeddingError::new(format!("mark chunk {rowid} vectorized: {e}")))?;
        }
    }
    tx.commit()
        .map_err(|e| EmbeddingError::new(format!("commit vector transaction: {e}")))?;

    set_meta(conn, "embedding_provider", provider.provider().label())
        .map_err(|e| EmbeddingError::new(e.to_string()))?;
    set_meta(conn, "embedding_model", provider.model())
        .map_err(|e| EmbeddingError::new(e.to_string()))?;
    set_meta(conn, "embedding_dimension", &dimension.to_string())
        .map_err(|e| EmbeddingError::new(e.to_string()))?;
    set_meta(conn, "embedding_model_key", &provider.model_key(dimension))
        .map_err(|e| EmbeddingError::new(e.to_string()))?;
    set_meta(conn, "vector_posture", RagVectorPosture::Healthy.label())
        .map_err(|e| EmbeddingError::new(e.to_string()))?;
    set_meta(conn, "vector_degraded_reason", "").map_err(|e| EmbeddingError::new(e.to_string()))?;
    Ok(indexed.len())
}

fn embedding_provider(config: &Config, timeout: Duration) -> Box<dyn EmbeddingProvider> {
    match config.rag.vector.provider {
        RagEmbeddingProvider::Fake => Box::new(FakeEmbeddingProvider {
            model: config.rag.vector.model.clone(),
            dimension: fake_dimension_for_model(&config.rag.vector.model),
        }),
        RagEmbeddingProvider::Ollama => Box::new(OllamaEmbeddingProvider {
            model: config.rag.vector.model.clone(),
            base_url: config.rag.vector.base_url.clone(),
            timeout,
        }),
    }
}

fn embed_with_retry(
    provider: &dyn EmbeddingProvider,
    inputs: &[String],
    config: &Config,
) -> Result<Vec<Vec<f32>>, EmbeddingError> {
    let attempts = usize::from(config.rag.vector.retry_attempts) + 1;
    let mut last = None;
    for attempt in 0..attempts {
        match provider.embed_batch(inputs) {
            Ok(vectors) => return Ok(vectors),
            Err(err) => last = Some(err),
        }
        if attempt + 1 < attempts {
            thread::sleep(Duration::from_millis(100 * (attempt as u64 + 1)));
        }
    }
    Err(last.unwrap_or_else(|| EmbeddingError::new("embedding failed without an error")))
}

fn create_vector_table(conn: &Connection, dimension: usize) -> Result<(), EmbeddingError> {
    register_sqlite_vec();
    conn.execute("DROP TABLE IF EXISTS rag_embeddings", [])
        .map_err(|e| EmbeddingError::new(format!("drop stale vector table: {e}")))?;
    conn.execute(
        &format!(
            "CREATE VIRTUAL TABLE rag_embeddings
             USING vec0(embedding float[{dimension}] distance_metric=cosine)"
        ),
        [],
    )
    .map_err(|e| EmbeddingError::new(format!("create vector table: {e}")))?;
    Ok(())
}

fn vectors_current(conn: &Connection, config: &Config) -> Result<bool, KernelError> {
    if !table_exists(conn, "rag_embeddings")? || count_vectors(conn)? == 0 {
        return Ok(false);
    }
    let Some(dimension) =
        get_meta(conn, "embedding_dimension")?.and_then(|value| value.parse::<usize>().ok())
    else {
        return Ok(false);
    };
    let expected_key = format!(
        "{}:{}:{dimension}",
        config.rag.vector.provider.label(),
        config.rag.vector.model
    );
    Ok(get_meta(conn, "embedding_model_key")?.as_deref() == Some(expected_key.as_str()))
}

fn table_exists(conn: &Connection, table: &str) -> Result<bool, KernelError> {
    raw_table_exists(conn, table)
}

fn raw_table_exists(conn: &Connection, table: &str) -> Result<bool, KernelError> {
    conn.query_row(
        "SELECT EXISTS(
           SELECT 1
           FROM sqlite_master
           WHERE name = ?1 AND type IN ('table', 'virtual table')
         )",
        [table],
        |row| row.get::<_, i64>(0),
    )
    .map(|value| value != 0)
    .map_err(sql_err)
}

fn raw_column_exists(conn: &Connection, table: &str, column: &str) -> Result<bool, KernelError> {
    let mut stmt = conn
        .prepare(&format!("PRAGMA table_info({})", table.replace('"', "")))
        .map_err(sql_err)?;
    let rows = stmt
        .query_map([], |row| row.get::<_, String>(1))
        .map_err(sql_err)?;
    for row in rows {
        if row.map_err(sql_err)? == column {
            return Ok(true);
        }
    }
    Ok(false)
}

fn count_vectors(conn: &Connection) -> Result<usize, KernelError> {
    conn.query_row("SELECT COUNT(*) FROM rag_embeddings", [], |row| {
        row.get::<_, i64>(0)
    })
    .map(|value| value as usize)
    .map_err(sql_err)
}

fn vector_blob(vector: &[f32]) -> Vec<u8> {
    let mut blob = Vec::with_capacity(std::mem::size_of_val(vector));
    for value in vector {
        blob.extend_from_slice(&value.to_le_bytes());
    }
    blob
}

fn normalize_vector(mut vector: Vec<f32>) -> Vec<f32> {
    let norm = vector
        .iter()
        .map(|value| f64::from(*value) * f64::from(*value))
        .sum::<f64>()
        .sqrt();
    if norm > 0.0 {
        for value in &mut vector {
            *value = (f64::from(*value) / norm) as f32;
        }
    }
    vector
}

fn fake_embedding(input: &str, dimension: usize) -> Vec<f32> {
    let dimension = dimension.max(1);
    let mut vector = vec![0.0f32; dimension];
    for token in input
        .split(|ch: char| !ch.is_ascii_alphanumeric())
        .filter(|token| !token.is_empty())
    {
        let mut hasher = Sha256::new();
        hasher.update(token.to_ascii_lowercase().as_bytes());
        let digest = hasher.finalize();
        let mut bytes = [0u8; 8];
        bytes.copy_from_slice(&digest[..8]);
        let idx = u64::from_le_bytes(bytes) as usize % dimension;
        vector[idx] += 1.0;
    }
    if vector.iter().all(|value| *value == 0.0) {
        vector[0] = 1.0;
    }
    normalize_vector(vector)
}

fn fake_dimension_for_model(model: &str) -> usize {
    model
        .rsplit_once('-')
        .and_then(|(_, suffix)| suffix.strip_suffix('d').unwrap_or(suffix).parse().ok())
        .unwrap_or(8)
}

fn acquire_vector_query_permit(max_concurrent: usize) -> Result<VectorQueryPermit, EmbeddingError> {
    loop {
        let current = ACTIVE_VECTOR_QUERIES.load(Ordering::Acquire);
        if current >= max_concurrent {
            return Err(EmbeddingError::new(format!(
                "vector query concurrency limit reached ({max_concurrent})"
            )));
        }
        if ACTIVE_VECTOR_QUERIES
            .compare_exchange(current, current + 1, Ordering::AcqRel, Ordering::Acquire)
            .is_ok()
        {
            return Ok(VectorQueryPermit);
        }
    }
}

fn check_embedding_provider(config: &Config) -> Result<(), String> {
    match config.rag.vector.provider {
        RagEmbeddingProvider::Fake => Ok(()),
        RagEmbeddingProvider::Ollama => check_ollama_model(config),
    }
}

fn check_ollama_model(config: &Config) -> Result<(), String> {
    let base_url = config.rag.vector.base_url.clone();
    let model = config.rag.vector.model.clone();
    let timeout = Duration::from_secs(config.rag.vector.query_timeout_s);
    let tags = run_blocking_http(
        move || ollama_tags_blocking(base_url, model, timeout),
        std::convert::identity,
    )?;
    let wanted = config.rag.vector.model.as_str();
    if tags
        .models
        .iter()
        .any(|model| model.name == wanted || model.name.split(':').next() == Some(wanted))
    {
        Ok(())
    } else {
        Err(format!(
            "Ollama model `{}` is missing; run `ollama pull {}`",
            config.rag.vector.model, config.rag.vector.model
        ))
    }
}

fn ollama_tags_blocking(
    base_url: String,
    model: String,
    timeout: Duration,
) -> Result<OllamaTagsResponse, String> {
    let client = reqwest::blocking::Client::builder()
        .timeout(timeout)
        .build()
        .map_err(|e| format!("build Ollama client: {e}"))?;
    let url = format!("{}/api/tags", base_url.trim_end_matches('/'));
    client
        .get(url)
        .send()
        .and_then(|response| response.error_for_status())
        .map_err(|e| {
            format!(
                "Ollama is not reachable for RAG vectors at {base_url}; start Ollama and run `ollama pull {model}` ({e})"
            )
        })?
        .json::<OllamaTagsResponse>()
        .map_err(|e| format!("parse Ollama tags response: {e}"))
}

fn open_rag_db(paths: &AllbertPaths) -> Result<Connection, KernelError> {
    let conn = open_path(&paths.rag_db)?;
    init_schema(&conn)?;
    Ok(conn)
}

fn open_path(path: &Path) -> Result<Connection, KernelError> {
    register_sqlite_vec();
    let conn = Connection::open(path)
        .map_err(|e| KernelError::InitFailed(format!("open {}: {e}", path.display())))?;
    conn.pragma_update(None, "journal_mode", "WAL")
        .map_err(sql_err)?;
    conn.pragma_update(None, "foreign_keys", "ON")
        .map_err(sql_err)?;
    Ok(conn)
}

fn init_schema(conn: &Connection) -> Result<(), KernelError> {
    if raw_table_exists(conn, "rag_sources")?
        && !raw_column_exists(conn, "rag_sources", "collection_fk")?
    {
        conn.execute_batch(
            r#"
DROP TABLE IF EXISTS rag_embeddings;
DROP TABLE IF EXISTS rag_chunks_fts;
DROP TABLE IF EXISTS rag_chunks;
DROP TABLE IF EXISTS rag_sources;
DROP TABLE IF EXISTS rag_collections;
DROP TABLE IF EXISTS rag_index_runs;
"#,
        )
        .map_err(sql_err)?;
    }
    conn.execute_batch(
        r#"
CREATE TABLE IF NOT EXISTS rag_meta (
  key TEXT PRIMARY KEY,
  value TEXT NOT NULL,
  updated_at TEXT NOT NULL
);

CREATE TABLE IF NOT EXISTS rag_collections (
  id INTEGER PRIMARY KEY,
  collection_type TEXT NOT NULL CHECK(collection_type IN ('system', 'user')),
  collection_name TEXT NOT NULL,
  source_uri TEXT NOT NULL,
  manifest_path TEXT,
  manifest_hash TEXT NOT NULL DEFAULT '',
  title TEXT NOT NULL,
  description TEXT NOT NULL DEFAULT '',
  privacy_tier TEXT NOT NULL,
  prompt_eligible INTEGER NOT NULL DEFAULT 0,
  review_only INTEGER NOT NULL DEFAULT 0,
  enabled INTEGER NOT NULL DEFAULT 1,
  stale INTEGER NOT NULL DEFAULT 0,
  content_hash TEXT NOT NULL DEFAULT '',
  embedding_model_key TEXT,
  created_at TEXT NOT NULL,
  updated_at TEXT NOT NULL,
  last_ingested_at TEXT,
  last_indexed_at TEXT,
  last_accessed_at TEXT,
  fetch_policy_json TEXT NOT NULL DEFAULT '{}',
  last_error TEXT,
  last_error_at TEXT,
  UNIQUE(collection_type, collection_name)
);

CREATE TABLE IF NOT EXISTS rag_sources (
  id INTEGER PRIMARY KEY,
  collection_fk INTEGER NOT NULL REFERENCES rag_collections(id) ON DELETE CASCADE,
  source_kind TEXT NOT NULL,
  source_id TEXT NOT NULL,
  parent_source_id TEXT,
  source_path TEXT,
  source_uri TEXT NOT NULL DEFAULT '',
  title TEXT NOT NULL,
  tags_json TEXT NOT NULL DEFAULT '[]',
  content_hash TEXT NOT NULL,
  privacy_tier TEXT NOT NULL,
  prompt_eligible INTEGER NOT NULL DEFAULT 0,
  review_only INTEGER NOT NULL DEFAULT 0,
  stale INTEGER NOT NULL DEFAULT 0,
  ingest_state TEXT NOT NULL DEFAULT 'active'
    CHECK(ingest_state IN ('active', 'skipped', 'error')),
  created_at TEXT NOT NULL,
  updated_at TEXT NOT NULL,
  last_ingested_at TEXT,
  last_indexed_at TEXT,
  last_accessed_at TEXT,
  fetched_at TEXT,
  http_status INTEGER,
  http_etag TEXT,
  http_last_modified TEXT,
  http_content_type TEXT,
  http_content_length INTEGER,
  final_url TEXT,
  robots_allowed INTEGER,
  robots_checked_at TEXT,
  fetch_duration_ms INTEGER,
  last_error TEXT,
  last_error_at TEXT,
  UNIQUE(collection_fk, source_kind, source_id)
);

CREATE TABLE IF NOT EXISTS rag_chunks (
  id INTEGER PRIMARY KEY,
  collection_fk INTEGER NOT NULL REFERENCES rag_collections(id) ON DELETE CASCADE,
  source_fk INTEGER NOT NULL REFERENCES rag_sources(id) ON DELETE CASCADE,
  chunk_id TEXT NOT NULL UNIQUE,
  ordinal INTEGER NOT NULL,
  title TEXT NOT NULL,
  heading_path TEXT,
  text TEXT NOT NULL,
  byte_len INTEGER NOT NULL,
  token_estimate INTEGER NOT NULL,
  tags TEXT NOT NULL DEFAULT '',
  collection_type TEXT NOT NULL DEFAULT '',
  collection_name TEXT NOT NULL DEFAULT '',
  source_kind TEXT NOT NULL DEFAULT '',
  labels TEXT NOT NULL DEFAULT '',
  provenance_json TEXT NOT NULL,
  prompt_eligible INTEGER NOT NULL DEFAULT 0,
  review_only INTEGER NOT NULL DEFAULT 0,
  content_hash TEXT NOT NULL,
  embedding_model_key TEXT,
  embedding_state TEXT NOT NULL DEFAULT 'missing',
  updated_at TEXT NOT NULL
);

CREATE VIRTUAL TABLE IF NOT EXISTS rag_chunks_fts USING fts5(
  title,
  text,
  tags,
  source_kind,
  collection_type,
  collection_name,
  labels,
  content='rag_chunks',
  content_rowid='id'
);

CREATE TABLE IF NOT EXISTS rag_index_runs (
  run_id TEXT PRIMARY KEY,
  trigger TEXT NOT NULL,
  requested_collections_json TEXT NOT NULL DEFAULT '[]',
  requested_sources_json TEXT NOT NULL DEFAULT '[]',
  include_vectors INTEGER NOT NULL DEFAULT 0,
  stale_only INTEGER NOT NULL DEFAULT 1,
  status TEXT NOT NULL,
  started_at TEXT NOT NULL,
  finished_at TEXT,
  source_count INTEGER NOT NULL DEFAULT 0,
  chunk_count INTEGER NOT NULL DEFAULT 0,
  vector_count INTEGER NOT NULL DEFAULT 0,
  skipped_count INTEGER NOT NULL DEFAULT 0,
  elapsed_ms INTEGER NOT NULL DEFAULT 0,
  error TEXT
);

CREATE INDEX IF NOT EXISTS idx_rag_collections_type_name ON rag_collections(collection_type, collection_name);
CREATE INDEX IF NOT EXISTS idx_rag_collections_stale ON rag_collections(stale);
CREATE INDEX IF NOT EXISTS idx_rag_collections_accessed ON rag_collections(last_accessed_at);
CREATE INDEX IF NOT EXISTS idx_rag_collections_manifest ON rag_collections(manifest_hash);
CREATE INDEX IF NOT EXISTS idx_rag_sources_collection ON rag_sources(collection_fk);
CREATE INDEX IF NOT EXISTS idx_rag_sources_kind ON rag_sources(source_kind);
CREATE INDEX IF NOT EXISTS idx_rag_sources_stale ON rag_sources(stale);
CREATE INDEX IF NOT EXISTS idx_rag_sources_state ON rag_sources(ingest_state);
CREATE INDEX IF NOT EXISTS idx_rag_sources_uri ON rag_sources(source_uri);
CREATE INDEX IF NOT EXISTS idx_rag_sources_accessed ON rag_sources(last_accessed_at);
CREATE INDEX IF NOT EXISTS idx_rag_chunks_source ON rag_chunks(source_fk);
CREATE INDEX IF NOT EXISTS idx_rag_chunks_collection ON rag_chunks(collection_fk);
CREATE INDEX IF NOT EXISTS idx_rag_chunks_collection_name ON rag_chunks(collection_type, collection_name);
CREATE INDEX IF NOT EXISTS idx_rag_chunks_prompt ON rag_chunks(prompt_eligible, review_only);
CREATE INDEX IF NOT EXISTS idx_rag_chunks_embedding ON rag_chunks(embedding_model_key, embedding_state);
CREATE INDEX IF NOT EXISTS idx_rag_runs_started ON rag_index_runs(started_at);
"#,
    )
    .map_err(sql_err)?;
    conn.execute(
        "INSERT INTO rag_meta (key, value, updated_at)
         VALUES ('schema_version', ?1, ?2)
         ON CONFLICT(key) DO UPDATE SET value = excluded.value, updated_at = excluded.updated_at",
        params![
            RAG_SCHEMA_VERSION.to_string(),
            chrono::Utc::now().to_rfc3339()
        ],
    )
    .map_err(sql_err)?;
    Ok(())
}

fn collect_sources(
    paths: &AllbertPaths,
    config: &Config,
    request: &RagRebuildRequest,
) -> Result<Vec<CollectedSource>, KernelError> {
    let mut sources = Vec::new();
    if request.collection_type != Some(RagCollectionType::User) {
        collect_operator_docs(&mut sources)?;
        collect_command_catalog(&mut sources)?;
        collect_settings_catalog(&mut sources);
        collect_skill_metadata(paths, config, &mut sources);
        collect_memory_sources(
            paths,
            config,
            request.sources.contains(&RagSourceKind::StagedMemoryReview)
                || config
                    .rag
                    .sources
                    .contains(&RagSourceKind::StagedMemoryReview),
            &mut sources,
        )?;
    }

    let wants_user = request.collection_type == Some(RagCollectionType::User)
        || !request.collections.is_empty()
        || request
            .sources
            .iter()
            .any(|source| matches!(source, RagSourceKind::UserDocument | RagSourceKind::WebUrl));
    if wants_user {
        collect_user_collection_sources(paths, config, request, &mut sources)?;
    }

    if let Some(collection_type) = request.collection_type {
        sources.retain(|source| source.collection_type == collection_type);
    }
    if !request.collections.is_empty() {
        let wanted = request
            .collections
            .iter()
            .map(|value| normalize_collection_name(value))
            .collect::<HashSet<_>>();
        sources.retain(|source| wanted.contains(&source.collection_name));
    }
    if !request.sources.is_empty() {
        sources.retain(|source| request.sources.contains(&source.kind));
    } else {
        sources.retain(|source| {
            source.collection_type == RagCollectionType::User
                || config.rag.sources.contains(&source.kind)
        });
    }
    sources.sort_by(|a, b| {
        a.collection_type
            .label()
            .cmp(b.collection_type.label())
            .then_with(|| a.collection_name.cmp(&b.collection_name))
            .then_with(|| a.kind.label().cmp(b.kind.label()))
            .then_with(|| a.source_id.cmp(&b.source_id))
    });
    Ok(sources)
}

fn system_collection_for_kind(kind: RagSourceKind) -> (&'static str, &'static str, &'static str) {
    match kind {
        RagSourceKind::OperatorDocs => {
            ("operator_docs", "allbert://docs/operator", "Operator docs")
        }
        RagSourceKind::CommandCatalog => ("commands", "allbert://generated/commands", "Commands"),
        RagSourceKind::SettingsCatalog => ("settings", "allbert://generated/settings", "Settings"),
        RagSourceKind::SkillsMetadata => ("skills", "allbert://skills/metadata", "Skills"),
        RagSourceKind::DurableMemory => ("memory", "allbert://memory/durable", "Memory"),
        RagSourceKind::FactMemory => ("facts", "allbert://memory/facts", "Facts"),
        RagSourceKind::EpisodeRecall => ("episodes", "allbert://sessions/episodes", "Episodes"),
        RagSourceKind::SessionSummary => ("sessions", "allbert://sessions/summaries", "Sessions"),
        RagSourceKind::StagedMemoryReview => (
            "staged_review",
            "allbert://memory/staged-review",
            "Staged review",
        ),
        RagSourceKind::UserDocument | RagSourceKind::WebUrl => {
            ("user", "allbert://user", "User collection")
        }
    }
}

#[allow(clippy::too_many_arguments)]
fn system_source(
    kind: RagSourceKind,
    source_id: String,
    source_path: Option<String>,
    title: String,
    tags: Vec<String>,
    text: String,
    privacy_tier: &'static str,
    prompt_eligible: bool,
    review_only: bool,
) -> CollectedSource {
    let (collection_name, source_uri, _) = system_collection_for_kind(kind);
    CollectedSource {
        collection_type: RagCollectionType::System,
        collection_name: collection_name.into(),
        kind,
        source_id,
        source_uri: source_uri.into(),
        source_path,
        title,
        tags,
        text,
        privacy_tier,
        prompt_eligible,
        review_only,
        ingest_state: "active",
        http_status: None,
        http_etag: None,
        http_last_modified: None,
        http_content_type: None,
        final_url: None,
        robots_allowed: None,
        last_error: None,
    }
}

fn normalize_collection_name(value: &str) -> String {
    value
        .trim()
        .chars()
        .map(|ch| {
            if ch.is_ascii_alphanumeric() || ch == '-' || ch == '_' {
                ch.to_ascii_lowercase()
            } else {
                '-'
            }
        })
        .collect::<String>()
        .trim_matches('-')
        .to_string()
}

fn user_collections_dir(paths: &AllbertPaths) -> PathBuf {
    paths.root.join("rag").join("collections").join("user")
}

fn user_collection_manifest_path(paths: &AllbertPaths, name: &str) -> PathBuf {
    user_collections_dir(paths).join(format!("{}.toml", normalize_collection_name(name)))
}

pub fn create_rag_collection(
    paths: &AllbertPaths,
    config: &Config,
    request: RagCollectionCreateRequest,
) -> Result<RagCollectionMutationSummary, KernelError> {
    paths.ensure()?;
    let collection_name = normalize_collection_name(&request.collection_name);
    if collection_name.is_empty() {
        return Err(KernelError::Request(
            "RAG collection name must contain a letter or number".into(),
        ));
    }
    let manifest_path = user_collection_manifest_path(paths, &collection_name);
    if manifest_path.exists() {
        return Err(KernelError::Request(format!(
            "RAG collection `{collection_name}` already exists"
        )));
    }
    let fetch_policy = merge_fetch_policy(config, request.fetch_policy);
    let source_uris = normalize_source_uris(config, &fetch_policy, &request.source_uris)?;
    if source_uris.is_empty() {
        return Err(KernelError::Request(
            "RAG collection needs at least one source".into(),
        ));
    }
    let now = chrono::Utc::now().to_rfc3339();
    let manifest = RagCollectionManifest {
        version: 1,
        collection_type: RagCollectionType::User,
        collection_name: collection_name.clone(),
        title: request.title.unwrap_or_else(|| collection_name.clone()),
        description: request.description.unwrap_or_default(),
        privacy_tier: "user_supplied".into(),
        prompt_eligible: false,
        review_only: false,
        created_at: now.clone(),
        updated_at: now,
        source_uris,
        fetch_policy,
    };
    write_collection_manifest(&manifest_path, &manifest)?;
    materialize_user_collection(paths, config, &manifest, &manifest_path)?;
    Ok(RagCollectionMutationSummary {
        collection_type: RagCollectionType::User,
        collection_name,
        manifest_path: Some(manifest_path),
        source_uris: manifest.source_uris,
        stale: true,
        message: "collection created; run ingest or rebuild to index sources".into(),
    })
}

pub fn list_rag_collections(
    paths: &AllbertPaths,
    config: &Config,
    collection_type: Option<RagCollectionType>,
) -> Result<Vec<RagCollectionStatus>, KernelError> {
    let mut statuses = Vec::new();
    if collection_type != Some(RagCollectionType::User) {
        for kind in SYSTEM_COLLECTION_KINDS {
            let (name, uri, title) = system_collection_for_kind(kind);
            statuses.push(RagCollectionStatus {
                collection_type: RagCollectionType::System,
                collection_name: name.into(),
                title: title.into(),
                source_uri: uri.into(),
                enabled: true,
                stale: false,
                source_count: 0,
                chunk_count: 0,
                vector_count: 0,
                skipped_count: 0,
                manifest_path: None,
                last_ingested_at: None,
                last_indexed_at: None,
                last_accessed_at: None,
                vector_posture: if config.rag.vector.enabled {
                    RagVectorPosture::Stale
                } else {
                    RagVectorPosture::Disabled
                },
                degraded_reason: None,
            });
        }
    }
    if collection_type != Some(RagCollectionType::System) {
        for (path, manifest, _) in read_user_collection_manifests(paths)? {
            statuses.push(RagCollectionStatus {
                collection_type: RagCollectionType::User,
                collection_name: manifest.collection_name,
                title: manifest.title,
                source_uri: manifest.source_uris.first().cloned().unwrap_or_default(),
                enabled: true,
                stale: true,
                source_count: manifest.source_uris.len(),
                chunk_count: 0,
                vector_count: 0,
                skipped_count: 0,
                manifest_path: Some(path_display_under(&path, &paths.root)),
                last_ingested_at: None,
                last_indexed_at: None,
                last_accessed_at: None,
                vector_posture: if config.rag.vector.enabled {
                    RagVectorPosture::Stale
                } else {
                    RagVectorPosture::Disabled
                },
                degraded_reason: None,
            });
        }
    }
    if paths.rag_db.exists() {
        let conn = open_rag_db(paths)?;
        overlay_collection_counts(&conn, config, &mut statuses)?;
    }
    statuses.sort_by(|a, b| {
        a.collection_type
            .label()
            .cmp(b.collection_type.label())
            .then_with(|| a.collection_name.cmp(&b.collection_name))
    });
    Ok(statuses)
}

pub fn delete_rag_collection(
    paths: &AllbertPaths,
    name: &str,
) -> Result<RagCollectionMutationSummary, KernelError> {
    let collection_name = normalize_collection_name(name);
    let manifest_path = user_collection_manifest_path(paths, &collection_name);
    let source_uris = if manifest_path.exists() {
        let manifest = read_collection_manifest(&manifest_path)?;
        manifest.source_uris
    } else {
        Vec::new()
    };
    if manifest_path.exists() {
        fs::remove_file(&manifest_path).map_err(|e| {
            KernelError::InitFailed(format!("remove {}: {e}", manifest_path.display()))
        })?;
    }
    if paths.rag_db.exists() {
        let conn = open_rag_db(paths)?;
        conn.execute(
            "DELETE FROM rag_collections WHERE collection_type = 'user' AND collection_name = ?1",
            [collection_name.as_str()],
        )
        .map_err(sql_err)?;
    }
    Ok(RagCollectionMutationSummary {
        collection_type: RagCollectionType::User,
        collection_name,
        manifest_path: Some(manifest_path),
        source_uris,
        stale: false,
        message: "collection deleted; source files and remote content were not deleted".into(),
    })
}

fn merge_fetch_policy(config: &Config, mut policy: RagFetchPolicy) -> RagFetchPolicy {
    policy.allow_insecure_http |= config.rag.ingest.allow_insecure_http;
    if policy.url_max_pages == 1 {
        policy.url_max_pages = config.rag.ingest.url_max_pages;
    }
    if policy.url_max_bytes == 2_097_152 {
        policy.url_max_bytes = config.rag.ingest.url_max_bytes;
    }
    if policy.url_max_redirects == 5 {
        policy.url_max_redirects = config.rag.ingest.url_max_redirects;
    }
    if policy.fetch_timeout_s == 20 {
        policy.fetch_timeout_s = config.rag.ingest.fetch_timeout_s;
    }
    policy.respect_robots_txt &= config.rag.ingest.respect_robots_txt;
    policy
}

fn normalize_source_uris(
    config: &Config,
    policy: &RagFetchPolicy,
    values: &[String],
) -> Result<Vec<String>, KernelError> {
    let mut normalized = Vec::new();
    for value in values {
        let (uri, _) = normalize_source_uri(config, policy, value)?;
        if !normalized.contains(&uri) {
            normalized.push(uri);
        }
    }
    Ok(normalized)
}

fn normalize_source_uri(
    config: &Config,
    policy: &RagFetchPolicy,
    value: &str,
) -> Result<(String, SourceUriKind), KernelError> {
    let raw = value.trim();
    if raw.starts_with("http://") || raw.starts_with("https://") {
        let url = reqwest::Url::parse(raw)
            .map_err(|e| KernelError::Request(format!("invalid URL source `{raw}`: {e}")))?;
        validate_url_source(config, &url, policy)?;
        return Ok((canonical_url(&url), SourceUriKind::Web));
    }
    let path = if let Some(rest) = raw.strip_prefix("dir://") {
        PathBuf::from(rest)
    } else if raw.starts_with("file://") {
        let url = reqwest::Url::parse(raw)
            .map_err(|e| KernelError::Request(format!("invalid file source `{raw}`: {e}")))?;
        url.to_file_path()
            .map_err(|_| KernelError::Request(format!("invalid file URL source `{raw}`")))?
    } else {
        PathBuf::from(raw)
    };
    let canonical =
        security::sandbox::check(&path, &config.security.fs_roots).map_err(KernelError::Request)?;
    if canonical.is_dir() {
        Ok((
            format!("dir://{}", canonical.to_string_lossy().replace('\\', "/")),
            SourceUriKind::Dir,
        ))
    } else {
        Ok((
            format!("file://{}", canonical.to_string_lossy().replace('\\', "/")),
            SourceUriKind::File,
        ))
    }
}

fn validate_url_source(
    config: &Config,
    url: &reqwest::Url,
    policy: &RagFetchPolicy,
) -> Result<(), KernelError> {
    let scheme_allowed = config
        .rag
        .ingest
        .allowed_url_schemes
        .iter()
        .any(|scheme| scheme.eq_ignore_ascii_case(url.scheme()))
        || (url.scheme() == "http" && policy.allow_insecure_http);
    if !scheme_allowed {
        return Err(KernelError::Request(format!(
            "RAG URL scheme `{}` is not enabled",
            url.scheme()
        )));
    }
    match url.scheme() {
        "https" => {}
        "http" if policy.allow_insecure_http => {}
        "http" => {
            return Err(KernelError::Request(
                "HTTP URL sources require --allow-insecure-http".into(),
            ))
        }
        scheme => {
            return Err(KernelError::Request(format!(
                "unsupported RAG URL scheme `{scheme}`"
            )))
        }
    }
    if !url.username().is_empty() || url.password().is_some() {
        return Err(KernelError::Request(
            "RAG URL sources must not include credentials".into(),
        ));
    }
    let host = url
        .host_str()
        .ok_or_else(|| KernelError::Request("RAG URL source needs a host".into()))?;
    if host.eq_ignore_ascii_case("localhost") {
        return Err(KernelError::Request(
            "RAG URL source host localhost is not allowed".into(),
        ));
    }
    validate_resolved_host(host, url.port_or_known_default().unwrap_or(443))
}

fn validate_resolved_host(host: &str, port: u16) -> Result<(), KernelError> {
    if let Ok(ip) = host.parse::<IpAddr>() {
        validate_public_ip(ip)?;
        return Ok(());
    }
    let addrs = (host, port)
        .to_socket_addrs()
        .map_err(|e| KernelError::Request(format!("resolve RAG URL host `{host}`: {e}")))?;
    let mut saw = false;
    for addr in addrs {
        saw = true;
        validate_public_ip(addr.ip())?;
    }
    if !saw {
        return Err(KernelError::Request(format!(
            "RAG URL host `{host}` resolved no addresses"
        )));
    }
    Ok(())
}

fn validate_public_ip(ip: IpAddr) -> Result<(), KernelError> {
    let blocked = match ip {
        IpAddr::V4(ip) => {
            ip.is_private()
                || ip.is_loopback()
                || ip.is_link_local()
                || ip.is_multicast()
                || ip.is_broadcast()
                || ip.is_unspecified()
                || ip.octets() == [169, 254, 169, 254]
        }
        IpAddr::V6(ip) => {
            ip.is_loopback()
                || ip.is_multicast()
                || ip.is_unspecified()
                || ip.is_unique_local()
                || ip.is_unicast_link_local()
        }
    };
    if blocked {
        Err(KernelError::Request(format!(
            "RAG URL resolved to disallowed address {ip}"
        )))
    } else {
        Ok(())
    }
}

fn canonical_url(url: &reqwest::Url) -> String {
    let mut cloned = url.clone();
    cloned.set_fragment(None);
    cloned.to_string()
}

fn write_collection_manifest(
    path: &Path,
    manifest: &RagCollectionManifest,
) -> Result<(), KernelError> {
    if let Some(parent) = path.parent() {
        fs::create_dir_all(parent)
            .map_err(|e| KernelError::InitFailed(format!("create {}: {e}", parent.display())))?;
    }
    let content = toml::to_string_pretty(manifest)
        .map_err(|e| KernelError::InitFailed(format!("serialize RAG collection manifest: {e}")))?;
    atomic_write(path, content.as_bytes())
        .map_err(|e| KernelError::InitFailed(format!("write {}: {e}", path.display())))
}

fn read_collection_manifest(path: &Path) -> Result<RagCollectionManifest, KernelError> {
    let raw = fs::read_to_string(path)
        .map_err(|e| KernelError::InitFailed(format!("read {}: {e}", path.display())))?;
    toml::from_str(&raw).map_err(|e| {
        KernelError::InitFailed(format!(
            "parse RAG collection manifest {}: {e}",
            path.display()
        ))
    })
}

fn read_user_collection_manifests(
    paths: &AllbertPaths,
) -> Result<Vec<(PathBuf, RagCollectionManifest, String)>, KernelError> {
    let dir = user_collections_dir(paths);
    if !dir.exists() {
        return Ok(Vec::new());
    }
    let mut entries = Vec::new();
    for entry in fs::read_dir(&dir)
        .map_err(|e| KernelError::InitFailed(format!("read {}: {e}", dir.display())))?
    {
        let entry = entry
            .map_err(|e| KernelError::InitFailed(format!("read {} entry: {e}", dir.display())))?;
        let path = entry.path();
        if path.extension().is_none_or(|ext| ext != "toml") {
            continue;
        }
        let raw = fs::read_to_string(&path)
            .map_err(|e| KernelError::InitFailed(format!("read {}: {e}", path.display())))?;
        let manifest: RagCollectionManifest = toml::from_str(&raw).map_err(|e| {
            KernelError::InitFailed(format!(
                "parse RAG collection manifest {}: {e}",
                path.display()
            ))
        })?;
        entries.push((path, manifest, hash_text(&raw)));
    }
    entries.sort_by(|a, b| a.1.collection_name.cmp(&b.1.collection_name));
    Ok(entries)
}

fn materialize_user_collection(
    paths: &AllbertPaths,
    config: &Config,
    manifest: &RagCollectionManifest,
    manifest_path: &Path,
) -> Result<(), KernelError> {
    fs::create_dir_all(&paths.rag_index).map_err(|e| {
        KernelError::InitFailed(format!("create {}: {e}", paths.rag_index.display()))
    })?;
    let conn = open_rag_db(paths)?;
    let raw = fs::read_to_string(manifest_path)
        .map_err(|e| KernelError::InitFailed(format!("read {}: {e}", manifest_path.display())))?;
    let entry = CollectionCatalogEntry {
        collection_type: RagCollectionType::User,
        collection_name: manifest.collection_name.clone(),
        source_uri: manifest.source_uris.first().cloned().unwrap_or_default(),
        title: manifest.title.clone(),
        description: manifest.description.clone(),
        privacy_tier: manifest.privacy_tier.clone(),
        prompt_eligible: false,
        review_only: manifest.review_only,
        manifest_path: Some(path_display_under(manifest_path, &paths.root)),
        manifest_hash: hash_text(&raw),
        fetch_policy_json: serde_json::to_string(&manifest.fetch_policy)
            .unwrap_or_else(|_| "{}".into()),
    };
    insert_collection_catalog(&conn, config, &entry, &[])?;
    Ok(())
}

fn overlay_collection_counts(
    conn: &Connection,
    config: &Config,
    statuses: &mut [RagCollectionStatus],
) -> Result<(), KernelError> {
    for status in statuses {
        let collection_type = status.collection_type.label();
        let row = conn
            .query_row(
                "SELECT c.id, c.source_uri, c.enabled, c.stale, c.last_ingested_at,
                        c.last_indexed_at, c.last_accessed_at,
                        COUNT(DISTINCT s.id),
                        COUNT(DISTINCT ch.id),
                        SUM(CASE WHEN s.ingest_state = 'skipped' THEN 1 ELSE 0 END)
                 FROM rag_collections c
                 LEFT JOIN rag_sources s ON s.collection_fk = c.id
                 LEFT JOIN rag_chunks ch ON ch.collection_fk = c.id
                 WHERE c.collection_type = ?1 AND c.collection_name = ?2
                 GROUP BY c.id",
                params![collection_type, status.collection_name],
                |row| {
                    Ok((
                        row.get::<_, i64>(0)?,
                        row.get::<_, String>(1)?,
                        row.get::<_, i64>(2)?,
                        row.get::<_, i64>(3)?,
                        row.get::<_, Option<String>>(4)?,
                        row.get::<_, Option<String>>(5)?,
                        row.get::<_, Option<String>>(6)?,
                        row.get::<_, i64>(7)?,
                        row.get::<_, i64>(8)?,
                        row.get::<_, Option<i64>>(9)?.unwrap_or(0),
                    ))
                },
            )
            .optional()
            .map_err(sql_err)?;
        if let Some((
            collection_id,
            source_uri,
            enabled,
            stale,
            last_ingested_at,
            last_indexed_at,
            last_accessed_at,
            source_count,
            chunk_count,
            skipped_count,
        )) = row
        {
            status.source_uri = source_uri;
            status.enabled = enabled != 0;
            status.stale = stale != 0;
            status.source_count = source_count as usize;
            status.chunk_count = chunk_count as usize;
            status.skipped_count = skipped_count as usize;
            status.last_ingested_at = last_ingested_at;
            status.last_indexed_at = last_indexed_at;
            status.last_accessed_at = last_accessed_at;
            status.vector_count = if table_exists(conn, "rag_embeddings")? {
                conn.query_row(
                    "SELECT COUNT(*)
                     FROM rag_embeddings e
                     JOIN rag_chunks ch ON ch.id = e.rowid
                     WHERE ch.collection_fk = ?1",
                    [collection_id],
                    |row| row.get::<_, i64>(0),
                )
                .map_err(sql_err)? as usize
            } else {
                0
            };
            status.vector_posture = if config.rag.vector.enabled {
                if status.vector_count > 0 {
                    RagVectorPosture::Healthy
                } else {
                    RagVectorPosture::Stale
                }
            } else {
                RagVectorPosture::Disabled
            };
        }
    }
    Ok(())
}

fn collect_user_collection_sources(
    paths: &AllbertPaths,
    config: &Config,
    request: &RagRebuildRequest,
    sources: &mut Vec<CollectedSource>,
) -> Result<(), KernelError> {
    let wanted = request
        .collections
        .iter()
        .map(|value| normalize_collection_name(value))
        .collect::<HashSet<_>>();
    for (_path, manifest, _hash) in read_user_collection_manifests(paths)? {
        if !wanted.is_empty() && !wanted.contains(&manifest.collection_name) {
            continue;
        }
        for uri in &manifest.source_uris {
            collect_user_source_uri(paths, config, &manifest, uri, sources)?;
        }
    }
    Ok(())
}

fn collect_user_source_uri(
    paths: &AllbertPaths,
    config: &Config,
    manifest: &RagCollectionManifest,
    uri: &str,
    sources: &mut Vec<CollectedSource>,
) -> Result<(), KernelError> {
    let (normalized, kind) = normalize_source_uri(config, &manifest.fetch_policy, uri)?;
    match kind {
        SourceUriKind::File => {
            let path = path_from_file_or_dir_uri(&normalized)?;
            collect_user_file(paths, config, manifest, &normalized, &path, sources)
        }
        SourceUriKind::Dir => {
            let path = path_from_file_or_dir_uri(&normalized)?;
            collect_user_dir(paths, config, manifest, &normalized, &path, sources)
        }
        SourceUriKind::Web => collect_user_url(config, manifest, &normalized, sources),
    }
}

fn path_from_file_or_dir_uri(uri: &str) -> Result<PathBuf, KernelError> {
    if let Some(rest) = uri.strip_prefix("dir://") {
        Ok(PathBuf::from(rest))
    } else if let Some(rest) = uri.strip_prefix("file://") {
        Ok(PathBuf::from(rest))
    } else {
        Err(KernelError::Request(format!(
            "RAG source `{uri}` is not a local file or directory URI"
        )))
    }
}

fn collect_user_file(
    paths: &AllbertPaths,
    config: &Config,
    manifest: &RagCollectionManifest,
    source_uri: &str,
    path: &Path,
    sources: &mut Vec<CollectedSource>,
) -> Result<(), KernelError> {
    let bytes = fs::read(path)
        .map_err(|e| KernelError::InitFailed(format!("read {}: {e}", path.display())))?;
    let max = config.rag.ingest.max_file_bytes.max(1);
    if bytes.len() > max {
        sources.push(user_error_source(
            manifest,
            RagSourceKind::UserDocument,
            source_uri,
            Some(path_display_under(path, &paths.root)),
            format!("file exceeds cap: {}", path.display()),
        ));
        return Ok(());
    }
    let text = match String::from_utf8(bytes) {
        Ok(text) => text,
        Err(_) => {
            sources.push(user_error_source(
                manifest,
                RagSourceKind::UserDocument,
                source_uri,
                Some(path_display_under(path, &paths.root)),
                format!("file is not UTF-8 text: {}", path.display()),
            ));
            return Ok(());
        }
    };
    sources.push(user_text_source(
        manifest,
        RagSourceKind::UserDocument,
        source_uri,
        Some(path_display_under(path, &paths.root)),
        file_title(path, &text),
        vec!["user".into(), "local".into()],
        text,
        None,
    ));
    Ok(())
}

fn collect_user_dir(
    paths: &AllbertPaths,
    config: &Config,
    manifest: &RagCollectionManifest,
    source_uri: &str,
    dir: &Path,
    sources: &mut Vec<CollectedSource>,
) -> Result<(), KernelError> {
    let mut files = Vec::new();
    collect_text_files_bounded(dir, &mut files, config.rag.ingest.max_files_per_collection)?;
    let mut total = 0usize;
    for file in files {
        let size = fs::metadata(&file)
            .map_err(|e| KernelError::InitFailed(format!("stat {}: {e}", file.display())))?
            .len() as usize;
        total += size;
        if total > config.rag.ingest.max_collection_bytes {
            sources.push(user_error_source(
                manifest,
                RagSourceKind::UserDocument,
                source_uri,
                Some(path_display_under(&file, &paths.root)),
                "collection byte cap exceeded".into(),
            ));
            break;
        }
        if size > config.rag.ingest.max_file_bytes {
            sources.push(user_error_source(
                manifest,
                RagSourceKind::UserDocument,
                source_uri,
                Some(path_display_under(&file, &paths.root)),
                format!("file exceeds cap: {}", file.display()),
            ));
            continue;
        }
        collect_user_file(paths, config, manifest, source_uri, &file, sources)?;
    }
    Ok(())
}

fn collect_text_files_bounded(
    root: &Path,
    files: &mut Vec<PathBuf>,
    max_files: usize,
) -> Result<(), KernelError> {
    if files.len() >= max_files {
        return Ok(());
    }
    for entry in fs::read_dir(root)
        .map_err(|e| KernelError::InitFailed(format!("read {}: {e}", root.display())))?
    {
        if files.len() >= max_files {
            break;
        }
        let entry = entry
            .map_err(|e| KernelError::InitFailed(format!("read {} entry: {e}", root.display())))?;
        let path = entry.path();
        if path.is_dir() {
            collect_text_files_bounded(&path, files, max_files)?;
        } else if is_text_like_path(&path) {
            files.push(path);
        }
    }
    files.sort();
    Ok(())
}

fn is_text_like_path(path: &Path) -> bool {
    path.extension()
        .and_then(|ext| ext.to_str())
        .map(|ext| {
            matches!(
                ext.to_ascii_lowercase().as_str(),
                "md" | "markdown" | "txt" | "toml" | "json" | "yaml" | "yml" | "rs"
            )
        })
        .unwrap_or(false)
}

fn collect_user_url(
    config: &Config,
    manifest: &RagCollectionManifest,
    source_uri: &str,
    sources: &mut Vec<CollectedSource>,
) -> Result<(), KernelError> {
    let config = config.clone();
    let manifest = manifest.clone();
    let source_uri = source_uri.to_string();
    let mut collected = run_blocking_http(
        move || collect_user_url_blocking(&config, &manifest, &source_uri),
        KernelError::InitFailed,
    )?;
    sources.append(&mut collected);
    Ok(())
}

fn collect_user_url_blocking(
    config: &Config,
    manifest: &RagCollectionManifest,
    source_uri: &str,
) -> Result<Vec<CollectedSource>, KernelError> {
    let mut sources = Vec::new();
    let url = reqwest::Url::parse(source_uri)
        .map_err(|e| KernelError::Request(format!("invalid URL source `{source_uri}`: {e}")))?;
    if let Err(err) = validate_url_source(config, &url, &manifest.fetch_policy) {
        sources.push(user_error_source(
            manifest,
            RagSourceKind::WebUrl,
            source_uri,
            None,
            err.to_string(),
        ));
        return Ok(sources);
    }
    let client = reqwest::blocking::Client::builder()
        .timeout(Duration::from_secs(manifest.fetch_policy.fetch_timeout_s))
        .redirect(reqwest::redirect::Policy::none())
        .user_agent(config.rag.ingest.user_agent.clone())
        .build()
        .map_err(|e| KernelError::InitFailed(format!("build RAG URL client: {e}")))?;

    let mut queue = VecDeque::from([(url, 0usize)]);
    let mut seen = HashSet::new();
    let mut fetched_pages = 0usize;
    while let Some((current, depth)) = queue.pop_front() {
        if fetched_pages >= manifest.fetch_policy.url_max_pages {
            break;
        }
        let canonical = canonical_url(&current);
        if !seen.insert(canonical) {
            continue;
        }
        let links = collect_user_url_page(config, manifest, &client, &current, &mut sources)?;
        fetched_pages += 1;
        if depth >= manifest.fetch_policy.url_depth {
            continue;
        }
        for link in links {
            if fetched_pages + queue.len() >= manifest.fetch_policy.url_max_pages {
                break;
            }
            if same_origin(&current, &link) {
                queue.push_back((link, depth + 1));
            }
        }
    }
    Ok(sources)
}

fn collect_user_url_page(
    config: &Config,
    manifest: &RagCollectionManifest,
    client: &reqwest::blocking::Client,
    url: &reqwest::Url,
    sources: &mut Vec<CollectedSource>,
) -> Result<Vec<reqwest::Url>, KernelError> {
    let source_uri = canonical_url(url);
    let started = Instant::now();
    if manifest.fetch_policy.respect_robots_txt && !robots_allows(config, url)? {
        sources.push(user_skipped_source(
            manifest,
            RagSourceKind::WebUrl,
            &source_uri,
            "robots.txt disallowed fetch".into(),
        ));
        return Ok(Vec::new());
    }
    let mut current = url.clone();
    for _ in 0..=manifest.fetch_policy.url_max_redirects {
        validate_url_source(config, &current, &manifest.fetch_policy)?;
        let response = client
            .get(current.clone())
            .send()
            .map_err(|e| KernelError::Request(format!("fetch RAG URL `{current}`: {e}")))?;
        let status = response.status();
        if status.is_redirection() {
            let Some(location) = response.headers().get(reqwest::header::LOCATION) else {
                break;
            };
            let location = location.to_str().map_err(|e| {
                KernelError::Request(format!("read redirect location for `{current}`: {e}"))
            })?;
            current = current.join(location).map_err(|e| {
                KernelError::Request(format!("resolve redirect for RAG URL `{current}`: {e}"))
            })?;
            continue;
        }
        if !status.is_success() {
            sources.push(user_error_source(
                manifest,
                RagSourceKind::WebUrl,
                &source_uri,
                None,
                format!("HTTP status {status}"),
            ));
            return Ok(Vec::new());
        }
        let content_type = response
            .headers()
            .get(reqwest::header::CONTENT_TYPE)
            .and_then(|value| value.to_str().ok())
            .unwrap_or("text/plain")
            .to_string();
        if !content_type_allowed(config, &content_type) {
            sources.push(user_skipped_source(
                manifest,
                RagSourceKind::WebUrl,
                &source_uri,
                format!("content type `{content_type}` is not allowed"),
            ));
            return Ok(Vec::new());
        }
        let etag = response
            .headers()
            .get(reqwest::header::ETAG)
            .and_then(|value| value.to_str().ok())
            .map(str::to_string);
        let last_modified = response
            .headers()
            .get(reqwest::header::LAST_MODIFIED)
            .and_then(|value| value.to_str().ok())
            .map(str::to_string);
        let bytes = response
            .bytes()
            .map_err(|e| KernelError::Request(format!("read RAG URL `{current}`: {e}")))?;
        if bytes.len() > manifest.fetch_policy.url_max_bytes {
            sources.push(user_error_source(
                manifest,
                RagSourceKind::WebUrl,
                &source_uri,
                None,
                "URL response exceeded byte cap".into(),
            ));
            return Ok(Vec::new());
        }
        let raw = String::from_utf8_lossy(&bytes).to_string();
        let html = content_type.contains("html");
        let links = if html {
            extract_html_links(&raw, &current, config, &manifest.fetch_policy)
        } else {
            Vec::new()
        };
        let text = if html { extract_html_text(&raw) } else { raw };
        let mut source = user_text_source(
            manifest,
            RagSourceKind::WebUrl,
            &source_uri,
            Some(current.to_string()),
            first_markdown_heading(&text).unwrap_or_else(|| current.to_string()),
            vec!["user".into(), "web".into()],
            text,
            Some(current.to_string()),
        );
        source.http_status = Some(status.as_u16() as i64);
        source.http_etag = etag;
        source.http_last_modified = last_modified;
        source.http_content_type = Some(content_type);
        source.robots_allowed = Some(true);
        source.final_url = Some(current.to_string());
        source
            .tags
            .push(format!("fetch_ms:{}", started.elapsed().as_millis()));
        sources.push(source);
        return Ok(links);
    }
    sources.push(user_error_source(
        manifest,
        RagSourceKind::WebUrl,
        &source_uri,
        None,
        "too many redirects".into(),
    ));
    Ok(Vec::new())
}

fn content_type_allowed(config: &Config, content_type: &str) -> bool {
    let base = content_type
        .split(';')
        .next()
        .unwrap_or(content_type)
        .trim()
        .to_ascii_lowercase();
    config
        .rag
        .ingest
        .allowed_content_types
        .iter()
        .any(|allowed| allowed.eq_ignore_ascii_case(&base))
}

fn same_origin(left: &reqwest::Url, right: &reqwest::Url) -> bool {
    left.scheme() == right.scheme()
        && left.host_str() == right.host_str()
        && left.port_or_known_default() == right.port_or_known_default()
}

fn extract_html_links(
    raw: &str,
    base: &reqwest::Url,
    config: &Config,
    policy: &RagFetchPolicy,
) -> Vec<reqwest::Url> {
    let lower = raw.to_ascii_lowercase();
    let mut offset = 0usize;
    let mut seen = HashSet::new();
    let mut links = Vec::new();
    while let Some(found) = lower[offset..].find("href") {
        let mut pos = offset + found + "href".len();
        while lower
            .as_bytes()
            .get(pos)
            .is_some_and(u8::is_ascii_whitespace)
        {
            pos += 1;
        }
        if lower.as_bytes().get(pos) != Some(&b'=') {
            offset = pos;
            continue;
        }
        pos += 1;
        while lower
            .as_bytes()
            .get(pos)
            .is_some_and(u8::is_ascii_whitespace)
        {
            pos += 1;
        }
        let Some(first) = raw.as_bytes().get(pos).copied() else {
            break;
        };
        let (start, end) = if first == b'\'' || first == b'"' {
            let start = pos + 1;
            let Some(relative_end) = raw[start..].find(first as char) else {
                break;
            };
            (start, start + relative_end)
        } else {
            let start = pos;
            let relative_end = raw[start..]
                .find(|ch: char| ch.is_ascii_whitespace() || ch == '>')
                .unwrap_or(raw.len() - start);
            (start, start + relative_end)
        };
        offset = end.saturating_add(1);
        let target = raw[start..end].trim();
        if target.is_empty() || target.starts_with('#') {
            continue;
        }
        let Ok(mut link) = base.join(target) else {
            continue;
        };
        link.set_fragment(None);
        if !same_origin(base, &link) {
            continue;
        }
        if validate_url_source(config, &link, policy).is_err() {
            continue;
        }
        let canonical = canonical_url(&link);
        if seen.insert(canonical) {
            links.push(link);
        }
    }
    links
}

fn robots_allows(config: &Config, url: &reqwest::Url) -> Result<bool, KernelError> {
    let mut robots = url.clone();
    robots.set_path("/robots.txt");
    robots.set_query(None);
    robots.set_fragment(None);
    let client = reqwest::blocking::Client::builder()
        .timeout(Duration::from_secs(5))
        .redirect(reqwest::redirect::Policy::none())
        .user_agent(config.rag.ingest.user_agent.clone())
        .build()
        .map_err(|e| KernelError::InitFailed(format!("build robots client: {e}")))?;
    let Ok(response) = client.get(robots).send() else {
        return Ok(true);
    };
    if !response.status().is_success() {
        return Ok(true);
    }
    let Ok(body) = response.text() else {
        return Ok(true);
    };
    Ok(simple_robots_allows(&body, url.path()))
}

fn simple_robots_allows(body: &str, path: &str) -> bool {
    let mut applies = false;
    for line in body.lines() {
        let line = line.split('#').next().unwrap_or("").trim();
        let Some((key, value)) = line.split_once(':') else {
            continue;
        };
        let key = key.trim().to_ascii_lowercase();
        let value = value.trim();
        match key.as_str() {
            "user-agent" => {
                applies = value == "*" || value.eq_ignore_ascii_case("AllbertRagBot");
            }
            "disallow" if applies && !value.is_empty() && path.starts_with(value) => {
                return false;
            }
            _ => {}
        }
    }
    true
}

fn extract_html_text(raw: &str) -> String {
    let mut out = String::new();
    let mut in_tag = false;
    for ch in raw.chars() {
        match ch {
            '<' => {
                in_tag = true;
                out.push(' ');
            }
            '>' => in_tag = false,
            _ if !in_tag => out.push(ch),
            _ => {}
        }
    }
    out.split_whitespace().collect::<Vec<_>>().join(" ")
}

fn file_title(path: &Path, text: &str) -> String {
    first_markdown_heading(text).unwrap_or_else(|| {
        path.file_name()
            .and_then(|name| name.to_str())
            .unwrap_or("user document")
            .to_string()
    })
}

#[allow(clippy::too_many_arguments)]
fn user_text_source(
    manifest: &RagCollectionManifest,
    kind: RagSourceKind,
    source_uri: &str,
    source_path: Option<String>,
    title: String,
    tags: Vec<String>,
    text: String,
    final_url: Option<String>,
) -> CollectedSource {
    CollectedSource {
        collection_type: RagCollectionType::User,
        collection_name: manifest.collection_name.clone(),
        kind,
        source_id: user_source_id(
            kind,
            &manifest.collection_name,
            source_uri,
            source_path.as_deref(),
        ),
        source_uri: source_uri.into(),
        source_path,
        title,
        tags,
        text,
        privacy_tier: if kind == RagSourceKind::WebUrl {
            "user_supplied_web"
        } else {
            "user_supplied"
        },
        prompt_eligible: false,
        review_only: manifest.review_only,
        ingest_state: "active",
        http_status: None,
        http_etag: None,
        http_last_modified: None,
        http_content_type: None,
        final_url,
        robots_allowed: None,
        last_error: None,
    }
}

fn user_error_source(
    manifest: &RagCollectionManifest,
    kind: RagSourceKind,
    source_uri: &str,
    source_path: Option<String>,
    error: String,
) -> CollectedSource {
    let mut source = user_text_source(
        manifest,
        kind,
        source_uri,
        source_path,
        format!("Skipped {}", source_uri),
        vec!["user".into(), "skipped".into()],
        format!("Skipped source {source_uri}: {error}"),
        None,
    );
    source.ingest_state = "error";
    source.last_error = Some(error);
    source.prompt_eligible = false;
    source
}

fn user_skipped_source(
    manifest: &RagCollectionManifest,
    kind: RagSourceKind,
    source_uri: &str,
    reason: String,
) -> CollectedSource {
    let mut source = user_error_source(manifest, kind, source_uri, None, reason);
    source.ingest_state = "skipped";
    source
}

fn user_source_id(
    kind: RagSourceKind,
    collection_name: &str,
    source_uri: &str,
    source_path: Option<&str>,
) -> String {
    let suffix = source_path.unwrap_or(source_uri);
    format!(
        "{}:{collection_name}:{}",
        kind.label(),
        hash_text(&format!("{source_uri}#{suffix}"))
    )
}

fn collect_memory_sources(
    paths: &AllbertPaths,
    config: &Config,
    include_staged_review: bool,
    sources: &mut Vec<CollectedSource>,
) -> Result<(), KernelError> {
    for source in memory::collect_rag_memory_sources(paths, &config.memory, include_staged_review)?
    {
        sources.push(system_source(
            source.kind,
            source.source_id,
            source.source_path,
            source.title,
            source.tags,
            source.text,
            source.privacy_tier,
            source.prompt_eligible,
            source.review_only,
        ));
    }
    Ok(())
}

fn collect_operator_docs(sources: &mut Vec<CollectedSource>) -> Result<(), KernelError> {
    let Some(repo) = repo_root() else {
        return Ok(());
    };
    let mut files = markdown_files(&repo.join("docs/operator"))?;
    files.push(repo.join("docs/onboarding-and-operations.md"));
    files.sort();
    files.dedup();
    for path in files {
        if !path.exists() {
            continue;
        }
        let raw = fs::read_to_string(&path)
            .map_err(|e| KernelError::InitFailed(format!("read {}: {e}", path.display())))?;
        let rel = path
            .strip_prefix(&repo)
            .unwrap_or(&path)
            .to_string_lossy()
            .replace('\\', "/");
        sources.push(system_source(
            RagSourceKind::OperatorDocs,
            format!("docs:{rel}"),
            Some(rel.clone()),
            first_markdown_heading(&raw).unwrap_or_else(|| rel.clone()),
            vec!["docs".into(), "operator".into()],
            raw,
            "local_docs",
            true,
            false,
        ));
    }
    Ok(())
}

fn collect_command_catalog(sources: &mut Vec<CollectedSource>) -> Result<(), KernelError> {
    for command in command_catalog() {
        let tags = command
            .surfaces
            .iter()
            .map(|surface| surface.label().to_string())
            .collect::<Vec<_>>();
        let text = format!(
            "# {}\n\n{}\n\nGroup: {}\nSurfaces: {}\nCommand id: {}\n",
            command.display,
            command.summary,
            command.group.label(),
            command
                .surfaces
                .iter()
                .map(|surface| surface.label())
                .collect::<Vec<_>>()
                .join(", "),
            command.id
        );
        sources.push(system_source(
            RagSourceKind::CommandCatalog,
            format!("command:{}", command.id),
            None,
            command.display.into(),
            tags,
            text,
            "generated_public",
            true,
            false,
        ));
    }
    Ok(())
}

fn collect_settings_catalog(sources: &mut Vec<CollectedSource>) {
    for setting in settings_catalog() {
        sources.push(setting_source(&setting));
    }
}

fn setting_source(setting: &SettingDescriptor) -> CollectedSource {
    let text = format!(
        "# {}\n\n{}\n\nKey: {}\nDefault: {}\nRestart: {}\nSafety: {}\n",
        setting.label,
        setting.description,
        setting.key,
        setting.default_value,
        setting.restart.label(),
        setting.safety_note
    );
    system_source(
        RagSourceKind::SettingsCatalog,
        format!("setting:{}", setting.key),
        None,
        setting.key.into(),
        vec![setting.group.id().into(), "settings".into()],
        text,
        "generated_local",
        true,
        false,
    )
}

fn collect_skill_metadata(
    paths: &AllbertPaths,
    config: &Config,
    sources: &mut Vec<CollectedSource>,
) {
    let skills = SkillStore::discover(&paths.skills);
    for skill in skills.all() {
        let intents = skill
            .intents
            .iter()
            .map(|intent| intent.as_str())
            .collect::<Vec<_>>();
        let agents = skill
            .agents
            .iter()
            .map(|agent| agent.name.as_str())
            .collect::<Vec<_>>();
        let body = if config.rag.include_inactive_skill_bodies {
            format!("\n\n## Body\n\n{}", truncate_to_bytes(&skill.body, 4096))
        } else {
            String::new()
        };
        let text = format!(
            "# {}\n\n{}\n\nProvenance: {}\nIntents: {}\nAgents: {}\nAllowed tools: {}{}",
            skill.name,
            skill.description,
            skill.provenance.label(),
            intents.join(", "),
            agents.join(", "),
            skill.allowed_tools.join(", "),
            body
        );
        sources.push(system_source(
            RagSourceKind::SkillsMetadata,
            format!("skill:installed:{}", skill.name),
            Some(path_display_under(&skill.path, &paths.root)),
            skill.name.clone(),
            vec!["skills".into(), skill.provenance.label().into()],
            text,
            "local_metadata",
            true,
            false,
        ));
    }
}

fn write_sources<F>(
    conn: &mut Connection,
    config: &Config,
    sources: &[CollectedSource],
    should_cancel: &F,
) -> Result<usize, KernelError>
where
    F: Fn() -> bool,
{
    let tx = conn.transaction().map_err(sql_err)?;
    let now = chrono::Utc::now().to_rfc3339();
    let mut chunk_total = 0;
    let collections = collection_catalog_from_sources(config, sources)?;
    let mut collection_ids = HashMap::new();
    for entry in collections {
        let id = insert_collection_catalog(&tx, config, &entry, sources)?;
        collection_ids.insert(
            (
                entry.collection_type.label().to_string(),
                entry.collection_name,
            ),
            id,
        );
    }
    for source in sources {
        if should_cancel() {
            return Err(KernelError::Request(RAG_REBUILD_CANCELLED.into()));
        }
        let collection_fk = *collection_ids
            .get(&(
                source.collection_type.label().to_string(),
                source.collection_name.clone(),
            ))
            .ok_or_else(|| {
                KernelError::InitFailed(format!(
                    "missing RAG collection {}:{}",
                    source.collection_type.label(),
                    source.collection_name
                ))
            })?;
        let tags_json = serde_json::to_string(&source.tags)
            .map_err(|e| KernelError::InitFailed(format!("serialize source tags: {e}")))?;
        let source_hash = hash_text(&source.text);
        tx.execute(
            "INSERT INTO rag_sources
             (collection_fk, source_kind, source_id, parent_source_id, source_path,
              source_uri, title, tags_json, content_hash, privacy_tier,
              prompt_eligible, review_only, stale, ingest_state, created_at, updated_at,
              last_ingested_at, last_indexed_at, fetched_at, http_status, http_etag,
              http_last_modified, http_content_type, final_url, robots_allowed,
              last_error, last_error_at)
             VALUES (?1, ?2, ?3, NULL, ?4, ?5, ?6, ?7, ?8, ?9, ?10, ?11, 0,
                     ?12, ?13, ?13, ?13, ?13, ?13, ?14, ?15, ?16, ?17, ?18,
                     ?19, ?20, ?21)",
            params![
                collection_fk,
                source.kind.label(),
                source.source_id,
                source.source_path,
                source.source_uri,
                source.title,
                tags_json,
                source_hash,
                source.privacy_tier,
                bool_int(source.prompt_eligible),
                bool_int(source.review_only),
                source.ingest_state,
                now,
                source.http_status,
                source.http_etag,
                source.http_last_modified,
                source.http_content_type,
                source.final_url,
                source.robots_allowed.map(bool_int),
                source.last_error,
                source.last_error.as_ref().map(|_| now.clone()),
            ],
        )
        .map_err(sql_err)?;
        let source_fk = tx.last_insert_rowid();
        let chunks = chunk_source(config, source);
        for chunk in chunks {
            if should_cancel() {
                return Err(KernelError::Request(RAG_REBUILD_CANCELLED.into()));
            }
            let provenance_json = json!({
                "source_id": source.source_id,
                "source_path": source.source_path,
                "heading_path": chunk.heading_path,
                "ordinal": chunk.ordinal,
            })
            .to_string();
            tx.execute(
                "INSERT INTO rag_chunks
                 (collection_fk, source_fk, chunk_id, ordinal, title, heading_path, text, byte_len,
                  token_estimate, tags, collection_type, collection_name, source_kind, labels, provenance_json,
                  prompt_eligible, review_only, content_hash, embedding_state, updated_at)
                 VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8, ?9, ?10, ?11, ?12,
                         ?13, ?14, ?15, ?16, ?17, ?18, 'missing', ?19)",
                params![
                    collection_fk,
                    source_fk,
                    chunk.chunk_id,
                    chunk.ordinal as i64,
                    chunk.title,
                    chunk.heading_path,
                    chunk.text,
                    chunk.text.len() as i64,
                    token_estimate(&chunk.text) as i64,
                    chunk.tags.join(" "),
                    source.collection_type.label(),
                    source.collection_name,
                    source.kind.label(),
                    chunk.labels.join(" "),
                    provenance_json,
                    bool_int(chunk.prompt_eligible),
                    bool_int(chunk.review_only),
                    chunk.content_hash,
                    now,
                ],
            )
            .map_err(sql_err)?;
            let rowid = tx.last_insert_rowid();
            tx.execute(
                "INSERT INTO rag_chunks_fts
                 (rowid, title, text, tags, source_kind, collection_type, collection_name, labels)
                 VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8)",
                params![
                    rowid,
                    chunk.title,
                    chunk.text,
                    chunk.tags.join(" "),
                    source.kind.label(),
                    source.collection_type.label(),
                    source.collection_name,
                    chunk.labels.join(" "),
                ],
            )
            .map_err(sql_err)?;
            chunk_total += 1;
        }
    }
    tx.commit().map_err(sql_err)?;
    Ok(chunk_total)
}

fn collection_catalog_from_sources(
    config: &Config,
    sources: &[CollectedSource],
) -> Result<Vec<CollectionCatalogEntry>, KernelError> {
    let mut by_key: BTreeMap<(RagCollectionType, String), Vec<&CollectedSource>> = BTreeMap::new();
    for source in sources {
        by_key
            .entry((source.collection_type, source.collection_name.clone()))
            .or_default()
            .push(source);
    }
    let mut entries = Vec::new();
    for ((collection_type, collection_name), group) in by_key {
        let first = group[0];
        let (source_uri, title, description, privacy_tier, prompt_eligible, review_only) =
            if collection_type == RagCollectionType::System {
                let (_, uri, title) = system_collection_for_kind(first.kind);
                (
                    uri.to_string(),
                    title.to_string(),
                    String::new(),
                    first.privacy_tier.to_string(),
                    group.iter().any(|source| source.prompt_eligible),
                    group.iter().all(|source| source.review_only),
                )
            } else {
                (
                    first.source_uri.clone(),
                    collection_name.clone(),
                    String::new(),
                    first.privacy_tier.to_string(),
                    false,
                    group.iter().all(|source| source.review_only),
                )
            };
        let mut hasher = Sha256::new();
        for source in &group {
            hasher.update(&source.source_id);
            hasher.update(&source.text);
        }
        let content_hash = format!("{:x}", hasher.finalize());
        entries.push(CollectionCatalogEntry {
            collection_type,
            collection_name,
            source_uri,
            title,
            description,
            privacy_tier,
            prompt_eligible,
            review_only,
            manifest_path: None,
            manifest_hash: content_hash,
            fetch_policy_json: serde_json::to_string(&config.rag.ingest)
                .unwrap_or_else(|_| "{}".into()),
        });
    }
    Ok(entries)
}

fn insert_collection_catalog(
    conn: &Connection,
    _config: &Config,
    entry: &CollectionCatalogEntry,
    sources: &[CollectedSource],
) -> Result<i64, KernelError> {
    let now = chrono::Utc::now().to_rfc3339();
    let content_hash = if sources.is_empty() {
        entry.manifest_hash.clone()
    } else {
        let mut hasher = Sha256::new();
        for source in sources.iter().filter(|source| {
            source.collection_type == entry.collection_type
                && source.collection_name == entry.collection_name
        }) {
            hasher.update(&source.source_id);
            hasher.update(&source.text);
        }
        format!("{:x}", hasher.finalize())
    };
    conn.execute(
        "INSERT INTO rag_collections
         (collection_type, collection_name, source_uri, manifest_path, manifest_hash,
          title, description, privacy_tier, prompt_eligible, review_only, enabled,
          stale, content_hash, created_at, updated_at, last_ingested_at, last_indexed_at,
          fetch_policy_json)
         VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8, ?9, ?10, 1, 0, ?11, ?12, ?12,
                 ?12, ?12, ?13)
         ON CONFLICT(collection_type, collection_name) DO UPDATE SET
           source_uri = excluded.source_uri,
           manifest_path = excluded.manifest_path,
           manifest_hash = excluded.manifest_hash,
           title = excluded.title,
           description = excluded.description,
           privacy_tier = excluded.privacy_tier,
           prompt_eligible = excluded.prompt_eligible,
           review_only = excluded.review_only,
           stale = excluded.stale,
           content_hash = excluded.content_hash,
           updated_at = excluded.updated_at,
           last_ingested_at = excluded.last_ingested_at,
           last_indexed_at = excluded.last_indexed_at,
           fetch_policy_json = excluded.fetch_policy_json",
        params![
            entry.collection_type.label(),
            entry.collection_name,
            entry.source_uri,
            entry.manifest_path,
            entry.manifest_hash,
            entry.title,
            entry.description,
            entry.privacy_tier,
            bool_int(entry.prompt_eligible),
            bool_int(entry.review_only),
            content_hash,
            now,
            entry.fetch_policy_json,
        ],
    )
    .map_err(sql_err)?;
    conn.query_row(
        "SELECT id FROM rag_collections WHERE collection_type = ?1 AND collection_name = ?2",
        params![entry.collection_type.label(), entry.collection_name],
        |row| row.get::<_, i64>(0),
    )
    .map_err(sql_err)
}

fn chunk_source(config: &Config, source: &CollectedSource) -> Vec<RagChunk> {
    let max_bytes = config.rag.max_chunk_bytes.max(256);
    let mut chunks = Vec::new();
    let mut heading = source.title.clone();
    let mut body = String::new();
    let mut ordinal = 0usize;

    for line in source.text.lines() {
        if line.starts_with('#') && !body.trim().is_empty() {
            push_chunk(&mut chunks, source, &heading, &body, ordinal, max_bytes);
            ordinal += 1;
            body.clear();
        }
        if line.starts_with('#') {
            heading = line.trim_start_matches('#').trim().to_string();
        }
        body.push_str(line);
        body.push('\n');
    }
    if !body.trim().is_empty() {
        push_chunk(&mut chunks, source, &heading, &body, ordinal, max_bytes);
    }
    chunks
}

fn push_chunk(
    chunks: &mut Vec<RagChunk>,
    source: &CollectedSource,
    heading: &str,
    body: &str,
    ordinal: usize,
    max_bytes: usize,
) {
    for (part, text) in split_by_bytes(body.trim(), max_bytes)
        .into_iter()
        .enumerate()
    {
        let chunk_title = if part == 0 {
            heading.to_string()
        } else {
            format!("{heading} part {}", part + 1)
        };
        let content_hash = hash_text(&text);
        chunks.push(RagChunk {
            chunk_id: format!("{}#chunk-{ordinal}-{part}", source.source_id),
            ordinal: ordinal + part,
            title: chunk_title,
            heading_path: Some(heading.to_string()),
            text,
            tags: source.tags.clone(),
            labels: vec![source.privacy_tier.into()],
            prompt_eligible: source.prompt_eligible,
            review_only: source.review_only,
            content_hash,
        });
    }
}

fn split_by_bytes(value: &str, max_bytes: usize) -> Vec<String> {
    if value.len() <= max_bytes {
        return vec![value.to_string()];
    }
    let mut chunks = Vec::new();
    let mut current = String::new();
    for line in value.lines() {
        if !current.is_empty() && current.len() + line.len() + 1 > max_bytes {
            chunks.push(current.trim().to_string());
            current.clear();
        }
        if line.len() > max_bytes {
            for part in line.as_bytes().chunks(max_bytes) {
                chunks.push(String::from_utf8_lossy(part).trim().to_string());
            }
        } else {
            current.push_str(line);
            current.push('\n');
        }
    }
    if !current.trim().is_empty() {
        chunks.push(current.trim().to_string());
    }
    chunks
}

fn insert_run(
    conn: &Connection,
    run_id: &str,
    request: &RagRebuildRequest,
    requested_sources_json: &str,
    requested_collections_json: &str,
    record: RunWrite<'_>,
) -> Result<(), KernelError> {
    conn.execute(
        "INSERT OR REPLACE INTO rag_index_runs
         (run_id, trigger, requested_collections_json, requested_sources_json,
          include_vectors, stale_only, status,
          started_at, finished_at, source_count, chunk_count, vector_count, skipped_count,
          elapsed_ms, error)
         VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8, ?9, ?10, ?11, ?12, ?13, ?14, ?15)",
        params![
            run_id,
            request.trigger,
            requested_collections_json,
            requested_sources_json,
            bool_int(request.include_vectors),
            bool_int(request.stale_only),
            record.status.label(),
            chrono::Utc::now().to_rfc3339(),
            if matches!(record.status, RagIndexRunStatus::Running) {
                None::<String>
            } else {
                Some(chrono::Utc::now().to_rfc3339())
            },
            record.source_count as i64,
            record.chunk_count as i64,
            record.vector_count as i64,
            record.skipped_count as i64,
            record.elapsed_ms as i64,
            record.error,
        ],
    )
    .map_err(sql_err)?;
    Ok(())
}

fn finish_run(conn: &Connection, run_id: &str, record: RunWrite<'_>) -> Result<(), KernelError> {
    conn.execute(
        "UPDATE rag_index_runs
         SET status = ?2, finished_at = ?3, source_count = ?4, chunk_count = ?5,
             vector_count = ?6, skipped_count = ?7, elapsed_ms = ?8, error = ?9
         WHERE run_id = ?1",
        params![
            run_id,
            record.status.label(),
            chrono::Utc::now().to_rfc3339(),
            record.source_count as i64,
            record.chunk_count as i64,
            record.vector_count as i64,
            record.skipped_count as i64,
            record.elapsed_ms as i64,
            record.error,
        ],
    )
    .map_err(sql_err)?;
    Ok(())
}

fn count_table(conn: &Connection, table: &str) -> Result<usize, KernelError> {
    let sql = match table {
        "rag_collections" => "SELECT COUNT(*) FROM rag_collections",
        "rag_sources" => "SELECT COUNT(*) FROM rag_sources",
        "rag_chunks" => "SELECT COUNT(*) FROM rag_chunks",
        _ => {
            return Err(KernelError::InitFailed(format!(
                "unsupported RAG table {table}"
            )))
        }
    };
    conn.query_row(sql, [], |row| row.get::<_, i64>(0))
        .map(|value| value as usize)
        .map_err(sql_err)
}

fn get_meta(conn: &Connection, key: &str) -> Result<Option<String>, KernelError> {
    conn.query_row("SELECT value FROM rag_meta WHERE key = ?1", [key], |row| {
        row.get(0)
    })
    .optional()
    .map_err(sql_err)
}

fn set_meta(conn: &Connection, key: &str, value: &str) -> Result<(), KernelError> {
    conn.execute(
        "INSERT INTO rag_meta (key, value, updated_at)
         VALUES (?1, ?2, ?3)
         ON CONFLICT(key) DO UPDATE SET value = excluded.value, updated_at = excluded.updated_at",
        params![key, value, chrono::Utc::now().to_rfc3339()],
    )
    .map_err(sql_err)?;
    Ok(())
}

fn register_sqlite_vec() {
    unsafe {
        // SAFETY: sqlite-vec documents registration through sqlite3_auto_extension
        // with its C entrypoint. The function pointer is process-global and
        // rusqlite owns later connection lifetimes.
        let entrypoint = std::mem::transmute::<*const (), SqliteExtensionInit>(
            sqlite_vec::sqlite3_vec_init as *const (),
        );
        rusqlite::ffi::sqlite3_auto_extension(Some(entrypoint));
    }
}

fn repo_root() -> Option<PathBuf> {
    PathBuf::from(env!("CARGO_MANIFEST_DIR"))
        .parent()
        .and_then(Path::parent)
        .map(Path::to_path_buf)
}

fn markdown_files(root: &Path) -> Result<Vec<PathBuf>, KernelError> {
    let mut files = Vec::new();
    if !root.exists() {
        return Ok(files);
    }
    collect_markdown_files(root, &mut files)?;
    Ok(files)
}

fn collect_markdown_files(root: &Path, files: &mut Vec<PathBuf>) -> Result<(), KernelError> {
    for entry in fs::read_dir(root)
        .map_err(|e| KernelError::InitFailed(format!("read {}: {e}", root.display())))?
    {
        let entry = entry
            .map_err(|e| KernelError::InitFailed(format!("read {} entry: {e}", root.display())))?;
        let path = entry.path();
        if path.is_dir() {
            collect_markdown_files(&path, files)?;
        } else if path.extension().is_some_and(|ext| ext == "md") {
            files.push(path);
        }
    }
    Ok(())
}

fn first_markdown_heading(raw: &str) -> Option<String> {
    raw.lines()
        .find(|line| line.starts_with("# "))
        .map(|line| line.trim_start_matches('#').trim().to_string())
}

fn hash_sources(sources: &[CollectedSource]) -> String {
    let mut hasher = Sha256::new();
    for source in sources {
        hasher.update(source.kind.label());
        hasher.update(&source.source_id);
        hasher.update(&source.text);
    }
    format!("{:x}", hasher.finalize())
}

fn hash_text(value: &str) -> String {
    let mut hasher = Sha256::new();
    hasher.update(value.as_bytes());
    format!("{:x}", hasher.finalize())
}

fn fts_match_expression(query: &str) -> String {
    query
        .split_whitespace()
        .filter_map(|term| {
            let cleaned = term
                .trim_matches(|ch: char| !ch.is_ascii_alphanumeric() && ch != '_' && ch != '-')
                .replace('"', "");
            if cleaned.is_empty() {
                None
            } else {
                Some(format!("\"{cleaned}\""))
            }
        })
        .collect::<Vec<_>>()
        .join(" OR ")
}

fn token_estimate(value: &str) -> usize {
    value.split_whitespace().count().max(1)
}

fn truncate_to_bytes(value: &str, max_bytes: usize) -> String {
    if value.len() <= max_bytes {
        return value.to_string();
    }
    let mut end = max_bytes;
    while !value.is_char_boundary(end) {
        end -= 1;
    }
    format!("{}...", value[..end].trim_end())
}

fn path_display_under(path: &Path, root: &Path) -> String {
    path.strip_prefix(root)
        .unwrap_or(path)
        .to_string_lossy()
        .replace('\\', "/")
}

fn bool_int(value: bool) -> i64 {
    i64::from(value)
}

fn sql_err(error: rusqlite::Error) -> KernelError {
    KernelError::InitFailed(format!("rag sqlite: {error}"))
}

trait RagStatusLabel {
    fn label(self) -> &'static str;
}

impl RagStatusLabel for RagVectorPosture {
    fn label(self) -> &'static str {
        match self {
            Self::Healthy => "healthy",
            Self::Disabled => "disabled",
            Self::MissingModel => "missing_model",
            Self::Stale => "stale",
            Self::Degraded => "degraded",
            Self::Unavailable => "unavailable",
        }
    }
}

trait RagRunStatusLabel {
    fn label(self) -> &'static str;
}

impl RagRunStatusLabel for RagIndexRunStatus {
    fn label(self) -> &'static str {
        match self {
            Self::Pending => "pending",
            Self::Running => "running",
            Self::Succeeded => "succeeded",
            Self::Skipped => "skipped",
            Self::Cancelled => "cancelled",
            Self::Failed => "failed",
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::fs;
    use std::sync::atomic::Ordering;

    fn temp_paths() -> (tempfile::TempDir, AllbertPaths) {
        let temp = tempfile::tempdir().expect("tempdir");
        let paths = AllbertPaths::under(temp.path().join("home"));
        paths.ensure().expect("paths should initialize");
        Config::default_template()
            .persist(&paths)
            .expect("config should persist");
        (temp, paths)
    }

    fn fake_vector_config() -> Config {
        let mut config = Config::default_template();
        config.rag.vector.enabled = true;
        config.rag.vector.provider = RagEmbeddingProvider::Fake;
        config.rag.vector.model = "fake-8d".into();
        config.rag.vector.retry_attempts = 0;
        config
    }

    #[test]
    fn sqlite_vec_registers_with_bundled_rusqlite() {
        let version = sqlite_vec_dependency_probe().expect("sqlite-vec should register");
        assert!(
            version.starts_with("v0.") || version.starts_with("0."),
            "unexpected sqlite-vec version {version}"
        );
    }

    #[test]
    fn blocking_http_helper_does_not_drop_reqwest_runtime_inside_tokio() {
        let runtime = tokio::runtime::Runtime::new().expect("runtime");
        runtime.block_on(async {
            let result = run_blocking_http(
                || {
                    let _client = reqwest::blocking::Client::builder()
                        .timeout(Duration::from_millis(10))
                        .build()
                        .map_err(|e| EmbeddingError::new(e.to_string()))?;
                    Ok::<_, EmbeddingError>(())
                },
                EmbeddingError::new,
            );
            assert!(result.is_ok());
        });
    }

    #[test]
    fn rebuild_status_and_search_use_lexical_sqlite() {
        let (_temp, paths) = temp_paths();
        let config = Config::default_template();
        let summary = rebuild_rag_index(
            &paths,
            &config,
            RagRebuildRequest {
                stale_only: false,
                sources: vec![
                    RagSourceKind::CommandCatalog,
                    RagSourceKind::SettingsCatalog,
                    RagSourceKind::SkillsMetadata,
                ],
                collection_type: None,
                collections: Vec::new(),
                include_vectors: false,
                trigger: "test".into(),
            },
        )
        .expect("rebuild should succeed");
        assert_eq!(summary.status, RagIndexRunStatus::Succeeded);
        assert!(summary.source_count > 0);
        assert!(summary.chunk_count > 0);

        let status = rag_status(&paths, &config).expect("status should read");
        assert_eq!(status.source_count, summary.source_count);
        assert_eq!(status.vector_posture, RagVectorPosture::Disabled);

        let search = search_rag(
            &paths,
            &config,
            RagSearchRequest {
                query: "settings".into(),
                sources: vec![
                    RagSourceKind::CommandCatalog,
                    RagSourceKind::SettingsCatalog,
                ],
                collection_type: None,
                collections: Vec::new(),
                mode: Some(RagRetrievalMode::Lexical),
                limit: Some(5),
                include_review_only: false,
            },
        )
        .expect("search should succeed");
        assert!(!search.results.is_empty());
        assert!(search
            .results
            .iter()
            .all(|result| result.source_kind != RagSourceKind::StagedMemoryReview));
    }

    #[test]
    fn controlled_rebuild_can_cancel_before_publish() {
        let (_temp, paths) = temp_paths();
        let config = Config::default_template();
        let summary = rebuild_rag_index_with_control(
            &paths,
            &config,
            RagRebuildRequest {
                stale_only: false,
                sources: vec![RagSourceKind::CommandCatalog],
                collection_type: None,
                collections: Vec::new(),
                include_vectors: false,
                trigger: "test-cancel".into(),
            },
            "rag-test-cancel".into(),
            || true,
        )
        .expect("cancelled rebuild should report cleanly");
        assert_eq!(summary.run_id, "rag-test-cancel");
        assert_eq!(summary.status, RagIndexRunStatus::Cancelled);
        assert!(!paths.rag_db.exists());
    }

    #[test]
    fn stale_only_rebuild_skips_unchanged_corpus() {
        let (_temp, paths) = temp_paths();
        let config = Config::default_template();
        rebuild_rag_index(
            &paths,
            &config,
            RagRebuildRequest {
                stale_only: false,
                sources: vec![RagSourceKind::CommandCatalog],
                collection_type: None,
                collections: Vec::new(),
                include_vectors: false,
                trigger: "test".into(),
            },
        )
        .expect("initial rebuild should succeed");
        let skipped = rebuild_rag_index(
            &paths,
            &config,
            RagRebuildRequest {
                stale_only: true,
                sources: vec![RagSourceKind::CommandCatalog],
                collection_type: None,
                collections: Vec::new(),
                include_vectors: false,
                trigger: "test".into(),
            },
        )
        .expect("stale-only rebuild should inspect corpus");
        assert_eq!(skipped.status, RagIndexRunStatus::Skipped);
        assert_eq!(skipped.message, "nothing stale");
    }

    #[test]
    fn schema_v2_reinitializes_v1_rag_database_with_collections() {
        let (_temp, paths) = temp_paths();
        let config = Config::default_template();
        let conn = Connection::open(&paths.rag_db).expect("old rag db should open");
        conn.execute_batch(
            "CREATE TABLE rag_sources (
               id INTEGER PRIMARY KEY,
               source_kind TEXT NOT NULL,
               source_id TEXT NOT NULL
             );",
        )
        .expect("old v1 source table should create");
        drop(conn);

        let status = rag_status(&paths, &config).expect("status should migrate schema");
        assert_eq!(status.collection_count, 0);
        let conn = open_rag_db(&paths).expect("db should reopen");
        assert!(table_exists(&conn, "rag_collections").expect("table check should work"));
        assert!(raw_column_exists(&conn, "rag_sources", "collection_fk")
            .expect("column check should work"));
        assert_eq!(
            get_meta(&conn, "schema_version")
                .expect("schema version should read")
                .as_deref(),
            Some("2")
        );
    }

    #[test]
    fn user_collection_local_ingest_search_filters_and_access_timestamps() {
        let (_temp, paths) = temp_paths();
        let corpus = paths.root.join("trusted-corpus");
        fs::create_dir_all(&corpus).unwrap();
        fs::write(
            corpus.join("notes.md"),
            "# Cobalt Plateau\n\nThe Cobalt Plateau runbook lives in the user collection only.\n",
        )
        .unwrap();
        let mut config = Config::default_template();
        config.security.fs_roots = vec![corpus.clone()];

        let created = create_rag_collection(
            &paths,
            &config,
            RagCollectionCreateRequest {
                collection_name: "Project Notes".into(),
                title: Some("Project Notes".into()),
                description: Some("Task corpus".into()),
                source_uris: vec![corpus.to_string_lossy().to_string()],
                fetch_policy: RagFetchPolicy::default(),
            },
        )
        .expect("collection should be created");
        assert_eq!(created.collection_type, RagCollectionType::User);
        assert_eq!(created.collection_name, "project-notes");
        assert!(created.manifest_path.as_ref().unwrap().exists());

        let listed = list_rag_collections(&paths, &config, Some(RagCollectionType::User)).unwrap();
        assert!(listed
            .iter()
            .any(|collection| collection.collection_name == "project-notes"));

        let summary = rebuild_rag_index(
            &paths,
            &config,
            RagRebuildRequest {
                stale_only: false,
                sources: Vec::new(),
                collection_type: Some(RagCollectionType::User),
                collections: vec!["project-notes".into()],
                include_vectors: false,
                trigger: "test-user-collection".into(),
            },
        )
        .expect("user collection should rebuild");
        assert_eq!(summary.status, RagIndexRunStatus::Succeeded);
        assert_eq!(summary.source_count, 1);
        assert!(summary.chunk_count > 0);

        let user_hits = search_rag(
            &paths,
            &config,
            RagSearchRequest {
                query: "Cobalt Plateau runbook".into(),
                sources: vec![RagSourceKind::UserDocument],
                collection_type: Some(RagCollectionType::User),
                collections: vec!["project-notes".into()],
                mode: Some(RagRetrievalMode::Lexical),
                limit: Some(5),
                include_review_only: false,
            },
        )
        .expect("user collection search should work");
        assert!(!user_hits.results.is_empty());
        assert!(user_hits.results.iter().all(|result| {
            result.collection_type == RagCollectionType::User
                && result.collection_name == "project-notes"
                && result.source_kind == RagSourceKind::UserDocument
        }));

        let system_hits = search_rag(
            &paths,
            &config,
            RagSearchRequest {
                query: "Cobalt Plateau runbook".into(),
                sources: Vec::new(),
                collection_type: Some(RagCollectionType::System),
                collections: Vec::new(),
                mode: Some(RagRetrievalMode::Lexical),
                limit: Some(5),
                include_review_only: false,
            },
        )
        .expect("system-filtered search should work");
        assert!(system_hits.results.is_empty());

        let listed = list_rag_collections(&paths, &config, Some(RagCollectionType::User)).unwrap();
        let collection = listed
            .iter()
            .find(|collection| collection.collection_name == "project-notes")
            .expect("collection should list after search");
        assert_eq!(collection.source_count, 1);
        assert!(collection.chunk_count > 0);
        assert!(collection.last_accessed_at.is_some());

        fs::write(
            corpus.join("notes.md"),
            "# Amber Plateau\n\nThe Amber Plateau update should force a stale-only rebuild.\n",
        )
        .unwrap();
        let stale_rebuild = rebuild_rag_index(
            &paths,
            &config,
            RagRebuildRequest {
                stale_only: true,
                sources: Vec::new(),
                collection_type: Some(RagCollectionType::User),
                collections: vec!["project-notes".into()],
                include_vectors: false,
                trigger: "test-user-collection-stale".into(),
            },
        )
        .expect("changed user collection should rebuild on stale-only");
        assert_eq!(stale_rebuild.status, RagIndexRunStatus::Succeeded);
        let amber_hits = search_rag(
            &paths,
            &config,
            RagSearchRequest {
                query: "Amber Plateau update".into(),
                sources: vec![RagSourceKind::UserDocument],
                collection_type: Some(RagCollectionType::User),
                collections: vec!["project-notes".into()],
                mode: Some(RagRetrievalMode::Lexical),
                limit: Some(5),
                include_review_only: false,
            },
        )
        .expect("changed user collection should be searchable");
        assert!(!amber_hits.results.is_empty());

        delete_rag_collection(&paths, "project-notes").expect("collection should delete");
        let listed = list_rag_collections(&paths, &config, Some(RagCollectionType::User)).unwrap();
        assert!(!listed
            .iter()
            .any(|collection| collection.collection_name == "project-notes"));
    }

    #[test]
    fn user_collection_url_sources_reject_localhost_and_private_ips() {
        let (_temp, paths) = temp_paths();
        let mut config = Config::default_template();
        config.rag.ingest.allowed_url_schemes = vec!["https".into(), "http".into()];
        let mut policy = RagFetchPolicy {
            allow_insecure_http: true,
            ..RagFetchPolicy::default()
        };
        policy.respect_robots_txt = false;

        let localhost = create_rag_collection(
            &paths,
            &config,
            RagCollectionCreateRequest {
                collection_name: "localhost".into(),
                title: None,
                description: None,
                source_uris: vec!["http://localhost:8000/notes".into()],
                fetch_policy: policy.clone(),
            },
        )
        .expect_err("localhost URL source should be rejected");
        assert!(localhost.to_string().contains("localhost"));

        let private = create_rag_collection(
            &paths,
            &config,
            RagCollectionCreateRequest {
                collection_name: "private".into(),
                title: None,
                description: None,
                source_uris: vec!["http://127.0.0.1:8000/notes".into()],
                fetch_policy: policy,
            },
        )
        .expect_err("private URL source should be rejected");
        assert!(private.to_string().contains("disallowed address"));
    }

    #[test]
    fn user_collection_local_ingest_enforces_trusted_roots_and_file_caps() {
        let (_temp, paths) = temp_paths();
        let trusted = paths.root.join("trusted");
        let untrusted = paths.root.join("untrusted");
        fs::create_dir_all(&trusted).unwrap();
        fs::create_dir_all(&untrusted).unwrap();
        fs::write(untrusted.join("notes.md"), "# Outside\n\nNope.\n").unwrap();
        let mut config = Config::default_template();
        config.security.fs_roots = vec![trusted.clone()];

        let outside = create_rag_collection(
            &paths,
            &config,
            RagCollectionCreateRequest {
                collection_name: "outside".into(),
                title: None,
                description: None,
                source_uris: vec![untrusted.join("notes.md").to_string_lossy().to_string()],
                fetch_policy: RagFetchPolicy::default(),
            },
        )
        .expect_err("untrusted local source should be rejected");
        assert!(outside.to_string().contains("outside configured roots"));

        fs::write(
            trusted.join("large.md"),
            "# Too Large\n\nThis file is larger than the configured cap.\n",
        )
        .unwrap();
        config.rag.ingest.max_file_bytes = 8;
        config.rag.ingest.max_collection_bytes = 64;
        create_rag_collection(
            &paths,
            &config,
            RagCollectionCreateRequest {
                collection_name: "capped".into(),
                title: None,
                description: None,
                source_uris: vec![trusted.join("large.md").to_string_lossy().to_string()],
                fetch_policy: RagFetchPolicy::default(),
            },
        )
        .expect("capped collection should create");
        rebuild_rag_index(
            &paths,
            &config,
            RagRebuildRequest {
                stale_only: false,
                sources: Vec::new(),
                collection_type: Some(RagCollectionType::User),
                collections: vec!["capped".into()],
                include_vectors: false,
                trigger: "test-user-collection-caps".into(),
            },
        )
        .expect("capped collection should rebuild with an error source");
        let conn = open_rag_db(&paths).expect("db should open");
        let (state, error): (String, Option<String>) = conn
            .query_row(
                "SELECT ingest_state, last_error FROM rag_sources WHERE source_kind = 'user_document'",
                [],
                |row| Ok((row.get(0)?, row.get(1)?)),
            )
            .expect("error source should be indexed");
        assert_eq!(state, "error");
        assert!(error.unwrap_or_default().contains("file exceeds cap"));
    }

    #[test]
    fn web_collection_link_extraction_is_same_origin_and_policy_checked() {
        let mut config = Config::default_template();
        config.rag.ingest.allowed_url_schemes = vec!["https".into()];
        let policy = RagFetchPolicy::default();
        let base = reqwest::Url::parse("https://93.184.216.34/docs/index.html").unwrap();
        let links = extract_html_links(
            r#"
            <a href="/docs/next.html">next</a>
            <a HREF='https://93.184.216.34/docs/next.html#section'>dupe</a>
            <a href="https://93.184.216.35/docs/off-origin.html">off</a>
            <a href="http://93.184.216.34/docs/insecure.html">scheme</a>
            "#,
            &base,
            &config,
            &policy,
        );
        assert_eq!(links.len(), 1);
        assert_eq!(links[0].as_str(), "https://93.184.216.34/docs/next.html");
    }

    #[test]
    fn doctor_reports_missing_and_healthy_index() {
        let (_temp, paths) = temp_paths();
        let config = Config::default_template();
        let missing = rag_doctor(&paths, &config).expect("missing doctor should return");
        assert!(!missing.ok);
        assert!(!missing.db_exists);

        rebuild_rag_index(
            &paths,
            &config,
            RagRebuildRequest {
                stale_only: false,
                sources: vec![RagSourceKind::SettingsCatalog],
                collection_type: None,
                collections: Vec::new(),
                include_vectors: false,
                trigger: "test".into(),
            },
        )
        .expect("rebuild should succeed");
        let healthy = rag_doctor(&paths, &config).expect("healthy doctor should return");
        assert!(healthy.ok, "{:?}", healthy.issues);
        assert!(healthy.db_exists);
        assert_eq!(healthy.schema_version.as_deref(), Some("2"));
    }

    #[test]
    fn rebuild_indexes_fake_vectors_and_hybrid_searches() {
        let (_temp, paths) = temp_paths();
        let config = fake_vector_config();
        let summary = rebuild_rag_index(
            &paths,
            &config,
            RagRebuildRequest {
                stale_only: false,
                sources: vec![
                    RagSourceKind::SettingsCatalog,
                    RagSourceKind::CommandCatalog,
                ],
                collection_type: None,
                collections: Vec::new(),
                include_vectors: true,
                trigger: "test".into(),
            },
        )
        .expect("vector rebuild should succeed");
        assert_eq!(summary.status, RagIndexRunStatus::Succeeded);
        assert!(summary.vector_count > 0);

        let status = rag_status(&paths, &config).expect("status should read");
        assert_eq!(status.vector_posture, RagVectorPosture::Healthy);
        assert_eq!(status.active_dimension, Some(8));
        assert_eq!(status.vector_count, summary.vector_count);

        let hybrid = search_rag(
            &paths,
            &config,
            RagSearchRequest {
                query: "settings catalog".into(),
                sources: vec![RagSourceKind::SettingsCatalog],
                collection_type: None,
                collections: Vec::new(),
                mode: Some(RagRetrievalMode::Hybrid),
                limit: Some(5),
                include_review_only: false,
            },
        )
        .expect("hybrid search should succeed");
        assert_eq!(hybrid.mode, RagRetrievalMode::Hybrid);
        assert_eq!(hybrid.vector_posture, RagVectorPosture::Healthy);
        assert!(!hybrid.results.is_empty());
        assert!(hybrid
            .results
            .iter()
            .all(|result| result.source_kind == RagSourceKind::SettingsCatalog));

        let vector = search_rag(
            &paths,
            &config,
            RagSearchRequest {
                query: "settings catalog".into(),
                sources: vec![RagSourceKind::SettingsCatalog],
                collection_type: None,
                collections: Vec::new(),
                mode: Some(RagRetrievalMode::Vector),
                limit: Some(3),
                include_review_only: false,
            },
        )
        .expect("vector search should succeed");
        assert_eq!(vector.mode, RagRetrievalMode::Vector);
        assert_eq!(vector.vector_posture, RagVectorPosture::Healthy);
        assert!(!vector.results.is_empty());
        assert!(vector
            .results
            .iter()
            .all(|result| result.mode == RagRetrievalMode::Vector));

        let doctor = rag_doctor(&paths, &config).expect("doctor should inspect vectors");
        assert!(doctor.ok, "{:?}", doctor.issues);
        assert_eq!(doctor.vector_posture, RagVectorPosture::Healthy);
    }

    #[test]
    fn vector_search_falls_back_when_model_key_is_stale() {
        let (_temp, paths) = temp_paths();
        let config = fake_vector_config();
        rebuild_rag_index(
            &paths,
            &config,
            RagRebuildRequest {
                stale_only: false,
                sources: vec![RagSourceKind::SettingsCatalog],
                collection_type: None,
                collections: Vec::new(),
                include_vectors: true,
                trigger: "test".into(),
            },
        )
        .expect("vector rebuild should succeed");

        let mut stale_config = config.clone();
        stale_config.rag.vector.model = "fake-16d".into();
        let status = rag_status(&paths, &stale_config).expect("status should read stale vectors");
        assert_eq!(status.vector_posture, RagVectorPosture::Stale);

        let search = search_rag(
            &paths,
            &stale_config,
            RagSearchRequest {
                query: "settings".into(),
                sources: vec![RagSourceKind::SettingsCatalog],
                collection_type: None,
                collections: Vec::new(),
                mode: Some(RagRetrievalMode::Vector),
                limit: Some(3),
                include_review_only: false,
            },
        )
        .expect("stale vectors should fall back");
        assert_eq!(search.mode, RagRetrievalMode::Lexical);
        assert_eq!(search.vector_posture, RagVectorPosture::Degraded);
        assert!(!search.results.is_empty());
    }

    #[test]
    fn stale_only_rebuild_runs_when_vectors_are_missing() {
        let (_temp, paths) = temp_paths();
        let lexical_config = Config::default_template();
        rebuild_rag_index(
            &paths,
            &lexical_config,
            RagRebuildRequest {
                stale_only: false,
                sources: vec![RagSourceKind::CommandCatalog],
                collection_type: None,
                collections: Vec::new(),
                include_vectors: false,
                trigger: "test".into(),
            },
        )
        .expect("lexical rebuild should succeed");

        let config = fake_vector_config();
        let summary = rebuild_rag_index(
            &paths,
            &config,
            RagRebuildRequest {
                stale_only: true,
                sources: vec![RagSourceKind::CommandCatalog],
                collection_type: None,
                collections: Vec::new(),
                include_vectors: true,
                trigger: "test".into(),
            },
        )
        .expect("stale-only should rebuild missing vectors");
        assert_eq!(summary.status, RagIndexRunStatus::Succeeded);
        assert!(summary.vector_count > 0);
    }

    #[test]
    fn vector_query_permit_enforces_configured_limit() {
        ACTIVE_VECTOR_QUERIES.store(1, Ordering::Release);
        let denied = acquire_vector_query_permit(1);
        ACTIVE_VECTOR_QUERIES.store(0, Ordering::Release);
        assert!(denied.is_err());
    }

    #[test]
    fn rag_indexes_durable_memory_and_facts() {
        let (_temp, paths) = temp_paths();
        let config = Config::default_template();
        fs::create_dir_all(paths.memory_notes.join("projects")).unwrap();
        fs::write(
            paths.memory_notes.join("projects/warehouse.md"),
            "---\nfacts:\n  - id: warehouse_db\n    subject: Analytics warehouse\n    predicate: uses\n    object: Postgres\n---\n# Analytics warehouse\n\nThe analytics warehouse uses Postgres for reporting.\n",
        )
        .unwrap();
        memory::bootstrap_curated_memory(&paths, &config.memory).unwrap();

        let summary = rebuild_rag_index(
            &paths,
            &config,
            RagRebuildRequest {
                stale_only: false,
                sources: vec![RagSourceKind::DurableMemory, RagSourceKind::FactMemory],
                collection_type: None,
                collections: Vec::new(),
                include_vectors: false,
                trigger: "test".into(),
            },
        )
        .expect("memory RAG rebuild should succeed");
        assert!(summary.source_count >= 2);

        let durable = search_rag(
            &paths,
            &config,
            RagSearchRequest {
                query: "analytics warehouse reporting".into(),
                sources: vec![RagSourceKind::DurableMemory],
                collection_type: None,
                collections: Vec::new(),
                mode: Some(RagRetrievalMode::Lexical),
                limit: Some(5),
                include_review_only: false,
            },
        )
        .expect("durable memory should be searchable");
        assert!(durable
            .results
            .iter()
            .any(|result| result.source_kind == RagSourceKind::DurableMemory));

        let facts = search_rag(
            &paths,
            &config,
            RagSearchRequest {
                query: "warehouse Postgres".into(),
                sources: vec![RagSourceKind::FactMemory],
                collection_type: None,
                collections: Vec::new(),
                mode: Some(RagRetrievalMode::Lexical),
                limit: Some(5),
                include_review_only: false,
            },
        )
        .expect("facts should be searchable");
        assert!(facts
            .results
            .iter()
            .any(|result| result.source_kind == RagSourceKind::FactMemory));
    }

    #[test]
    fn rag_indexes_episode_recall_and_session_summary() {
        let (_temp, paths) = temp_paths();
        let config = Config::default_template();
        let session_dir = paths.sessions.join("episode-session");
        fs::create_dir_all(&session_dir).unwrap();
        fs::write(
            session_dir.join("turns.md"),
            "# Session episode-session\n\n- channel: cli\n- started_at: 2026-04-20T00:00:00Z\n\n## 2026-04-20T01:02:03Z\n- channel: cli\n- cost_delta_usd: 0.000000\n\n### user\n\nPlease remember the blue notebook lives on shelf seven.\n\n### assistant\n\nI noted the shelf-seven notebook detail as working history.\n",
        )
        .unwrap();
        memory::bootstrap_curated_memory(&paths, &config.memory).unwrap();

        rebuild_rag_index(
            &paths,
            &config,
            RagRebuildRequest {
                stale_only: false,
                sources: vec![RagSourceKind::EpisodeRecall, RagSourceKind::SessionSummary],
                collection_type: None,
                collections: Vec::new(),
                include_vectors: false,
                trigger: "test".into(),
            },
        )
        .expect("episode RAG rebuild should succeed");

        let episode = search_rag(
            &paths,
            &config,
            RagSearchRequest {
                query: "blue notebook".into(),
                sources: vec![RagSourceKind::EpisodeRecall],
                collection_type: None,
                collections: Vec::new(),
                mode: Some(RagRetrievalMode::Lexical),
                limit: Some(5),
                include_review_only: false,
            },
        )
        .expect("episode recall should be searchable");
        assert!(episode
            .results
            .iter()
            .any(|result| result.source_kind == RagSourceKind::EpisodeRecall));

        let summary = search_rag(
            &paths,
            &config,
            RagSearchRequest {
                query: "shelf seven".into(),
                sources: vec![RagSourceKind::SessionSummary],
                collection_type: None,
                collections: Vec::new(),
                mode: Some(RagRetrievalMode::Lexical),
                limit: Some(5),
                include_review_only: false,
            },
        )
        .expect("session summary should be searchable");
        assert!(summary
            .results
            .iter()
            .any(|result| result.source_kind == RagSourceKind::SessionSummary));
    }

    #[test]
    fn staged_memory_is_review_only_and_requires_explicit_source() {
        let (_temp, paths) = temp_paths();
        let config = Config::default_template();
        memory::bootstrap_curated_memory(&paths, &config.memory).unwrap();
        memory::stage_memory(
            &paths,
            &config.memory,
            memory::StageMemoryRequest {
                session_id: "session".into(),
                turn_id: "turn".into(),
                agent: "allbert/root".into(),
                source: "test".into(),
                content: "Quartz staging secret should stay review-only.".into(),
                kind: memory::StagedMemoryKind::ExplicitRequest,
                summary: "Quartz staging secret".into(),
                tags: vec!["test".into()],
                provenance: None,
                fingerprint_basis: None,
                facts: Vec::new(),
            },
        )
        .expect("stage memory should succeed");

        rebuild_rag_index(
            &paths,
            &config,
            RagRebuildRequest {
                stale_only: false,
                sources: Vec::new(),
                collection_type: None,
                collections: Vec::new(),
                include_vectors: false,
                trigger: "test".into(),
            },
        )
        .expect("default RAG rebuild should succeed");
        let ordinary = search_rag(
            &paths,
            &config,
            RagSearchRequest {
                query: "Quartz staging secret".into(),
                sources: vec![RagSourceKind::StagedMemoryReview],
                collection_type: None,
                collections: Vec::new(),
                mode: Some(RagRetrievalMode::Lexical),
                limit: Some(5),
                include_review_only: true,
            },
        )
        .expect("ordinary index should be searchable");
        assert!(ordinary.results.is_empty());

        rebuild_rag_index(
            &paths,
            &config,
            RagRebuildRequest {
                stale_only: false,
                sources: vec![RagSourceKind::StagedMemoryReview],
                collection_type: None,
                collections: Vec::new(),
                include_vectors: false,
                trigger: "test".into(),
            },
        )
        .expect("explicit staged RAG rebuild should succeed");
        let hidden = search_rag(
            &paths,
            &config,
            RagSearchRequest {
                query: "Quartz staging secret".into(),
                sources: vec![RagSourceKind::StagedMemoryReview],
                collection_type: None,
                collections: Vec::new(),
                mode: Some(RagRetrievalMode::Lexical),
                limit: Some(5),
                include_review_only: false,
            },
        )
        .expect("review-only search should respect gating");
        assert!(hidden.results.is_empty());

        let review = search_rag(
            &paths,
            &config,
            RagSearchRequest {
                query: "Quartz staging secret".into(),
                sources: vec![RagSourceKind::StagedMemoryReview],
                collection_type: None,
                collections: Vec::new(),
                mode: Some(RagRetrievalMode::Lexical),
                limit: Some(5),
                include_review_only: true,
            },
        )
        .expect("explicit review search should find staged memory");
        assert!(review
            .results
            .iter()
            .any(|result| result.source_kind == RagSourceKind::StagedMemoryReview));
    }
}
