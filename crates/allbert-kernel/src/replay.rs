use std::collections::BTreeMap;
use std::fs::{self, File, OpenOptions};
use std::io::{BufRead, BufReader, Read, Write};
use std::path::{Path, PathBuf};
use std::sync::Arc;
use std::time::Instant;

use allbert_proto::{AttributeValue, Span, SpanEvent, SpanKind, SpanStatus, TraceSessionSummary};
use chrono::{DateTime, Utc};
use flate2::read::GzDecoder;
use flate2::write::GzEncoder;
use flate2::Compression;
use serde::{Deserialize, Serialize};
use thiserror::Error;

use crate::atomic_write;
use crate::paths::AllbertPaths;

pub const TRACE_RECORD_SCHEMA_VERSION: u16 = 1;
const TRACE_ACTIVE_FILE: &str = "trace.jsonl";
const CURRENT_SPANS_DIR: &str = "current_spans";

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq)]
pub struct TraceRecord {
    pub schema_version: u16,
    pub record_type: TraceRecordType,
    pub span: Span,
}

#[derive(Debug, Clone, Copy, Serialize, Deserialize, PartialEq, Eq)]
#[serde(rename_all = "snake_case")]
pub enum TraceRecordType {
    Span,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub enum TraceRecordError {
    UnsupportedSchemaVersion { found: u16, supported: u16 },
}

impl std::fmt::Display for TraceRecordError {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        match self {
            Self::UnsupportedSchemaVersion { found, supported } => write!(
                f,
                "unsupported trace schema version {found}; this build supports schema version {supported}"
            ),
        }
    }
}

impl std::error::Error for TraceRecordError {}

impl TraceRecord {
    pub fn span(span: Span) -> Self {
        Self {
            schema_version: TRACE_RECORD_SCHEMA_VERSION,
            record_type: TraceRecordType::Span,
            span,
        }
    }

    pub fn validate_schema_version(&self) -> Result<(), TraceRecordError> {
        if self.schema_version == TRACE_RECORD_SCHEMA_VERSION {
            Ok(())
        } else {
            Err(TraceRecordError::UnsupportedSchemaVersion {
                found: self.schema_version,
                supported: TRACE_RECORD_SCHEMA_VERSION,
            })
        }
    }
}

#[derive(Debug, Error)]
pub enum TraceStoreError {
    #[error("trace io error at {path}: {source}")]
    Io {
        path: String,
        #[source]
        source: std::io::Error,
    },
    #[error("trace json error at {path}: {source}")]
    Json {
        path: String,
        #[source]
        source: serde_json::Error,
    },
    #[error("{0}")]
    Record(#[from] TraceRecordError),
    #[error("invalid trace path: {0}")]
    InvalidPath(String),
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct TraceReadWarning {
    pub path: PathBuf,
    pub line: usize,
    pub message: String,
}

#[derive(Debug, Clone)]
pub struct TraceReadResult {
    pub spans: Vec<Span>,
    pub warnings: Vec<TraceReadWarning>,
    pub bytes: u64,
    pub has_rotated_archives: bool,
    pub truncated_count: u64,
}

#[derive(Debug, Clone)]
pub struct TraceStorageLimits {
    pub session_disk_cap_bytes: u64,
}

impl TraceStorageLimits {
    pub fn from_session_cap_mb(session_disk_cap_mb: u64) -> Self {
        Self {
            session_disk_cap_bytes: session_disk_cap_mb.saturating_mul(1024 * 1024),
        }
    }
}

impl Default for TraceStorageLimits {
    fn default() -> Self {
        Self::from_session_cap_mb(50)
    }
}

pub trait TraceWriter: Send + Sync {
    fn span_started(&self, span: &Span) -> Result<(), TraceStoreError>;
    fn span_ended(&self, span: &Span) -> Result<(), TraceStoreError>;
    fn recover_in_flight(&self) -> Result<Vec<Span>, TraceStoreError>;
}

pub trait TracingHooks: Send + Sync {
    fn begin_span(&self, span: &Span) -> Result<(), TraceStoreError>;
    fn end_span(&self, span: &Span) -> Result<(), TraceStoreError>;
}

#[derive(Debug, Clone)]
pub struct JsonlTraceWriter {
    session_dir: PathBuf,
    active_path: PathBuf,
    current_spans_dir: PathBuf,
    limits: TraceStorageLimits,
}

impl JsonlTraceWriter {
    pub fn new(
        paths: &AllbertPaths,
        session_id: &str,
        limits: TraceStorageLimits,
    ) -> Result<Self, TraceStoreError> {
        validate_session_id(session_id)?;
        let session_dir = paths.sessions.join(session_id);
        let active_path = session_dir.join(TRACE_ACTIVE_FILE);
        let current_spans_dir = session_dir.join(CURRENT_SPANS_DIR);
        fs::create_dir_all(&current_spans_dir).map_err(|source| TraceStoreError::Io {
            path: current_spans_dir.display().to_string(),
            source,
        })?;
        Ok(Self {
            session_dir,
            active_path,
            current_spans_dir,
            limits,
        })
    }

    pub fn session_dir(&self) -> &Path {
        &self.session_dir
    }

    fn snapshot_path(&self, span_id: &str) -> PathBuf {
        self.current_spans_dir.join(format!("{span_id}.json"))
    }

    fn append_record(&self, record: &TraceRecord) -> Result<(), TraceStoreError> {
        fs::create_dir_all(&self.session_dir).map_err(|source| TraceStoreError::Io {
            path: self.session_dir.display().to_string(),
            source,
        })?;
        let mut file = OpenOptions::new()
            .create(true)
            .append(true)
            .open(&self.active_path)
            .map_err(|source| TraceStoreError::Io {
                path: self.active_path.display().to_string(),
                source,
            })?;
        serde_json::to_writer(&mut file, record).map_err(|source| TraceStoreError::Json {
            path: self.active_path.display().to_string(),
            source,
        })?;
        file.write_all(b"\n")
            .map_err(|source| TraceStoreError::Io {
                path: self.active_path.display().to_string(),
                source,
            })?;
        file.flush().map_err(|source| TraceStoreError::Io {
            path: self.active_path.display().to_string(),
            source,
        })?;
        self.rotate_if_needed()?;
        self.evict_archives_past_cap()
    }

    fn rotate_if_needed(&self) -> Result<(), TraceStoreError> {
        let Ok(meta) = fs::metadata(&self.active_path) else {
            return Ok(());
        };
        if meta.len() <= self.limits.session_disk_cap_bytes {
            return Ok(());
        }

        let archive_path = self.next_archive_path()?;
        let tmp_path = archive_path.with_extension("jsonl.gz.tmp");
        let mut source = Vec::new();
        File::open(&self.active_path)
            .map_err(|source| TraceStoreError::Io {
                path: self.active_path.display().to_string(),
                source,
            })?
            .read_to_end(&mut source)
            .map_err(|source| TraceStoreError::Io {
                path: self.active_path.display().to_string(),
                source,
            })?;
        {
            let tmp = File::create(&tmp_path).map_err(|source| TraceStoreError::Io {
                path: tmp_path.display().to_string(),
                source,
            })?;
            let mut encoder = GzEncoder::new(tmp, Compression::default());
            encoder
                .write_all(&source)
                .map_err(|source| TraceStoreError::Io {
                    path: tmp_path.display().to_string(),
                    source,
                })?;
            encoder.finish().map_err(|source| TraceStoreError::Io {
                path: tmp_path.display().to_string(),
                source,
            })?;
        }
        fs::rename(&tmp_path, &archive_path).map_err(|source| TraceStoreError::Io {
            path: format!("{} -> {}", tmp_path.display(), archive_path.display()),
            source,
        })?;
        fs::remove_file(&self.active_path).map_err(|source| TraceStoreError::Io {
            path: self.active_path.display().to_string(),
            source,
        })?;
        File::create(&self.active_path).map_err(|source| TraceStoreError::Io {
            path: self.active_path.display().to_string(),
            source,
        })?;
        Ok(())
    }

    fn next_archive_path(&self) -> Result<PathBuf, TraceStoreError> {
        let next = self
            .archive_paths()?
            .into_iter()
            .filter_map(|path| archive_index(&path))
            .max()
            .unwrap_or(0)
            .saturating_add(1);
        Ok(self.session_dir.join(format!("trace.{next}.jsonl.gz")))
    }

    fn archive_paths(&self) -> Result<Vec<PathBuf>, TraceStoreError> {
        if !self.session_dir.exists() {
            return Ok(Vec::new());
        }
        let mut archives = Vec::new();
        for entry in fs::read_dir(&self.session_dir).map_err(|source| TraceStoreError::Io {
            path: self.session_dir.display().to_string(),
            source,
        })? {
            let entry = entry.map_err(|source| TraceStoreError::Io {
                path: self.session_dir.display().to_string(),
                source,
            })?;
            let path = entry.path();
            if archive_index(&path).is_some() {
                archives.push(path);
            }
        }
        archives.sort_by_key(|path| archive_index(path).unwrap_or(0));
        Ok(archives)
    }

    fn evict_archives_past_cap(&self) -> Result<(), TraceStoreError> {
        let mut archives = self.archive_paths()?;
        let mut total = trace_artifact_bytes(&self.session_dir)?;
        while total > self.limits.session_disk_cap_bytes && !archives.is_empty() {
            let oldest = archives.remove(0);
            let len = fs::metadata(&oldest).map(|meta| meta.len()).unwrap_or(0);
            fs::remove_file(&oldest).map_err(|source| TraceStoreError::Io {
                path: oldest.display().to_string(),
                source,
            })?;
            total = total.saturating_sub(len);
        }
        Ok(())
    }
}

impl TraceWriter for JsonlTraceWriter {
    fn span_started(&self, span: &Span) -> Result<(), TraceStoreError> {
        let record = TraceRecord::span(span.clone());
        let bytes = serde_json::to_vec_pretty(&record).map_err(|source| TraceStoreError::Json {
            path: self.snapshot_path(&span.id).display().to_string(),
            source,
        })?;
        atomic_write(&self.snapshot_path(&span.id), &bytes).map_err(|source| TraceStoreError::Io {
            path: self.snapshot_path(&span.id).display().to_string(),
            source,
        })
    }

    fn span_ended(&self, span: &Span) -> Result<(), TraceStoreError> {
        self.append_record(&TraceRecord::span(span.clone()))?;
        let snapshot = self.snapshot_path(&span.id);
        match fs::remove_file(&snapshot) {
            Ok(()) => Ok(()),
            Err(err) if err.kind() == std::io::ErrorKind::NotFound => Ok(()),
            Err(source) => Err(TraceStoreError::Io {
                path: snapshot.display().to_string(),
                source,
            }),
        }
    }

    fn recover_in_flight(&self) -> Result<Vec<Span>, TraceStoreError> {
        if !self.current_spans_dir.exists() {
            return Ok(Vec::new());
        }
        let mut recovered = Vec::new();
        for entry in
            fs::read_dir(&self.current_spans_dir).map_err(|source| TraceStoreError::Io {
                path: self.current_spans_dir.display().to_string(),
                source,
            })?
        {
            let entry = entry.map_err(|source| TraceStoreError::Io {
                path: self.current_spans_dir.display().to_string(),
                source,
            })?;
            let path = entry.path();
            if path.extension().and_then(|ext| ext.to_str()) != Some("json") {
                continue;
            }
            let raw = fs::read_to_string(&path).map_err(|source| TraceStoreError::Io {
                path: path.display().to_string(),
                source,
            })?;
            let record: TraceRecord =
                serde_json::from_str(&raw).map_err(|source| TraceStoreError::Json {
                    path: path.display().to_string(),
                    source,
                })?;
            record.validate_schema_version()?;
            let mut span = record.span;
            let now = Utc::now();
            span.ended_at = Some(now);
            span.duration_ms = Some(duration_ms(span.started_at, now));
            span.status = SpanStatus::Error {
                message: "truncated_at_restart".into(),
            };
            span.events.push(SpanEvent {
                timestamp: now,
                name: "truncated_at_restart".into(),
                attributes: BTreeMap::new(),
            });
            sort_span_events(&mut span);
            self.span_ended(&span)?;
            recovered.push(span);
        }
        Ok(recovered)
    }
}

impl TracingHooks for JsonlTraceWriter {
    fn begin_span(&self, span: &Span) -> Result<(), TraceStoreError> {
        self.span_started(span)
    }

    fn end_span(&self, span: &Span) -> Result<(), TraceStoreError> {
        self.span_ended(span)
    }
}

#[derive(Clone)]
pub struct ActiveTraceSpan {
    hooks: Option<Arc<dyn TracingHooks>>,
    span: Span,
    started: Instant,
}

impl ActiveTraceSpan {
    pub fn disabled(
        session_id: &str,
        trace_id: &str,
        parent_id: Option<String>,
        name: impl Into<String>,
    ) -> Self {
        Self::new(
            None,
            session_id,
            trace_id,
            parent_id,
            name,
            SpanKind::Internal,
        )
    }

    pub fn new(
        hooks: Option<Arc<dyn TracingHooks>>,
        session_id: &str,
        trace_id: &str,
        parent_id: Option<String>,
        name: impl Into<String>,
        kind: SpanKind,
    ) -> Self {
        let now = Utc::now();
        let span = Span {
            id: new_span_id(),
            parent_id,
            session_id: session_id.into(),
            trace_id: trace_id.into(),
            name: name.into(),
            kind,
            started_at: now,
            ended_at: None,
            duration_ms: None,
            status: SpanStatus::Ok,
            attributes: BTreeMap::new(),
            events: Vec::new(),
        };
        if let Some(hooks) = hooks.as_ref() {
            if let Err(err) = hooks.begin_span(&span) {
                tracing::warn!(error = %err, span = %span.name, "failed to snapshot trace span");
            }
        }
        Self {
            hooks,
            span,
            started: Instant::now(),
        }
    }

    pub fn id(&self) -> &str {
        &self.span.id
    }

    pub fn trace_id(&self) -> &str {
        &self.span.trace_id
    }

    pub fn set_attribute(&mut self, key: impl Into<String>, value: AttributeValue) {
        self.span.attributes.insert(key.into(), value);
    }

    pub fn add_event(
        &mut self,
        name: impl Into<String>,
        attributes: BTreeMap<String, AttributeValue>,
    ) {
        self.span.events.push(SpanEvent {
            timestamp: Utc::now(),
            name: name.into(),
            attributes,
        });
    }

    pub fn finish_ok(mut self) -> Span {
        self.finish(SpanStatus::Ok)
    }

    pub fn finish_error(mut self, message: impl Into<String>) -> Span {
        self.finish(SpanStatus::Error {
            message: message.into(),
        })
    }

    fn finish(&mut self, status: SpanStatus) -> Span {
        let now = Utc::now();
        self.span.ended_at = Some(now);
        self.span.duration_ms = Some(
            self.started
                .elapsed()
                .as_millis()
                .try_into()
                .unwrap_or(u64::MAX),
        );
        self.span.status = status;
        sort_span_events(&mut self.span);
        if let Some(hooks) = self.hooks.as_ref() {
            if let Err(err) = hooks.end_span(&self.span) {
                tracing::warn!(error = %err, span = %self.span.name, "failed to persist trace span");
            }
        }
        self.span.clone()
    }
}

#[derive(Debug, Clone)]
pub struct TraceReader {
    paths: AllbertPaths,
}

impl TraceReader {
    pub fn new(paths: AllbertPaths) -> Self {
        Self { paths }
    }

    pub fn read_session(&self, session_id: &str) -> Result<TraceReadResult, TraceStoreError> {
        validate_session_id(session_id)?;
        let session_dir = self.paths.sessions.join(session_id);
        read_session_trace_dir(&session_dir)
    }

    pub fn summarize_session(
        &self,
        session_id: &str,
    ) -> Result<TraceSessionSummary, TraceStoreError> {
        let result = self.read_session(session_id)?;
        Ok(summary_for_read_result(session_id, &result))
    }
}

pub fn read_session_trace_dir(session_dir: &Path) -> Result<TraceReadResult, TraceStoreError> {
    let mut spans = Vec::new();
    let mut warnings = Vec::new();
    let mut bytes = trace_artifact_bytes(session_dir)?;
    let archives = archive_paths_for_dir(session_dir)?;
    let has_rotated_archives = !archives.is_empty();
    for archive in &archives {
        let file = File::open(archive).map_err(|source| TraceStoreError::Io {
            path: archive.display().to_string(),
            source,
        })?;
        let decoder = GzDecoder::new(file);
        read_jsonl_records(archive, BufReader::new(decoder), &mut spans, &mut warnings)?;
    }
    let active = session_dir.join(TRACE_ACTIVE_FILE);
    if active.exists() {
        let file = File::open(&active).map_err(|source| TraceStoreError::Io {
            path: active.display().to_string(),
            source,
        })?;
        read_jsonl_records(&active, BufReader::new(file), &mut spans, &mut warnings)?;
    }
    spans.sort_by(|left, right| {
        left.started_at
            .cmp(&right.started_at)
            .then_with(|| left.id.cmp(&right.id))
    });
    let truncated_count = spans
        .iter()
        .filter(|span| matches!(&span.status, SpanStatus::Error { message } if message == "truncated_at_restart"))
        .count()
        .try_into()
        .unwrap_or(u64::MAX);
    if !session_dir.exists() {
        bytes = 0;
    }
    Ok(TraceReadResult {
        spans,
        warnings,
        bytes,
        has_rotated_archives,
        truncated_count,
    })
}

pub fn trace_artifact_bytes(session_dir: &Path) -> Result<u64, TraceStoreError> {
    if !session_dir.exists() {
        return Ok(0);
    }
    let mut total = 0u64;
    for entry in fs::read_dir(session_dir).map_err(|source| TraceStoreError::Io {
        path: session_dir.display().to_string(),
        source,
    })? {
        let entry = entry.map_err(|source| TraceStoreError::Io {
            path: session_dir.display().to_string(),
            source,
        })?;
        let path = entry.path();
        if path.is_dir()
            && path.file_name().and_then(|name| name.to_str()) == Some(CURRENT_SPANS_DIR)
        {
            total = total.saturating_add(dir_bytes(&path)?);
        } else if is_trace_artifact_file(&path) {
            total = total.saturating_add(
                fs::metadata(&path)
                    .map_err(|source| TraceStoreError::Io {
                        path: path.display().to_string(),
                        source,
                    })?
                    .len(),
            );
        }
    }
    Ok(total)
}

pub fn trace_artifact_count(session_dir: &Path) -> Result<usize, TraceStoreError> {
    if !session_dir.exists() {
        return Ok(0);
    }
    let mut count = 0usize;
    for entry in fs::read_dir(session_dir).map_err(|source| TraceStoreError::Io {
        path: session_dir.display().to_string(),
        source,
    })? {
        let entry = entry.map_err(|source| TraceStoreError::Io {
            path: session_dir.display().to_string(),
            source,
        })?;
        let path = entry.path();
        if path.is_dir()
            && path.file_name().and_then(|name| name.to_str()) == Some(CURRENT_SPANS_DIR)
        {
            count = count.saturating_add(count_files(&path)?);
        } else if is_trace_artifact_file(&path) {
            count = count.saturating_add(1);
        }
    }
    Ok(count)
}

pub fn recover_all_in_flight_spans(
    paths: &AllbertPaths,
    limits: TraceStorageLimits,
) -> Result<usize, TraceStoreError> {
    if !paths.sessions.exists() {
        return Ok(0);
    }
    let mut recovered = 0usize;
    for entry in fs::read_dir(&paths.sessions).map_err(|source| TraceStoreError::Io {
        path: paths.sessions.display().to_string(),
        source,
    })? {
        let entry = entry.map_err(|source| TraceStoreError::Io {
            path: paths.sessions.display().to_string(),
            source,
        })?;
        if !entry.path().is_dir() || entry.file_name().to_string_lossy().starts_with('.') {
            continue;
        }
        let session_id = entry.file_name().to_string_lossy().to_string();
        let writer = JsonlTraceWriter::new(paths, &session_id, limits.clone())?;
        recovered = recovered.saturating_add(writer.recover_in_flight()?.len());
    }
    Ok(recovered)
}

pub fn new_trace_id() -> String {
    uuid::Uuid::new_v4().simple().to_string()
}

pub fn new_span_id() -> String {
    uuid::Uuid::new_v4().simple().to_string()[..16].to_string()
}

pub fn sort_span_events(span: &mut Span) {
    span.events.sort_by(|left, right| {
        left.timestamp
            .cmp(&right.timestamp)
            .then_with(|| left.name.cmp(&right.name))
    });
}

fn summary_for_read_result(session_id: &str, result: &TraceReadResult) -> TraceSessionSummary {
    let started_at = result
        .spans
        .first()
        .map(|span| span.started_at)
        .unwrap_or_else(Utc::now);
    let last_touched_at = result
        .spans
        .iter()
        .filter_map(|span| span.ended_at.or(Some(span.started_at)))
        .max()
        .unwrap_or(started_at);
    let total_duration_ms = result
        .spans
        .iter()
        .filter(|span| span.parent_id.is_none())
        .filter_map(|span| span.duration_ms)
        .sum();
    TraceSessionSummary {
        session_id: session_id.into(),
        span_count: result.spans.len().try_into().unwrap_or(u64::MAX),
        root_span_count: result
            .spans
            .iter()
            .filter(|span| span.parent_id.is_none())
            .count()
            .try_into()
            .unwrap_or(u64::MAX),
        started_at,
        last_touched_at,
        total_duration_ms,
        bytes: result.bytes,
        has_rotated_archives: result.has_rotated_archives,
        truncated_count: result.truncated_count,
    }
}

fn read_jsonl_records<R: BufRead>(
    path: &Path,
    reader: R,
    spans: &mut Vec<Span>,
    warnings: &mut Vec<TraceReadWarning>,
) -> Result<(), TraceStoreError> {
    for (index, line) in reader.lines().enumerate() {
        let line_no = index + 1;
        let line = line.map_err(|source| TraceStoreError::Io {
            path: path.display().to_string(),
            source,
        })?;
        if line.trim().is_empty() {
            continue;
        }
        match serde_json::from_str::<TraceRecord>(&line) {
            Ok(record) => {
                record.validate_schema_version()?;
                spans.push(record.span);
            }
            Err(source) => warnings.push(TraceReadWarning {
                path: path.to_path_buf(),
                line: line_no,
                message: source.to_string(),
            }),
        }
    }
    Ok(())
}

fn archive_paths_for_dir(session_dir: &Path) -> Result<Vec<PathBuf>, TraceStoreError> {
    if !session_dir.exists() {
        return Ok(Vec::new());
    }
    let mut archives = Vec::new();
    for entry in fs::read_dir(session_dir).map_err(|source| TraceStoreError::Io {
        path: session_dir.display().to_string(),
        source,
    })? {
        let entry = entry.map_err(|source| TraceStoreError::Io {
            path: session_dir.display().to_string(),
            source,
        })?;
        let path = entry.path();
        if archive_index(&path).is_some() {
            archives.push(path);
        }
    }
    archives.sort_by_key(|path| archive_index(path).unwrap_or(0));
    Ok(archives)
}

fn archive_index(path: &Path) -> Option<u64> {
    let name = path.file_name()?.to_str()?;
    let index = name.strip_prefix("trace.")?.strip_suffix(".jsonl.gz")?;
    index.parse::<u64>().ok()
}

fn is_trace_artifact_file(path: &Path) -> bool {
    path.file_name()
        .and_then(|name| name.to_str())
        .is_some_and(|name| name == TRACE_ACTIVE_FILE || archive_index(path).is_some())
}

fn count_files(path: &Path) -> Result<usize, TraceStoreError> {
    if !path.exists() {
        return Ok(0);
    }
    let mut count = 0usize;
    for entry in fs::read_dir(path).map_err(|source| TraceStoreError::Io {
        path: path.display().to_string(),
        source,
    })? {
        let entry = entry.map_err(|source| TraceStoreError::Io {
            path: path.display().to_string(),
            source,
        })?;
        if entry.path().is_dir() {
            count = count.saturating_add(count_files(&entry.path())?);
        } else {
            count = count.saturating_add(1);
        }
    }
    Ok(count)
}

fn dir_bytes(path: &Path) -> Result<u64, TraceStoreError> {
    if !path.exists() {
        return Ok(0);
    }
    let mut total = 0u64;
    for entry in fs::read_dir(path).map_err(|source| TraceStoreError::Io {
        path: path.display().to_string(),
        source,
    })? {
        let entry = entry.map_err(|source| TraceStoreError::Io {
            path: path.display().to_string(),
            source,
        })?;
        let path = entry.path();
        if path.is_dir() {
            total = total.saturating_add(dir_bytes(&path)?);
        } else {
            total = total.saturating_add(
                fs::metadata(&path)
                    .map_err(|source| TraceStoreError::Io {
                        path: path.display().to_string(),
                        source,
                    })?
                    .len(),
            );
        }
    }
    Ok(total)
}

fn validate_session_id(session_id: &str) -> Result<(), TraceStoreError> {
    if session_id.is_empty()
        || session_id.contains('/')
        || session_id.contains('\\')
        || session_id == "."
        || session_id == ".."
    {
        return Err(TraceStoreError::InvalidPath(format!(
            "invalid session id `{session_id}`"
        )));
    }
    Ok(())
}

fn duration_ms(started_at: DateTime<Utc>, ended_at: DateTime<Utc>) -> u64 {
    (ended_at - started_at)
        .num_milliseconds()
        .max(0)
        .try_into()
        .unwrap_or(u64::MAX)
}

#[cfg(test)]
mod tests {
    use super::*;
    use allbert_proto::{is_valid_otlp_span_id, is_valid_otlp_trace_id};

    fn ts(seconds: i64) -> DateTime<Utc> {
        DateTime::from_timestamp(seconds, 0).expect("fixture timestamp should be valid")
    }

    fn fixture_span(id: &str, parent_id: Option<&str>, started_at: DateTime<Utc>) -> Span {
        Span {
            id: id.into(),
            parent_id: parent_id.map(str::to_string),
            session_id: "session-a".into(),
            trace_id: "33333333333333333333333333333333".into(),
            name: "turn".into(),
            kind: SpanKind::Internal,
            started_at,
            ended_at: Some(started_at),
            duration_ms: Some(1),
            status: SpanStatus::Ok,
            attributes: BTreeMap::new(),
            events: Vec::new(),
        }
    }

    #[test]
    fn trace_record_roundtrips_schema_version() {
        let span = fixture_span("1111111111111111", None, ts(1));
        let record = TraceRecord::span(span.clone());
        let raw = serde_json::to_string(&record).expect("record serializes");
        let decoded: TraceRecord = serde_json::from_str(&raw).expect("record deserializes");
        decoded
            .validate_schema_version()
            .expect("schema version is supported");
        assert_eq!(decoded.span, span);
    }

    #[test]
    fn trace_record_rejects_future_schema_version() {
        let mut record = TraceRecord::span(fixture_span("1111111111111111", None, ts(1)));
        record.schema_version = TRACE_RECORD_SCHEMA_VERSION + 1;
        let err = record
            .validate_schema_version()
            .expect_err("future schema should reject");
        assert!(err.to_string().contains("unsupported trace schema version"));
    }

    #[test]
    fn trace_ids_are_otlp_compatible_lower_hex() {
        assert!(is_valid_otlp_trace_id(&new_trace_id()));
        assert!(is_valid_otlp_span_id(&new_span_id()));
    }

    #[test]
    fn span_events_sort_by_timestamp() {
        let mut span = fixture_span("1111111111111111", None, ts(3));
        span.events = vec![
            SpanEvent {
                timestamp: ts(3),
                name: "third".into(),
                attributes: BTreeMap::new(),
            },
            SpanEvent {
                timestamp: ts(1),
                name: "first".into(),
                attributes: BTreeMap::new(),
            },
            SpanEvent {
                timestamp: ts(2),
                name: "second".into(),
                attributes: BTreeMap::new(),
            },
        ];
        sort_span_events(&mut span);
        assert_eq!(
            span.events
                .iter()
                .map(|event| event.name.as_str())
                .collect::<Vec<_>>(),
            vec!["first", "second", "third"]
        );
    }

    #[test]
    fn jsonl_writer_snapshots_appends_and_recovers_in_flight_spans() {
        let temp = tempfile::tempdir().expect("tempdir");
        let paths = AllbertPaths::under(temp.path().join(".allbert"));
        paths.ensure().expect("paths ensure");
        let writer = JsonlTraceWriter::new(
            &paths,
            "session-a",
            TraceStorageLimits::from_session_cap_mb(5),
        )
        .expect("writer");
        let mut span = fixture_span("1111111111111111", None, ts(1));
        span.ended_at = None;
        span.duration_ms = None;
        writer.span_started(&span).expect("snapshot start");
        assert!(writer.snapshot_path(&span.id).exists());
        span.ended_at = Some(ts(2));
        span.duration_ms = Some(1000);
        writer.span_ended(&span).expect("span end");
        assert!(!writer.snapshot_path(&span.id).exists());

        let mut stale = fixture_span("2222222222222222", None, ts(3));
        stale.ended_at = None;
        stale.duration_ms = None;
        writer.span_started(&stale).expect("snapshot stale");
        let recovered = writer.recover_in_flight().expect("recover stale");
        assert_eq!(recovered.len(), 1);
        assert!(matches!(
            recovered[0].status,
            SpanStatus::Error { ref message } if message == "truncated_at_restart"
        ));

        let read = read_session_trace_dir(&paths.sessions.join("session-a")).expect("read traces");
        assert_eq!(read.spans.len(), 2);
        assert_eq!(read.truncated_count, 1);
    }

    #[test]
    fn rotation_and_reader_include_archives_in_order() {
        let temp = tempfile::tempdir().expect("tempdir");
        let paths = AllbertPaths::under(temp.path().join(".allbert"));
        paths.ensure().expect("paths ensure");
        let writer = JsonlTraceWriter::new(
            &paths,
            "session-a",
            TraceStorageLimits {
                session_disk_cap_bytes: 1,
            },
        )
        .expect("writer");
        writer
            .span_ended(&fixture_span("2222222222222222", None, ts(2)))
            .expect("first span");
        writer
            .span_ended(&fixture_span("1111111111111111", None, ts(1)))
            .expect("second span");

        let read = read_session_trace_dir(&paths.sessions.join("session-a")).expect("read traces");
        assert!(read.has_rotated_archives);
        assert_eq!(
            read.spans
                .iter()
                .map(|span| span.id.as_str())
                .collect::<Vec<_>>(),
            vec!["1111111111111111", "2222222222222222"]
        );
    }

    #[test]
    fn reader_skips_malformed_jsonl_with_warning() {
        let temp = tempfile::tempdir().expect("tempdir");
        let paths = AllbertPaths::under(temp.path().join(".allbert"));
        paths.ensure().expect("paths ensure");
        let session_dir = paths.sessions.join("session-a");
        fs::create_dir_all(&session_dir).expect("session dir");
        let good = serde_json::to_string(&TraceRecord::span(fixture_span(
            "1111111111111111",
            None,
            ts(1),
        )))
        .expect("good record");
        fs::write(
            session_dir.join(TRACE_ACTIVE_FILE),
            format!("{good}\n{{broken\n"),
        )
        .expect("trace write");

        let read = read_session_trace_dir(&session_dir).expect("read traces");
        assert_eq!(read.spans.len(), 1);
        assert_eq!(read.warnings.len(), 1);
    }
}
