use std::collections::HashMap;
use std::fs;
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
    command_catalog, memory, settings_catalog, AllbertPaths, Config, KernelError,
    SettingDescriptor, SkillStore,
};

pub const RAG_SCHEMA_VERSION: u32 = 1;
static ACTIVE_VECTOR_QUERIES: AtomicUsize = AtomicUsize::new(0);
const RAG_REBUILD_CANCELLED: &str = "__rag_rebuild_cancelled__";

type SqliteExtensionInit = unsafe extern "C" fn(
    *mut rusqlite::ffi::sqlite3,
    *mut *mut std::ffi::c_char,
    *const rusqlite::ffi::sqlite3_api_routines,
) -> std::ffi::c_int;

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq, Eq)]
pub struct RagRebuildRequest {
    pub stale_only: bool,
    pub sources: Vec<RagSourceKind>,
    pub include_vectors: bool,
    pub trigger: String,
}

impl Default for RagRebuildRequest {
    fn default() -> Self {
        Self {
            stale_only: true,
            sources: Vec::new(),
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

#[derive(Debug, Clone)]
struct CollectedSource {
    kind: RagSourceKind,
    source_id: String,
    source_path: Option<String>,
    title: String,
    tags: Vec<String>,
    text: String,
    privacy_tier: &'static str,
    prompt_eligible: bool,
    review_only: bool,
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
    let sources = collect_sources(paths, config, &request.sources)?;
    let corpus_hash = hash_sources(&sources);
    let requested_sources_json = serde_json::to_string(
        &request
            .sources
            .iter()
            .map(|source| source.label())
            .collect::<Vec<_>>(),
    )
    .map_err(|e| KernelError::InitFailed(format!("serialize requested sources: {e}")))?;

    if should_cancel() {
        record_cancelled_run_if_possible(
            paths,
            &run_id,
            &request,
            &requested_sources_json,
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
                    s.source_path, bm25(rag_chunks_fts) AS rank
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
                    row.get::<_, f64>(6)?,
                ))
            },
        )
        .map_err(sql_err)?;

    let mut results = Vec::new();
    for row in rows {
        let (chunk_id, title, text, source_kind, source_id, path, rank) = row.map_err(sql_err)?;
        if !allowed_sources.is_empty() && !allowed_sources.iter().any(|kind| kind == &source_kind) {
            continue;
        }
        let Some(kind) = RagSourceKind::parse(&source_kind) else {
            continue;
        };
        results.push(RagSearchResult {
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
                    s.source_path, knn.distance
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
                    row.get::<_, f64>(6)?,
                ))
            },
        )
        .map_err(|e| EmbeddingError::new(format!("query vector search: {e}")))?;
    let mut results = Vec::new();
    for row in rows {
        let (chunk_id, title, text, source_kind, source_id, path, distance) =
            row.map_err(|e| EmbeddingError::new(format!("read vector row: {e}")))?;
        if !allowed_sources.is_empty() && !allowed_sources.iter().any(|kind| kind == &source_kind) {
            continue;
        }
        let Some(kind) = RagSourceKind::parse(&source_kind) else {
            continue;
        };
        results.push(RagSearchResult {
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
    conn.execute_batch(
        r#"
CREATE TABLE IF NOT EXISTS rag_meta (
  key TEXT PRIMARY KEY,
  value TEXT NOT NULL,
  updated_at TEXT NOT NULL
);

CREATE TABLE IF NOT EXISTS rag_sources (
  id INTEGER PRIMARY KEY,
  source_kind TEXT NOT NULL,
  source_id TEXT NOT NULL,
  source_path TEXT,
  title TEXT NOT NULL,
  tags_json TEXT NOT NULL DEFAULT '[]',
  content_hash TEXT NOT NULL,
  privacy_tier TEXT NOT NULL,
  prompt_eligible INTEGER NOT NULL DEFAULT 0,
  review_only INTEGER NOT NULL DEFAULT 0,
  stale INTEGER NOT NULL DEFAULT 0,
  created_at TEXT NOT NULL,
  updated_at TEXT NOT NULL,
  UNIQUE(source_kind, source_id)
);

CREATE TABLE IF NOT EXISTS rag_chunks (
  id INTEGER PRIMARY KEY,
  source_fk INTEGER NOT NULL REFERENCES rag_sources(id) ON DELETE CASCADE,
  chunk_id TEXT NOT NULL UNIQUE,
  ordinal INTEGER NOT NULL,
  title TEXT NOT NULL,
  heading_path TEXT,
  text TEXT NOT NULL,
  byte_len INTEGER NOT NULL,
  token_estimate INTEGER NOT NULL,
  tags TEXT NOT NULL DEFAULT '',
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
  labels,
  content='rag_chunks',
  content_rowid='id'
);

CREATE TABLE IF NOT EXISTS rag_index_runs (
  run_id TEXT PRIMARY KEY,
  trigger TEXT NOT NULL,
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

CREATE INDEX IF NOT EXISTS idx_rag_sources_kind ON rag_sources(source_kind);
CREATE INDEX IF NOT EXISTS idx_rag_sources_stale ON rag_sources(stale);
CREATE INDEX IF NOT EXISTS idx_rag_chunks_source ON rag_chunks(source_fk);
CREATE INDEX IF NOT EXISTS idx_rag_chunks_prompt ON rag_chunks(prompt_eligible, review_only);
CREATE INDEX IF NOT EXISTS idx_rag_chunks_embedding ON rag_chunks(embedding_model_key, embedding_state);
CREATE INDEX IF NOT EXISTS idx_rag_runs_started ON rag_index_runs(started_at);
"#,
    )
    .map_err(sql_err)
}

fn collect_sources(
    paths: &AllbertPaths,
    config: &Config,
    only: &[RagSourceKind],
) -> Result<Vec<CollectedSource>, KernelError> {
    let mut sources = Vec::new();
    collect_operator_docs(&mut sources)?;
    collect_command_catalog(&mut sources)?;
    collect_settings_catalog(&mut sources);
    collect_skill_metadata(paths, config, &mut sources);
    collect_memory_sources(
        paths,
        config,
        only.contains(&RagSourceKind::StagedMemoryReview)
            || config
                .rag
                .sources
                .contains(&RagSourceKind::StagedMemoryReview),
        &mut sources,
    )?;
    if !only.is_empty() {
        sources.retain(|source| only.contains(&source.kind));
    } else {
        sources.retain(|source| config.rag.sources.contains(&source.kind));
    }
    sources.sort_by(|a, b| {
        a.kind
            .label()
            .cmp(b.kind.label())
            .then_with(|| a.source_id.cmp(&b.source_id))
    });
    Ok(sources)
}

fn collect_memory_sources(
    paths: &AllbertPaths,
    config: &Config,
    include_staged_review: bool,
    sources: &mut Vec<CollectedSource>,
) -> Result<(), KernelError> {
    for source in memory::collect_rag_memory_sources(paths, &config.memory, include_staged_review)?
    {
        sources.push(CollectedSource {
            kind: source.kind,
            source_id: source.source_id,
            source_path: source.source_path,
            title: source.title,
            tags: source.tags,
            text: source.text,
            privacy_tier: source.privacy_tier,
            prompt_eligible: source.prompt_eligible,
            review_only: source.review_only,
        });
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
        sources.push(CollectedSource {
            kind: RagSourceKind::OperatorDocs,
            source_id: format!("docs:{rel}"),
            source_path: Some(rel.clone()),
            title: first_markdown_heading(&raw).unwrap_or_else(|| rel.clone()),
            tags: vec!["docs".into(), "operator".into()],
            text: raw,
            privacy_tier: "local_docs",
            prompt_eligible: true,
            review_only: false,
        });
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
        sources.push(CollectedSource {
            kind: RagSourceKind::CommandCatalog,
            source_id: format!("command:{}", command.id),
            source_path: None,
            title: command.display.into(),
            tags,
            text,
            privacy_tier: "generated_public",
            prompt_eligible: true,
            review_only: false,
        });
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
    CollectedSource {
        kind: RagSourceKind::SettingsCatalog,
        source_id: format!("setting:{}", setting.key),
        source_path: None,
        title: setting.key.into(),
        tags: vec![setting.group.id().into(), "settings".into()],
        text,
        privacy_tier: "generated_local",
        prompt_eligible: true,
        review_only: false,
    }
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
        sources.push(CollectedSource {
            kind: RagSourceKind::SkillsMetadata,
            source_id: format!("skill:installed:{}", skill.name),
            source_path: Some(path_display_under(&skill.path, &paths.root)),
            title: skill.name.clone(),
            tags: vec!["skills".into(), skill.provenance.label().into()],
            text,
            privacy_tier: "local_metadata",
            prompt_eligible: true,
            review_only: false,
        });
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
    for source in sources {
        if should_cancel() {
            return Err(KernelError::Request(RAG_REBUILD_CANCELLED.into()));
        }
        let tags_json = serde_json::to_string(&source.tags)
            .map_err(|e| KernelError::InitFailed(format!("serialize source tags: {e}")))?;
        let source_hash = hash_text(&source.text);
        tx.execute(
            "INSERT INTO rag_sources
             (source_kind, source_id, source_path, title, tags_json, content_hash,
              privacy_tier, prompt_eligible, review_only, stale, created_at, updated_at)
             VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8, ?9, 0, ?10, ?10)",
            params![
                source.kind.label(),
                source.source_id,
                source.source_path,
                source.title,
                tags_json,
                source_hash,
                source.privacy_tier,
                bool_int(source.prompt_eligible),
                bool_int(source.review_only),
                now
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
                 (source_fk, chunk_id, ordinal, title, heading_path, text, byte_len,
                  token_estimate, tags, source_kind, labels, provenance_json,
                  prompt_eligible, review_only, content_hash, embedding_state, updated_at)
                 VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8, ?9, ?10, ?11, ?12,
                         ?13, ?14, ?15, 'missing', ?16)",
                params![
                    source_fk,
                    chunk.chunk_id,
                    chunk.ordinal as i64,
                    chunk.title,
                    chunk.heading_path,
                    chunk.text,
                    chunk.text.len() as i64,
                    token_estimate(&chunk.text) as i64,
                    chunk.tags.join(" "),
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
                 (rowid, title, text, tags, source_kind, labels)
                 VALUES (?1, ?2, ?3, ?4, ?5, ?6)",
                params![
                    rowid,
                    chunk.title,
                    chunk.text,
                    chunk.tags.join(" "),
                    source.kind.label(),
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
    record: RunWrite<'_>,
) -> Result<(), KernelError> {
    conn.execute(
        "INSERT OR REPLACE INTO rag_index_runs
         (run_id, trigger, requested_sources_json, include_vectors, stale_only, status,
          started_at, finished_at, source_count, chunk_count, vector_count, skipped_count,
          elapsed_ms, error)
         VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8, ?9, ?10, ?11, ?12, ?13, ?14)",
        params![
            run_id,
            request.trigger,
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
                include_vectors: false,
                trigger: "test".into(),
            },
        )
        .expect("stale-only rebuild should inspect corpus");
        assert_eq!(skipped.status, RagIndexRunStatus::Skipped);
        assert_eq!(skipped.message, "nothing stale");
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
                include_vectors: false,
                trigger: "test".into(),
            },
        )
        .expect("rebuild should succeed");
        let healthy = rag_doctor(&paths, &config).expect("healthy doctor should return");
        assert!(healthy.ok, "{:?}", healthy.issues);
        assert!(healthy.db_exists);
        assert_eq!(healthy.schema_version.as_deref(), Some("1"));
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
