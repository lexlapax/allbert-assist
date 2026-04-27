use std::fs;
use std::path::{Path, PathBuf};
use std::time::Instant;

pub use allbert_kernel_core::rag::*;
use rusqlite::{params, Connection, OptionalExtension};
use serde::{Deserialize, Serialize};
use serde_json::json;
use sha2::{Digest, Sha256};
use uuid::Uuid;

use crate::{
    command_catalog, settings_catalog, AllbertPaths, Config, KernelError, SettingDescriptor,
    SkillStore,
};

pub const RAG_SCHEMA_VERSION: u32 = 1;

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

pub fn sqlite_vec_dependency_probe() -> Result<String, rusqlite::Error> {
    register_sqlite_vec();
    let db = rusqlite::Connection::open_in_memory()?;
    db.query_row("select vec_version()", [], |row| row.get(0))
}

pub fn rag_status(paths: &AllbertPaths, config: &Config) -> Result<RagStatusSnapshot, KernelError> {
    if !paths.rag_db.exists() {
        return Ok(RagStatusSnapshot {
            enabled: config.rag.enabled,
            mode: config.rag.mode,
            source_count: 0,
            chunk_count: 0,
            vector_count: 0,
            vector_posture: RagVectorPosture::Disabled,
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
        vector_count: 0,
        vector_posture: if config.rag.vector.enabled {
            RagVectorPosture::Stale
        } else {
            RagVectorPosture::Disabled
        },
        active_provider: Some(config.rag.vector.provider),
        active_model: Some(config.rag.vector.model.clone()),
        active_dimension: None,
        last_run_id,
        degraded_reason: if config.rag.vector.enabled {
            Some("M1 builds lexical RAG only; vector tables land in M2".into())
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
    paths.ensure()?;
    fs::create_dir_all(&paths.rag_index).map_err(|e| {
        KernelError::InitFailed(format!("create {}: {e}", paths.rag_index.display()))
    })?;

    let started = Instant::now();
    let run_id = format!("rag-{}", Uuid::new_v4());
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

    if request.stale_only && paths.rag_db.exists() {
        let conn = open_rag_db(paths)?;
        let previous = get_meta(&conn, "source_hash")?;
        if previous.as_deref() == Some(&corpus_hash) {
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

    let chunk_count = write_sources(&mut conn, config, &sources)?;
    set_meta(&conn, "schema_version", &RAG_SCHEMA_VERSION.to_string())?;
    set_meta(&conn, "source_hash", &corpus_hash)?;
    set_meta(
        &conn,
        "sqlite_vec_version",
        &sqlite_vec_dependency_probe().unwrap_or_default(),
    )?;
    set_meta(&conn, "vector_posture", RagVectorPosture::Disabled.label())?;
    finish_run(
        &conn,
        &run_id,
        RunWrite {
            status: RagIndexRunStatus::Succeeded,
            source_count: sources.len(),
            chunk_count,
            vector_count: 0,
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
        vector_count: 0,
        skipped_count: 0,
        elapsed_ms: started.elapsed().as_millis() as u64,
        db_path: paths.rag_db.clone(),
        message: "lexical RAG rebuilt".into(),
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
    let mode = match request.mode.unwrap_or(config.rag.mode) {
        RagRetrievalMode::Vector if config.rag.vector.fallback_to_lexical => {
            RagRetrievalMode::Lexical
        }
        RagRetrievalMode::Hybrid | RagRetrievalMode::Vector | RagRetrievalMode::Lexical => {
            RagRetrievalMode::Lexical
        }
    };
    let limit = request.limit.unwrap_or(10).clamp(1, 50);
    let match_expr = fts_match_expression(&request.query);
    if match_expr.is_empty() {
        return Ok(RagSearchResponse {
            query: request.query,
            mode,
            vector_posture: RagVectorPosture::Disabled,
            degraded_reason: None,
            results: Vec::new(),
        });
    }
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
            mode,
            score: -rank,
            vector_posture: RagVectorPosture::Disabled,
            score_explanation: Some("sqlite fts bm25".into()),
        });
        if results.len() >= limit {
            break;
        }
    }

    Ok(RagSearchResponse {
        query: request.query,
        mode,
        vector_posture: RagVectorPosture::Disabled,
        degraded_reason: if request.mode == Some(RagRetrievalMode::Vector) {
            Some("M1 lexical fallback: vectors land in M2".into())
        } else {
            None
        },
        results,
    })
}

pub fn rag_doctor(paths: &AllbertPaths, _config: &Config) -> Result<RagDoctorReport, KernelError> {
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
    Ok(RagDoctorReport {
        ok: issues.is_empty(),
        db_path: paths.rag_db.clone(),
        db_exists,
        schema_version,
        source_count,
        chunk_count,
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

fn open_rag_db(paths: &AllbertPaths) -> Result<Connection, KernelError> {
    let conn = open_path(&paths.rag_db)?;
    init_schema(&conn)?;
    Ok(conn)
}

fn open_path(path: &Path) -> Result<Connection, KernelError> {
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
    if !only.is_empty() {
        sources.retain(|source| only.contains(&source.kind));
    }
    sources.sort_by(|a, b| {
        a.kind
            .label()
            .cmp(b.kind.label())
            .then_with(|| a.source_id.cmp(&b.source_id))
    });
    Ok(sources)
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

fn write_sources(
    conn: &mut Connection,
    config: &Config,
    sources: &[CollectedSource],
) -> Result<usize, KernelError> {
    let tx = conn.transaction().map_err(sql_err)?;
    let now = chrono::Utc::now().to_rfc3339();
    let mut chunk_total = 0;
    for source in sources {
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

    fn temp_paths() -> (tempfile::TempDir, AllbertPaths) {
        let temp = tempfile::tempdir().expect("tempdir");
        let paths = AllbertPaths::under(temp.path().join("home"));
        paths.ensure().expect("paths should initialize");
        Config::default_template()
            .persist(&paths)
            .expect("config should persist");
        (temp, paths)
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
}
