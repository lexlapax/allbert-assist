use std::fs::{self, File};
use std::io::{Read, Write};
use std::path::{Component, Path, PathBuf};

use allbert_kernel::{memory, trace_artifact_bytes, trace_artifact_count, AllbertPaths, Config};
use anyhow::{anyhow, Context, Result};
use flate2::read::GzDecoder;
use flate2::write::GzEncoder;
use flate2::Compression;
use serde::Serialize;
use tar::{Archive, Builder, Header};
use time::format_description::well_known::Rfc3339;
use time::OffsetDateTime;

const MANIFEST_PATH: &str = ".allbert-manifest.json";
const PROFILE_FORMAT_VERSION: &str = "0.8.0";

#[derive(Debug, Clone, Copy)]
pub enum ImportMode {
    Overlay,
    Replace,
}

#[derive(Debug, Serialize)]
struct ProfileManifest {
    version: String,
    exported_at: String,
    exported_from_host: String,
    identity_id: Option<String>,
    counts: ManifestCounts,
    excluded: Vec<String>,
}

#[derive(Debug, Serialize)]
struct ManifestCounts {
    sessions: usize,
    approvals_pending: usize,
    approvals_resolved: usize,
    memory_durable: usize,
    memory_staged: usize,
    jobs: usize,
    skills: usize,
    trace_artifacts: usize,
    trace_bytes: u64,
    adapters_installed: usize,
    adapter_bytes: u64,
}

struct ImportEntry {
    rel: PathBuf,
    is_dir: bool,
    bytes: Vec<u8>,
    mtime: u64,
}

pub fn export_profile(
    paths: &AllbertPaths,
    destination: &Path,
    include_secrets: bool,
    include_adapters: bool,
    dry_run: bool,
    identity_id: Option<&str>,
) -> Result<String> {
    if dry_run {
        return render_export_dry_run(paths, destination, include_secrets, include_adapters);
    }
    if let Some(parent) = destination.parent() {
        fs::create_dir_all(parent).with_context(|| format!("create {}", parent.display()))?;
    }

    let file =
        File::create(destination).with_context(|| format!("create {}", destination.display()))?;
    let encoder = GzEncoder::new(file, Compression::default());
    let mut tar = Builder::new(encoder);

    for rel in continuity_roots() {
        let abs = paths.root.join(rel);
        append_path_if_exists(&mut tar, &abs, rel)?;
    }
    if include_secrets {
        append_path_if_exists(&mut tar, &paths.secrets, Path::new("secrets"))?;
    }
    if include_adapters {
        append_path_if_exists(
            &mut tar,
            &paths.adapters_installed,
            Path::new("adapters/installed"),
        )?;
        append_path_if_exists(
            &mut tar,
            &paths.adapters_active,
            Path::new("adapters/active.json"),
        )?;
    }

    let manifest = ProfileManifest {
        version: PROFILE_FORMAT_VERSION.to_string(),
        exported_at: OffsetDateTime::now_utc().format(&Rfc3339)?,
        exported_from_host: hostname_guess(),
        identity_id: identity_id.map(|value| value.to_string()),
        counts: collect_counts(paths, include_adapters)?,
        excluded: excluded_paths(include_secrets, include_adapters),
    };
    let manifest_json = serde_json::to_vec_pretty(&manifest)?;
    let mut header = Header::new_gnu();
    header.set_size(manifest_json.len() as u64);
    header.set_mode(0o644);
    header.set_cksum();
    tar.append_data(&mut header, MANIFEST_PATH, manifest_json.as_slice())?;

    tar.finish()?;

    Ok(format!(
        "exported profile to {}\nmanifest: {}\ninclude secrets: {}\ninclude adapters: {}",
        destination.display(),
        MANIFEST_PATH,
        if include_secrets { "yes" } else { "no" },
        if include_adapters { "yes" } else { "no" }
    ))
}

pub fn import_profile(
    paths: &AllbertPaths,
    config: &Config,
    archive_path: &Path,
    mode: ImportMode,
    yes: bool,
) -> Result<String> {
    if paths.daemon_lock.exists() {
        return Err(anyhow!(
            "refusing profile import while daemon.lock exists at {}; stop daemon and remove stale lock first",
            paths.daemon_lock.display()
        ));
    }
    if matches!(mode, ImportMode::Replace) && !yes {
        return Err(anyhow!(
            "--replace is destructive; rerun with --yes to confirm"
        ));
    }

    let file =
        File::open(archive_path).with_context(|| format!("open {}", archive_path.display()))?;
    let mut archive = Archive::new(GzDecoder::new(file));
    let mut entries = Vec::new();
    for entry_result in archive.entries()? {
        let mut entry = entry_result?;
        let rel = entry.path()?.to_path_buf();
        if rel == Path::new(MANIFEST_PATH) {
            continue;
        }
        validate_relative(&rel)?;
        let mut bytes = Vec::new();
        entry.read_to_end(&mut bytes)?;
        entries.push(ImportEntry {
            rel,
            is_dir: entry.header().entry_type().is_dir(),
            bytes,
            mtime: entry.header().mtime().unwrap_or(0),
        });
    }

    if matches!(mode, ImportMode::Replace) {
        wipe_continuity_paths(paths)?;
    }

    let mut imported = 0usize;
    let mut skipped = 0usize;
    for entry in entries {
        let target = paths.root.join(&entry.rel);
        if entry.is_dir {
            fs::create_dir_all(&target).with_context(|| format!("create {}", target.display()))?;
            continue;
        }
        if let Some(parent) = target.parent() {
            fs::create_dir_all(parent).with_context(|| format!("create {}", parent.display()))?;
        }
        if matches!(mode, ImportMode::Overlay) && target.exists() {
            let local_mtime = metadata_mtime_secs(&target).unwrap_or(0);
            if local_mtime >= entry.mtime {
                skipped += 1;
                continue;
            }
        }
        atomic_write(&target, &entry.bytes)?;
        imported += 1;
    }

    let rebuild = memory::rebuild_memory_index(paths, &config.memory, true)?;
    let verify = memory::verify_curated_memory(paths, &config.memory)?;
    Ok(format!(
        "imported profile from {}\nmode: {}\nfiles imported: {}\nfiles skipped: {}\nmemory rebuild: docs={} reason={}\nmemory verify: {}",
        archive_path.display(),
        match mode {
            ImportMode::Overlay => "overlay",
            ImportMode::Replace => "replace",
        },
        imported,
        skipped,
        rebuild.docs_indexed,
        rebuild.reason,
        if verify.is_healthy() { "ok" } else { "failed" }
    ))
}

fn continuity_roots() -> Vec<&'static Path> {
    vec![
        Path::new("identity/user.md"),
        Path::new("config.toml"),
        Path::new("config"),
        Path::new("memory/MEMORY.md"),
        Path::new("memory/notes"),
        Path::new("memory/daily"),
        Path::new("memory/staging"),
        Path::new("sessions"),
        Path::new("jobs"),
        Path::new("skills/installed"),
        Path::new("skills/incoming"),
        Path::new("SOUL.md"),
        Path::new("USER.md"),
        Path::new("IDENTITY.md"),
        Path::new("TOOLS.md"),
        Path::new("PERSONALITY.md"),
        Path::new("AGENTS.md"),
        Path::new("HEARTBEAT.md"),
    ]
}

fn excluded_paths(include_secrets: bool, include_adapters: bool) -> Vec<String> {
    let mut excluded = vec![
        "adapters/runs/".to_string(),
        "adapters/incoming/".to_string(),
        "adapters/runtime/".to_string(),
        "adapters/history.jsonl".to_string(),
        "memory/index/".to_string(),
        "run/".to_string(),
        "logs/".to_string(),
        "traces/".to_string(),
        "costs.jsonl".to_string(),
        "daemon.lock".to_string(),
    ];
    if !include_secrets {
        excluded.insert(0, "secrets/".to_string());
    }
    if !include_adapters {
        excluded.insert(0, "adapters/".to_string());
    }
    excluded
}

fn append_path_if_exists(tar: &mut Builder<GzEncoder<File>>, abs: &Path, rel: &Path) -> Result<()> {
    if !abs.exists() {
        return Ok(());
    }
    if abs.is_dir() {
        tar.append_dir_all(rel, abs)?;
    } else {
        tar.append_path_with_name(abs, rel)?;
    }
    Ok(())
}

fn collect_counts(paths: &AllbertPaths, include_adapters: bool) -> Result<ManifestCounts> {
    let mut pending = 0usize;
    let mut resolved = 0usize;
    let approvals_root = &paths.sessions;
    if approvals_root.exists() {
        for file in collect_files_recursive(approvals_root)? {
            let normalized = file.to_string_lossy();
            if !normalized.contains("/approvals/") || !normalized.ends_with(".md") {
                continue;
            }
            let text = fs::read_to_string(&file).unwrap_or_default();
            if text.contains("status: pending") {
                pending += 1;
            } else {
                resolved += 1;
            }
        }
    }
    let (trace_artifacts, trace_bytes) = collect_trace_counts(paths)?;
    let (adapters_installed, adapter_bytes) = if include_adapters {
        collect_adapter_counts(paths)?
    } else {
        (0, 0)
    };
    Ok(ManifestCounts {
        sessions: immediate_dir_count(&paths.sessions)?,
        approvals_pending: pending,
        approvals_resolved: resolved,
        memory_durable: collect_files_recursive(&paths.memory_notes)?.len()
            + collect_files_recursive(&paths.memory_daily)?.len(),
        memory_staged: collect_files_recursive(&paths.memory_staging)?
            .into_iter()
            .filter(|path| {
                let value = path.to_string_lossy();
                value.ends_with(".md")
                    && !value.contains("/.rejected/")
                    && !value.contains("/reject/")
                    && !value.contains("/.expired/")
            })
            .count(),
        jobs: collect_files_recursive(&paths.jobs_definitions)?.len(),
        skills: immediate_dir_count(&paths.skills_installed)?,
        trace_artifacts,
        trace_bytes,
        adapters_installed,
        adapter_bytes,
    })
}

fn collect_adapter_counts(paths: &AllbertPaths) -> Result<(usize, u64)> {
    let mut bytes = 0u64;
    let installed = immediate_dir_count(&paths.adapters_installed)?;
    for file in collect_files_recursive(&paths.adapters_installed)? {
        bytes = bytes.saturating_add(fs::metadata(&file)?.len());
    }
    if paths.adapters_active.exists() {
        bytes = bytes.saturating_add(fs::metadata(&paths.adapters_active)?.len());
    }
    Ok((installed, bytes))
}

fn render_export_dry_run(
    paths: &AllbertPaths,
    destination: &Path,
    include_secrets: bool,
    include_adapters: bool,
) -> Result<String> {
    let mut included = continuity_roots()
        .into_iter()
        .map(|path| path.display().to_string())
        .collect::<Vec<_>>();
    if include_secrets {
        included.push("secrets/".into());
    }
    if include_adapters {
        included.push("adapters/installed/".into());
        included.push("adapters/active.json".into());
    }
    let counts = collect_counts(paths, include_adapters)?;
    Ok(format!(
        "profile export dry run\ndestination: {}\ninclude secrets: {}\ninclude adapters: {}\nincluded:\n  - {}\nexcluded:\n  - {}\nadapters installed: {}\nadapter bytes: {}",
        destination.display(),
        if include_secrets { "yes" } else { "no" },
        if include_adapters { "yes" } else { "no" },
        included.join("\n  - "),
        excluded_paths(include_secrets, include_adapters).join("\n  - "),
        counts.adapters_installed,
        counts.adapter_bytes
    ))
}

fn collect_trace_counts(paths: &AllbertPaths) -> Result<(usize, u64)> {
    if !paths.sessions.exists() {
        return Ok((0, 0));
    }
    let mut artifacts = 0usize;
    let mut bytes = 0u64;
    for entry in fs::read_dir(&paths.sessions).with_context(|| {
        format!(
            "read sessions for trace accounting at {}",
            paths.sessions.display()
        )
    })? {
        let entry = entry?;
        if !entry.file_type()?.is_dir() || entry.file_name().to_string_lossy().starts_with('.') {
            continue;
        }
        artifacts = artifacts.saturating_add(trace_artifact_count(&entry.path())?);
        bytes = bytes.saturating_add(trace_artifact_bytes(&entry.path())?);
    }
    Ok((artifacts, bytes))
}

fn immediate_dir_count(root: &Path) -> Result<usize> {
    if !root.exists() {
        return Ok(0);
    }
    let mut total = 0usize;
    for entry in fs::read_dir(root).with_context(|| format!("read {}", root.display()))? {
        let entry = entry?;
        if entry.file_type()?.is_dir() {
            let name = entry.file_name();
            if !name.to_string_lossy().starts_with('.') {
                total += 1;
            }
        }
    }
    Ok(total)
}

fn collect_files_recursive(root: &Path) -> Result<Vec<PathBuf>> {
    if !root.exists() {
        return Ok(Vec::new());
    }
    let mut stack = vec![root.to_path_buf()];
    let mut files = Vec::new();
    while let Some(current) = stack.pop() {
        for entry in
            fs::read_dir(&current).with_context(|| format!("read {}", current.display()))?
        {
            let entry = entry?;
            let file_type = entry.file_type()?;
            if file_type.is_dir() {
                stack.push(entry.path());
            } else if file_type.is_file() {
                files.push(entry.path());
            }
        }
    }
    Ok(files)
}

fn validate_relative(path: &Path) -> Result<()> {
    if path.is_absolute()
        || path.components().any(|component| {
            matches!(
                component,
                Component::ParentDir | Component::RootDir | Component::Prefix(_)
            )
        })
    {
        return Err(anyhow!(
            "archive entry escapes profile root: {}",
            path.display()
        ));
    }
    Ok(())
}

fn wipe_continuity_paths(paths: &AllbertPaths) -> Result<()> {
    for rel in continuity_roots() {
        let abs = paths.root.join(rel);
        if abs.is_dir() {
            let _ = fs::remove_dir_all(&abs);
        } else {
            let _ = fs::remove_file(&abs);
        }
    }
    Ok(())
}

fn metadata_mtime_secs(path: &Path) -> Result<u64> {
    let modified = fs::metadata(path)?.modified()?;
    Ok(modified
        .duration_since(std::time::UNIX_EPOCH)
        .unwrap_or_default()
        .as_secs())
}

fn atomic_write(path: &Path, bytes: &[u8]) -> Result<()> {
    let parent = path
        .parent()
        .ok_or_else(|| anyhow!("{} has no parent directory", path.display()))?;
    fs::create_dir_all(parent).with_context(|| format!("create {}", parent.display()))?;

    let tmp = path.with_extension("tmp");
    {
        let mut file = File::create(&tmp).with_context(|| format!("create {}", tmp.display()))?;
        file.write_all(bytes)
            .with_context(|| format!("write {}", tmp.display()))?;
        file.sync_all()
            .with_context(|| format!("fsync {}", tmp.display()))?;
    }

    fs::rename(&tmp, path)
        .with_context(|| format!("rename {} -> {}", tmp.display(), path.display()))?;
    File::open(parent)
        .with_context(|| format!("open {}", parent.display()))?
        .sync_all()
        .with_context(|| format!("fsync {}", parent.display()))?;
    Ok(())
}

fn hostname_guess() -> String {
    std::env::var("HOSTNAME")
        .ok()
        .or_else(|| std::env::var("COMPUTERNAME").ok())
        .unwrap_or_else(|| "unknown".to_string())
}

#[cfg(test)]
mod tests {
    use std::sync::atomic::{AtomicUsize, Ordering};

    use super::*;

    static TEMP_COUNTER: AtomicUsize = AtomicUsize::new(0);

    struct TempRoot {
        path: PathBuf,
    }

    impl TempRoot {
        fn new() -> Self {
            let path = std::env::temp_dir().join(format!(
                "allbert-cli-profile-{}-{}",
                std::process::id(),
                TEMP_COUNTER.fetch_add(1, Ordering::Relaxed)
            ));
            std::fs::create_dir_all(&path).expect("temp root should create");
            Self { path }
        }

        fn paths(&self) -> AllbertPaths {
            AllbertPaths::under(self.path.clone())
        }
    }

    impl Drop for TempRoot {
        fn drop(&mut self) {
            let _ = std::fs::remove_dir_all(&self.path);
        }
    }

    #[test]
    fn export_then_import_overlay_round_trips_memory_note() {
        let temp = TempRoot::new();
        let paths = temp.paths();
        paths.ensure().expect("paths should ensure");
        let config = Config::default_template();

        std::fs::write(paths.memory_notes.join("sample.md"), "# Sample\n")
            .expect("sample note should write");
        let archive = temp.path.join("profile.tgz");
        export_profile(&paths, &archive, false, false, false, Some("usr_test"))
            .expect("export should succeed");

        std::fs::remove_file(paths.memory_notes.join("sample.md"))
            .expect("sample note should delete");
        let rendered = import_profile(&paths, &config, &archive, ImportMode::Overlay, false)
            .expect("import should succeed");

        assert!(rendered.contains("mode: overlay"));
        assert!(paths.memory_notes.join("sample.md").exists());
    }

    #[test]
    fn export_then_import_overlay_round_trips_pending_approval() {
        let temp = TempRoot::new();
        let paths = temp.paths();
        paths.ensure().expect("paths should ensure");
        let config = Config::default_template();

        let approval_dir = paths.sessions.join("telegram-session").join("approvals");
        std::fs::create_dir_all(&approval_dir).expect("approval dir should create");
        std::fs::write(
            approval_dir.join("approval-1.md"),
            "---\nid: approval-1\nsession_id: telegram-session\nchannel: telegram\nsender: telegram:12345\nagent: allbert/root\ntool: process_exec\nrequest_id: 7\nrequested_at: 2026-04-21T00:00:00Z\nexpires_at: 2026-04-21T01:00:00Z\nkind: tool_approval\nstatus: pending\n---\n\nrun echo hello\n",
        )
        .expect("approval should write");

        let archive = temp.path.join("profile-approval.tgz");
        export_profile(&paths, &archive, false, false, false, Some("usr_test"))
            .expect("export should succeed");

        std::fs::remove_file(approval_dir.join("approval-1.md")).expect("approval should delete");
        let rendered = import_profile(&paths, &config, &archive, ImportMode::Overlay, false)
            .expect("import should succeed");

        assert!(rendered.contains("mode: overlay"));
        let restored =
            std::fs::read_to_string(approval_dir.join("approval-1.md")).expect("approval exists");
        assert!(restored.contains("status: pending"));
    }

    #[test]
    fn export_manifest_counts_session_traces_and_excludes_top_level_traces() {
        let temp = TempRoot::new();
        let paths = temp.paths();
        paths.ensure().expect("paths should ensure");

        let session_dir = paths.sessions.join("trace-session");
        std::fs::create_dir_all(&session_dir).expect("session dir should create");
        std::fs::write(session_dir.join("trace.jsonl"), "{}\n").expect("session trace writes");
        std::fs::write(paths.traces.join("legacy.log"), "debug only").expect("legacy trace writes");

        let archive = temp.path.join("profile-trace.tgz");
        export_profile(&paths, &archive, false, false, false, Some("usr_test"))
            .expect("export should succeed");

        let file = File::open(&archive).expect("archive should open");
        let mut archive = Archive::new(GzDecoder::new(file));
        let mut manifest = None;
        let mut saw_session_trace = false;
        let mut saw_top_level_trace = false;
        for entry_result in archive.entries().expect("archive entries") {
            let mut entry = entry_result.expect("entry");
            let rel = entry.path().expect("entry path").to_path_buf();
            if rel == Path::new(MANIFEST_PATH) {
                let mut raw = String::new();
                entry.read_to_string(&mut raw).expect("manifest reads");
                manifest = Some(raw);
            } else if rel == Path::new("sessions/trace-session/trace.jsonl") {
                saw_session_trace = true;
            } else if rel == Path::new("traces/legacy.log") {
                saw_top_level_trace = true;
            }
        }

        let manifest: serde_json::Value =
            serde_json::from_str(&manifest.expect("manifest exists")).expect("manifest json");
        assert_eq!(manifest["counts"]["trace_artifacts"], 1);
        assert_eq!(manifest["counts"]["trace_bytes"], 3);
        assert!(saw_session_trace);
        assert!(!saw_top_level_trace);
    }

    #[test]
    fn profile_export_includes_adapters_only_when_requested() {
        let temp = TempRoot::new();
        let paths = temp.paths();
        paths.ensure().expect("paths should ensure");
        let installed = paths.adapters_installed.join("adapter-1");
        std::fs::create_dir_all(&installed).expect("installed adapter dir");
        std::fs::write(installed.join("adapter.toml"), "id = \"adapter-1\"\n")
            .expect("adapter manifest");
        std::fs::write(&paths.adapters_active, "{\"adapter_id\":\"adapter-1\"}\n")
            .expect("active pointer");
        std::fs::write(&paths.adapters_history, "{}\n").expect("history");
        std::fs::write(
            paths.adapters_runtime.join("derived.Modelfile"),
            "FROM base\n",
        )
        .expect("runtime");

        let excluded_archive = temp.path.join("profile-no-adapters.tgz");
        export_profile(&paths, &excluded_archive, false, false, false, None)
            .expect("export should succeed");
        let excluded_entries = archive_entries(&excluded_archive);
        assert!(!excluded_entries.contains(&"adapters/installed/adapter-1/adapter.toml".into()));
        assert!(!excluded_entries.contains(&"adapters/active.json".into()));

        let included_archive = temp.path.join("profile-with-adapters.tgz");
        export_profile(&paths, &included_archive, false, true, false, None)
            .expect("export should succeed");
        let included_entries = archive_entries(&included_archive);
        assert!(included_entries.contains(&"adapters/installed/adapter-1/adapter.toml".into()));
        assert!(included_entries.contains(&"adapters/active.json".into()));
        assert!(!included_entries.contains(&"adapters/history.jsonl".into()));
        assert!(!included_entries.contains(&"adapters/runtime/derived.Modelfile".into()));

        let dry_run =
            export_profile(&paths, &included_archive, false, true, true, None).expect("dry run");
        assert!(dry_run.contains("include adapters: yes"));
        assert!(dry_run.contains("adapters installed: 1"));
        assert!(dry_run.contains("adapters/runs/"));
    }

    #[test]
    fn replace_requires_yes() {
        let temp = TempRoot::new();
        let paths = temp.paths();
        paths.ensure().expect("paths should ensure");
        let config = Config::default_template();
        let archive = temp.path.join("empty.tgz");
        export_profile(&paths, &archive, false, false, false, None).expect("export should succeed");

        let err = import_profile(&paths, &config, &archive, ImportMode::Replace, false)
            .expect_err("replace should require yes");
        assert!(err.to_string().contains("--yes"));
    }

    #[test]
    fn replace_with_yes_replaces_continuity_tree() {
        let temp = TempRoot::new();
        let paths = temp.paths();
        paths.ensure().expect("paths should ensure");
        let config = Config::default_template();

        std::fs::write(paths.memory_notes.join("kept.md"), "# Kept\n").expect("kept note writes");
        let archive = temp.path.join("replace.tgz");
        export_profile(&paths, &archive, false, false, false, None).expect("export should succeed");

        std::fs::write(paths.memory_notes.join("local-only.md"), "# Local only\n")
            .expect("local-only note writes");
        let rendered = import_profile(&paths, &config, &archive, ImportMode::Replace, true)
            .expect("replace import should succeed");

        assert!(rendered.contains("mode: replace"));
        assert!(paths.memory_notes.join("kept.md").exists());
        assert!(
            !paths.memory_notes.join("local-only.md").exists(),
            "replace should wipe files not present in archive"
        );
        assert!(
            !paths.daemon_lock.exists(),
            "replace import should keep lockfile absent in restored profile"
        );
    }

    #[test]
    fn import_refuses_when_daemon_lock_exists() {
        let temp = TempRoot::new();
        let paths = temp.paths();
        paths.ensure().expect("paths should ensure");
        let config = Config::default_template();
        let archive = temp.path.join("daemon-lock.tgz");
        export_profile(&paths, &archive, false, false, false, None).expect("export should succeed");

        std::fs::write(paths.daemon_lock.clone(), "{\"pid\":1}").expect("daemon lock should write");
        let err = import_profile(&paths, &config, &archive, ImportMode::Replace, true)
            .expect_err("daemon lock should block import");
        assert!(err.to_string().contains("daemon.lock"));
    }

    fn archive_entries(path: &Path) -> Vec<String> {
        let file = File::open(path).expect("archive should open");
        let mut archive = Archive::new(GzDecoder::new(file));
        archive
            .entries()
            .expect("archive entries")
            .map(|entry| {
                entry
                    .expect("entry")
                    .path()
                    .expect("entry path")
                    .display()
                    .to_string()
            })
            .collect()
    }
}
