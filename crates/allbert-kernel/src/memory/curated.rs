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
use sha2::{Digest, Sha256};
use tantivy::doc;
use tantivy::schema::{Schema, INDEXED, STORED, STRING, TEXT};
use time::format_description::well_known::Rfc3339;
use time::OffsetDateTime;

use crate::config::MemoryConfig;
use crate::error::KernelError;
use crate::paths::AllbertPaths;

const MANIFEST_SCHEMA_VERSION: u32 = 1;
const INDEX_SCHEMA_VERSION: u32 = 1;
const TANTIVY_VERSION: &str = "0.22";

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

#[derive(Debug, Deserialize)]
struct StageFrontmatter {
    #[serde(default)]
    kind: Option<String>,
    #[serde(default)]
    expires_at: Option<String>,
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
            serde_yaml::from_str(frontmatter).unwrap_or(StageFrontmatter {
                kind: Some("unknown".into()),
                expires_at: None,
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
        return Ok(StageFrontmatter {
            kind: None,
            expires_at: None,
        });
    }
    serde_yaml::from_str(frontmatter)
        .map_err(|e| KernelError::InitFailed(format!("parse {} frontmatter: {e}", path.display())))
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
}
