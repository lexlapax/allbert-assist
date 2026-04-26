use std::collections::{BTreeMap, HashSet};
use std::io::ErrorKind;
use std::path::{Path, PathBuf};
use std::process::Stdio;
use std::time::{Duration, SystemTime};

use serde::{Deserialize, Serialize};
use tokio::io::{AsyncRead, AsyncReadExt, AsyncWrite, AsyncWriteExt};
use tokio::process::Command;

use crate::atomic_write;
use crate::config::{LocalUtilitiesConfig, SecurityConfig};
use crate::error::KernelError;
use crate::paths::AllbertPaths;
use crate::security::{self, NormalizedExec, PolicyDecision};
use crate::Config;

pub const UTILITY_MANIFEST_SCHEMA_VERSION: u16 = 1;

#[derive(Debug, Clone, Copy, Serialize, Deserialize, PartialEq, Eq)]
#[serde(rename_all = "kebab-case")]
pub enum UtilityStatus {
    Ok,
    Missing,
    Changed,
    Denied,
    NeedsReview,
}

impl UtilityStatus {
    pub fn label(self) -> &'static str {
        match self {
            Self::Ok => "ok",
            Self::Missing => "missing",
            Self::Changed => "changed",
            Self::Denied => "denied",
            Self::NeedsReview => "needs-review",
        }
    }
}

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq, Eq)]
pub struct EnabledUtilityEntry {
    pub id: String,
    pub path: String,
    pub path_canonical: String,
    pub version: String,
    pub help_summary: String,
    pub enabled_at: String,
    pub verified_at: String,
    pub status: UtilityStatus,
    pub size_bytes: u64,
    pub modified_at: String,
    #[serde(default = "default_pipe_allowed")]
    pub pipe_allowed: bool,
}

fn default_pipe_allowed() -> bool {
    true
}

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq, Eq)]
pub struct UtilityManifest {
    pub schema_version: u16,
    #[serde(default)]
    pub utilities: Vec<EnabledUtilityEntry>,
}

impl Default for UtilityManifest {
    fn default() -> Self {
        Self {
            schema_version: UTILITY_MANIFEST_SCHEMA_VERSION,
            utilities: Vec::new(),
        }
    }
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct LocalUtilityCatalogEntry {
    pub id: &'static str,
    pub name: &'static str,
    pub description: &'static str,
    pub executable_candidates: &'static [&'static str],
    pub pipe_allowed: bool,
}

#[derive(Debug, Clone, Serialize, PartialEq, Eq)]
pub struct LocalUtilityDiscovery {
    pub id: String,
    pub name: String,
    pub description: String,
    pub executable_candidates: Vec<String>,
    pub pipe_allowed: bool,
    pub installed_path: Option<String>,
    pub enabled: bool,
    pub status: Option<UtilityStatus>,
}

#[derive(Debug, Clone, Serialize, PartialEq, Eq)]
pub struct UtilityEnableResult {
    pub entry: EnabledUtilityEntry,
    pub exec_policy: UtilityExecPolicy,
}

#[derive(Debug, Clone, Serialize, PartialEq, Eq)]
pub struct UtilityDoctorReport {
    pub manifest_path: String,
    pub entries: Vec<EnabledUtilityEntry>,
}

#[derive(Debug, Clone, Serialize, PartialEq, Eq)]
pub struct UtilityExecPolicy {
    pub hard_denied: bool,
    pub auto_allowed: bool,
    pub requires_approval: bool,
    pub note: String,
}

#[derive(Debug, Clone, Default, Deserialize, PartialEq, Eq)]
#[serde(default, deny_unknown_fields)]
pub struct UnixPipeInput {
    pub stages: Vec<UnixPipeStageInput>,
    pub stdin: Option<String>,
    pub cwd: Option<String>,
    pub timeout_s: Option<u64>,
}

#[derive(Debug, Clone, Default, Deserialize, PartialEq, Eq)]
#[serde(default, deny_unknown_fields)]
pub struct UnixPipeStageInput {
    #[serde(alias = "utility")]
    pub utility_id: String,
    pub args: Vec<String>,
}

#[derive(Debug, Clone, Serialize, PartialEq, Eq)]
pub struct UnixPipeRunSummary {
    pub ok: bool,
    pub timed_out: bool,
    pub cap_violated: bool,
    pub stdout: String,
    pub stdout_bytes: usize,
    pub stdout_truncated: bool,
    pub lossy_utf8: bool,
    pub stages: Vec<UnixPipeStageSummary>,
}

#[derive(Debug, Clone, Serialize, PartialEq, Eq)]
pub struct UnixPipeStageSummary {
    pub utility_id: String,
    pub exit_code: Option<i32>,
    pub stdout_bytes: usize,
    pub stderr_bytes: usize,
    pub stderr_summary: String,
    pub stderr_truncated: bool,
}

#[derive(Debug, Clone)]
struct PreparedUnixPipeStage {
    utility_id: String,
    path: PathBuf,
    args: Vec<String>,
}

#[derive(Debug)]
struct BoundedBytes {
    bytes: Vec<u8>,
    total_bytes: usize,
    truncated: bool,
}

const UTILITY_CATALOG: &[LocalUtilityCatalogEntry] = &[
    LocalUtilityCatalogEntry {
        id: "jq",
        name: "jq",
        description: "JSON query and transform utility.",
        executable_candidates: &["jq"],
        pipe_allowed: true,
    },
    LocalUtilityCatalogEntry {
        id: "rg",
        name: "ripgrep",
        description: "Fast recursive text search.",
        executable_candidates: &["rg", "ripgrep"],
        pipe_allowed: true,
    },
    LocalUtilityCatalogEntry {
        id: "fd",
        name: "fd",
        description: "Fast filesystem search.",
        executable_candidates: &["fd", "fdfind"],
        pipe_allowed: true,
    },
    LocalUtilityCatalogEntry {
        id: "bat",
        name: "bat",
        description: "Syntax-highlighted file preview.",
        executable_candidates: &["bat", "batcat"],
        pipe_allowed: true,
    },
    LocalUtilityCatalogEntry {
        id: "pandoc",
        name: "Pandoc",
        description: "Document conversion utility.",
        executable_candidates: &["pandoc"],
        pipe_allowed: true,
    },
    LocalUtilityCatalogEntry {
        id: "sed",
        name: "sed",
        description: "Stream text editor.",
        executable_candidates: &["sed"],
        pipe_allowed: true,
    },
    LocalUtilityCatalogEntry {
        id: "awk",
        name: "awk",
        description: "Pattern scanning and processing.",
        executable_candidates: &["awk", "gawk", "mawk"],
        pipe_allowed: true,
    },
    LocalUtilityCatalogEntry {
        id: "sort",
        name: "sort",
        description: "Sort text lines.",
        executable_candidates: &["sort"],
        pipe_allowed: true,
    },
    LocalUtilityCatalogEntry {
        id: "uniq",
        name: "uniq",
        description: "Collapse adjacent duplicate lines.",
        executable_candidates: &["uniq"],
        pipe_allowed: true,
    },
    LocalUtilityCatalogEntry {
        id: "wc",
        name: "wc",
        description: "Count lines, words, and bytes.",
        executable_candidates: &["wc"],
        pipe_allowed: true,
    },
    LocalUtilityCatalogEntry {
        id: "head",
        name: "head",
        description: "Read the beginning of text streams.",
        executable_candidates: &["head"],
        pipe_allowed: true,
    },
    LocalUtilityCatalogEntry {
        id: "tail",
        name: "tail",
        description: "Read the end of text streams.",
        executable_candidates: &["tail"],
        pipe_allowed: true,
    },
];

pub fn utility_catalog() -> &'static [LocalUtilityCatalogEntry] {
    UTILITY_CATALOG
}

pub fn discover_utilities(paths: &AllbertPaths) -> Result<Vec<LocalUtilityDiscovery>, KernelError> {
    let manifest = load_manifest(paths)?;
    let enabled = manifest
        .utilities
        .into_iter()
        .map(|entry| (entry.id.clone(), entry))
        .collect::<BTreeMap<_, _>>();
    Ok(utility_catalog()
        .iter()
        .map(|entry| {
            let enabled_entry = enabled.get(entry.id);
            LocalUtilityDiscovery {
                id: entry.id.into(),
                name: entry.name.into(),
                description: entry.description.into(),
                executable_candidates: entry
                    .executable_candidates
                    .iter()
                    .map(|value| (*value).into())
                    .collect(),
                pipe_allowed: entry.pipe_allowed,
                installed_path: find_candidate(entry).map(|path| path.display().to_string()),
                enabled: enabled_entry.is_some(),
                status: enabled_entry.map(|entry| entry.status),
            }
        })
        .collect())
}

pub fn inspect_utility(
    paths: &AllbertPaths,
    id: &str,
) -> Result<(LocalUtilityDiscovery, Option<EnabledUtilityEntry>), KernelError> {
    let discovery = discover_utilities(paths)?
        .into_iter()
        .find(|entry| entry.id == id)
        .ok_or_else(|| KernelError::Request(format!("unknown utility id `{id}`")))?;
    let enabled = load_manifest(paths)?
        .utilities
        .into_iter()
        .find(|entry| entry.id == id);
    Ok((discovery, enabled))
}

pub fn list_enabled_utilities(
    paths: &AllbertPaths,
) -> Result<Vec<EnabledUtilityEntry>, KernelError> {
    Ok(load_manifest(paths)?.utilities)
}

pub fn enable_utility(
    paths: &AllbertPaths,
    security: &SecurityConfig,
    id: &str,
    requested_path: Option<&Path>,
) -> Result<UtilityEnableResult, KernelError> {
    let catalog = catalog_entry(id)?;
    let resolved = resolve_utility_path(catalog, requested_path)?;
    let canonical = resolved.canonicalize().map_err(|err| {
        KernelError::Request(format!("canonicalize {}: {err}", resolved.display()))
    })?;
    let exec_policy = utility_exec_policy(security, catalog, &canonical);
    if exec_policy.hard_denied {
        return Err(KernelError::Request(exec_policy.note));
    }
    let metadata = std::fs::metadata(&canonical)
        .map_err(|err| KernelError::Request(format!("metadata {}: {err}", canonical.display())))?;
    let now = chrono::Utc::now().to_rfc3339();
    let entry = EnabledUtilityEntry {
        id: catalog.id.into(),
        path: resolved.display().to_string(),
        path_canonical: canonical.display().to_string(),
        version: probe_version(&canonical),
        help_summary: catalog.description.into(),
        enabled_at: now.clone(),
        verified_at: now,
        status: if exec_policy.requires_approval {
            UtilityStatus::NeedsReview
        } else {
            UtilityStatus::Ok
        },
        size_bytes: metadata.len(),
        modified_at: modified_at(&metadata),
        pipe_allowed: catalog.pipe_allowed,
    };
    let mut manifest = load_manifest(paths)?;
    manifest
        .utilities
        .retain(|existing| existing.id != catalog.id);
    manifest.utilities.push(entry.clone());
    manifest
        .utilities
        .sort_by(|left, right| left.id.cmp(&right.id));
    save_manifest(paths, &manifest)?;
    Ok(UtilityEnableResult { entry, exec_policy })
}

pub fn disable_utility(paths: &AllbertPaths, id: &str) -> Result<bool, KernelError> {
    let mut manifest = load_manifest(paths)?;
    let before = manifest.utilities.len();
    manifest.utilities.retain(|entry| entry.id != id);
    let removed = manifest.utilities.len() != before;
    save_manifest(paths, &manifest)?;
    Ok(removed)
}

pub fn utility_doctor(
    paths: &AllbertPaths,
    security: &SecurityConfig,
) -> Result<UtilityDoctorReport, KernelError> {
    let mut manifest = load_manifest(paths)?;
    for entry in &mut manifest.utilities {
        refresh_entry_status(security, entry)?;
    }
    save_manifest(paths, &manifest)?;
    Ok(UtilityDoctorReport {
        manifest_path: paths.utilities_enabled.display().to_string(),
        entries: manifest.utilities,
    })
}

pub fn load_manifest(paths: &AllbertPaths) -> Result<UtilityManifest, KernelError> {
    if !paths.utilities_enabled.exists() {
        return Ok(UtilityManifest::default());
    }
    let raw = std::fs::read_to_string(&paths.utilities_enabled).map_err(|err| {
        KernelError::Io(std::io::Error::new(
            err.kind(),
            format!("read {}: {err}", paths.utilities_enabled.display()),
        ))
    })?;
    let manifest = toml::from_str::<UtilityManifest>(&raw).map_err(|err| {
        KernelError::Request(format!(
            "parse {}: {err}",
            paths.utilities_enabled.display()
        ))
    })?;
    if manifest.schema_version != UTILITY_MANIFEST_SCHEMA_VERSION {
        return Err(KernelError::Request(format!(
            "unsupported utility manifest schema {}; expected {}",
            manifest.schema_version, UTILITY_MANIFEST_SCHEMA_VERSION
        )));
    }
    Ok(manifest)
}

pub async fn run_unix_pipe(
    paths: &AllbertPaths,
    config: &Config,
    input: UnixPipeInput,
) -> Result<UnixPipeRunSummary, KernelError> {
    if !config.local_utilities.enabled {
        return Err(KernelError::Request(
            "local_utilities.enabled is false; enable local utilities before running unix_pipe"
                .into(),
        ));
    }

    let stdin = input.stdin.unwrap_or_default().into_bytes();
    if stdin.len() > config.local_utilities.unix_pipe_max_stdin_bytes {
        return Err(KernelError::Request(format!(
            "unix_pipe stdin is {} bytes; max is {}",
            stdin.len(),
            config.local_utilities.unix_pipe_max_stdin_bytes
        )));
    }
    let timeout_s = input
        .timeout_s
        .unwrap_or(config.local_utilities.unix_pipe_timeout_s);
    if timeout_s == 0 || timeout_s > config.local_utilities.unix_pipe_timeout_s {
        return Err(KernelError::Request(format!(
            "unix_pipe timeout_s must be between 1 and {}",
            config.local_utilities.unix_pipe_timeout_s
        )));
    }

    let cwd = match input
        .cwd
        .as_deref()
        .map(str::trim)
        .filter(|value| !value.is_empty())
    {
        Some(raw) => Some(
            security::sandbox::check(Path::new(raw), &config.security.fs_roots)
                .map_err(KernelError::Request)?,
        ),
        None => None,
    };
    let prepared = prepare_unix_pipe(paths, config, input.stages, cwd.clone())?;
    let timeout_stage_ids = prepared
        .iter()
        .map(|stage| stage.utility_id.clone())
        .collect::<Vec<_>>();
    match tokio::time::timeout(
        Duration::from_secs(timeout_s),
        execute_prepared_unix_pipe(
            prepared,
            stdin,
            cwd,
            config.local_utilities.unix_pipe_max_stdout_bytes,
            config.local_utilities.unix_pipe_max_stderr_bytes,
        ),
    )
    .await
    {
        Ok(result) => result,
        Err(_) => Ok(UnixPipeRunSummary {
            ok: false,
            timed_out: true,
            cap_violated: false,
            stdout: String::new(),
            stdout_bytes: 0,
            stdout_truncated: false,
            lossy_utf8: false,
            stages: timeout_stage_ids
                .into_iter()
                .map(|utility_id| UnixPipeStageSummary {
                    utility_id,
                    exit_code: None,
                    stdout_bytes: 0,
                    stderr_bytes: 0,
                    stderr_summary: "unix_pipe timed out; running children were killed".into(),
                    stderr_truncated: false,
                })
                .collect(),
        }),
    }
}

fn save_manifest(paths: &AllbertPaths, manifest: &UtilityManifest) -> Result<(), KernelError> {
    std::fs::create_dir_all(&paths.utilities).map_err(|err| {
        KernelError::Io(std::io::Error::new(
            err.kind(),
            format!("create {}: {err}", paths.utilities.display()),
        ))
    })?;
    let rendered = toml::to_string_pretty(manifest)
        .map_err(|err| KernelError::InitFailed(format!("serialize utilities manifest: {err}")))?;
    atomic_write(&paths.utilities_enabled, rendered.as_bytes()).map_err(|err| {
        KernelError::Io(std::io::Error::new(
            err.kind(),
            format!("write {}: {err}", paths.utilities_enabled.display()),
        ))
    })
}

fn prepare_unix_pipe(
    paths: &AllbertPaths,
    config: &Config,
    stages: Vec<UnixPipeStageInput>,
    cwd: Option<PathBuf>,
) -> Result<Vec<PreparedUnixPipeStage>, KernelError> {
    if stages.is_empty() {
        return Err(KernelError::Request(
            "unix_pipe requires at least one stage".into(),
        ));
    }
    if stages.len() > config.local_utilities.unix_pipe_max_stages {
        return Err(KernelError::Request(format!(
            "unix_pipe supports at most {} stages",
            config.local_utilities.unix_pipe_max_stages
        )));
    }

    let report = utility_doctor(paths, &config.security)?;
    let enabled = report
        .entries
        .into_iter()
        .map(|entry| (entry.id.clone(), entry))
        .collect::<BTreeMap<_, _>>();
    let mut prepared = Vec::with_capacity(stages.len());
    for stage in stages {
        let id = stage.utility_id.trim();
        if id.is_empty() {
            return Err(KernelError::Request(
                "unix_pipe stage utility_id must not be empty".into(),
            ));
        }
        let catalog = catalog_entry(id)?;
        if !catalog.pipe_allowed {
            return Err(KernelError::Request(format!(
                "utility {id} is not allowed for unix_pipe"
            )));
        }
        let entry = enabled.get(id).ok_or_else(|| {
            KernelError::Request(format!(
                "utility {id} is not enabled; run `allbert-cli utilities enable {id}` first"
            ))
        })?;
        if entry.status != UtilityStatus::Ok {
            return Err(KernelError::Request(format!(
                "utility {id} status is {}; run `allbert-cli utilities doctor` and review before unix_pipe",
                entry.status.label()
            )));
        }
        if !entry.pipe_allowed {
            return Err(KernelError::Request(format!(
                "utility {id} manifest entry is not allowed for unix_pipe"
            )));
        }
        if stage.args.len() > config.local_utilities.unix_pipe_max_args_per_stage {
            return Err(KernelError::Request(format!(
                "unix_pipe stage {id} has {} args; max is {}",
                stage.args.len(),
                config.local_utilities.unix_pipe_max_args_per_stage
            )));
        }
        let argv_bytes = stage.args.iter().map(|arg| arg.len()).sum::<usize>();
        if argv_bytes > config.local_utilities.unix_pipe_max_argv_bytes {
            return Err(KernelError::Request(format!(
                "unix_pipe stage {id} argv is {argv_bytes} bytes; max is {}",
                config.local_utilities.unix_pipe_max_argv_bytes
            )));
        }
        for arg in &stage.args {
            validate_unix_pipe_arg(id, arg, &config.local_utilities)?;
        }
        let path = PathBuf::from(&entry.path_canonical);
        if !is_executable_file(&path) {
            return Err(KernelError::Request(format!(
                "utility {id} is no longer executable at {}",
                path.display()
            )));
        }
        preflight_unix_pipe_exec(&config.security, catalog, &path, &stage.args, cwd.clone())?;
        prepared.push(PreparedUnixPipeStage {
            utility_id: id.into(),
            path,
            args: stage.args,
        });
    }
    Ok(prepared)
}

fn validate_unix_pipe_arg(
    utility_id: &str,
    arg: &str,
    limits: &LocalUtilitiesConfig,
) -> Result<(), KernelError> {
    if arg.contains('\0') {
        return Err(KernelError::Request(format!(
            "unix_pipe arg for {utility_id} contains a NUL byte"
        )));
    }
    if arg.len() > limits.unix_pipe_max_arg_bytes {
        return Err(KernelError::Request(format!(
            "unix_pipe arg for {utility_id} is {} bytes; max is {}",
            arg.len(),
            limits.unix_pipe_max_arg_bytes
        )));
    }
    if arg
        .chars()
        .any(|ch| matches!(ch, '|' | '>' | '<' | '*' | '?'))
    {
        return Err(KernelError::Request(format!(
            "unix_pipe arg for {utility_id} contains shell operators, redirection, or glob characters"
        )));
    }
    Ok(())
}

fn preflight_unix_pipe_exec(
    security: &SecurityConfig,
    catalog: &LocalUtilityCatalogEntry,
    path: &Path,
    args: &[String],
    cwd: Option<PathBuf>,
) -> Result<(), KernelError> {
    let utility_policy = utility_exec_policy(security, catalog, path);
    if utility_policy.hard_denied {
        return Err(KernelError::Request(utility_policy.note));
    }

    let normalized = NormalizedExec {
        program: path.display().to_string(),
        args: args.to_vec(),
        cwd,
    };
    match security::exec_policy(&normalized, security, &HashSet::new()) {
        PolicyDecision::Deny(message) => Err(KernelError::Request(message)),
        PolicyDecision::AutoAllow => Ok(()),
        PolicyDecision::NeedsConfirm(_) if utility_policy.auto_allowed => Ok(()),
        PolicyDecision::NeedsConfirm(_) => Err(KernelError::Request(format!(
            "utility {} still requires exec approval; add its id, filename, or canonical path to security.exec_allow before unix_pipe",
            catalog.id
        ))),
    }
}

async fn execute_prepared_unix_pipe(
    stages: Vec<PreparedUnixPipeStage>,
    stdin: Vec<u8>,
    cwd: Option<PathBuf>,
    stdout_cap: usize,
    stderr_cap: usize,
) -> Result<UnixPipeRunSummary, KernelError> {
    let stage_count = stages.len();
    let mut children = Vec::with_capacity(stage_count);
    let mut stdins = Vec::with_capacity(stage_count);
    let mut stdouts = Vec::with_capacity(stage_count);
    let mut stderr_handles = Vec::with_capacity(stage_count);

    for stage in &stages {
        let mut command = Command::new(&stage.path);
        command.args(&stage.args);
        if let Some(cwd) = &cwd {
            command.current_dir(cwd);
        }
        command.stdin(Stdio::piped());
        command.stdout(Stdio::piped());
        command.stderr(Stdio::piped());
        command.kill_on_drop(true);
        let mut child = command.spawn().map_err(|err| {
            KernelError::Request(format!("spawn unix_pipe stage {}: {err}", stage.utility_id))
        })?;
        let stdin = child.stdin.take().ok_or_else(|| {
            KernelError::Request(format!(
                "open stdin for unix_pipe stage {}",
                stage.utility_id
            ))
        })?;
        let stdout = child.stdout.take().ok_or_else(|| {
            KernelError::Request(format!(
                "open stdout for unix_pipe stage {}",
                stage.utility_id
            ))
        })?;
        let stderr = child.stderr.take().ok_or_else(|| {
            KernelError::Request(format!(
                "open stderr for unix_pipe stage {}",
                stage.utility_id
            ))
        })?;
        stderr_handles.push(tokio::spawn(read_bounded(stderr, stderr_cap)));
        stdins.push(Some(stdin));
        stdouts.push(Some(stdout));
        children.push(child);
    }

    let mut copy_handles = Vec::with_capacity(stage_count.saturating_sub(1));
    let first_stdin = stdins
        .get_mut(0)
        .and_then(Option::take)
        .ok_or_else(|| KernelError::Request("open first unix_pipe stdin".into()))?;
    let stdin_handle = tokio::spawn(write_pipe_stdin(first_stdin, stdin));
    for idx in 0..stage_count.saturating_sub(1) {
        let stdout = stdouts
            .get_mut(idx)
            .and_then(Option::take)
            .ok_or_else(|| KernelError::Request("open intermediate unix_pipe stdout".into()))?;
        let stdin = stdins
            .get_mut(idx + 1)
            .and_then(Option::take)
            .ok_or_else(|| KernelError::Request("open intermediate unix_pipe stdin".into()))?;
        copy_handles.push(tokio::spawn(copy_bounded(stdout, stdin, stdout_cap)));
    }
    let final_stdout = stdouts
        .get_mut(stage_count - 1)
        .and_then(Option::take)
        .ok_or_else(|| KernelError::Request("open final unix_pipe stdout".into()))?;
    let final_stdout_handle = tokio::spawn(read_bounded(final_stdout, stdout_cap));

    let mut exit_codes = Vec::with_capacity(stage_count);
    for (stage, child) in stages.iter().zip(children.iter_mut()) {
        let status = child.wait().await.map_err(|err| {
            KernelError::Request(format!(
                "wait for unix_pipe stage {}: {err}",
                stage.utility_id
            ))
        })?;
        exit_codes.push(status.code());
    }

    let _ = join_bounded_task(stdin_handle).await?;
    let mut stdout_counts = vec![0usize; stage_count];
    let mut cap_violated = false;
    for (idx, handle) in copy_handles.into_iter().enumerate() {
        let outcome = join_bounded_task(handle).await?;
        stdout_counts[idx] = outcome.total_bytes;
        cap_violated |= outcome.truncated;
    }
    let final_stdout = join_bounded_task(final_stdout_handle).await?;
    stdout_counts[stage_count - 1] = final_stdout.total_bytes;
    cap_violated |= final_stdout.truncated;

    let mut stderr_results = Vec::with_capacity(stage_count);
    for handle in stderr_handles {
        let outcome = join_bounded_task(handle).await?;
        cap_violated |= outcome.truncated;
        stderr_results.push(outcome);
    }

    let mut summaries = Vec::with_capacity(stage_count);
    for idx in 0..stage_count {
        let stderr = &stderr_results[idx];
        let (stderr_summary, _) = render_lossy_output(&stderr.bytes, stderr.truncated);
        summaries.push(UnixPipeStageSummary {
            utility_id: stages[idx].utility_id.clone(),
            exit_code: exit_codes[idx],
            stdout_bytes: stdout_counts[idx],
            stderr_bytes: stderr.total_bytes,
            stderr_summary,
            stderr_truncated: stderr.truncated,
        });
    }
    let (stdout, lossy_utf8) = render_lossy_output(&final_stdout.bytes, final_stdout.truncated);
    let ok = !cap_violated && exit_codes.iter().all(|code| *code == Some(0));
    Ok(UnixPipeRunSummary {
        ok,
        timed_out: false,
        cap_violated,
        stdout,
        stdout_bytes: final_stdout.total_bytes,
        stdout_truncated: final_stdout.truncated,
        lossy_utf8,
        stages: summaries,
    })
}

async fn join_bounded_task(
    handle: tokio::task::JoinHandle<std::io::Result<BoundedBytes>>,
) -> Result<BoundedBytes, KernelError> {
    handle
        .await
        .map_err(|err| KernelError::Request(format!("unix_pipe io task failed: {err}")))?
        .map_err(|err| KernelError::Request(format!("unix_pipe io failed: {err}")))
}

async fn write_pipe_stdin<W>(mut writer: W, input: Vec<u8>) -> std::io::Result<BoundedBytes>
where
    W: AsyncWrite + Unpin,
{
    match writer.write_all(&input).await {
        Ok(()) => {}
        Err(err) if err.kind() == ErrorKind::BrokenPipe => {}
        Err(err) => return Err(err),
    }
    let _ = writer.shutdown().await;
    Ok(BoundedBytes {
        bytes: Vec::new(),
        total_bytes: input.len(),
        truncated: false,
    })
}

async fn copy_bounded<R, W>(
    mut reader: R,
    mut writer: W,
    cap: usize,
) -> std::io::Result<BoundedBytes>
where
    R: AsyncRead + Unpin,
    W: AsyncWrite + Unpin,
{
    let mut total = 0usize;
    let mut written = 0usize;
    let mut truncated = false;
    let mut buffer = vec![0_u8; 8192];
    loop {
        let read = reader.read(&mut buffer).await?;
        if read == 0 {
            break;
        }
        total = total.saturating_add(read);
        let remaining = cap.saturating_sub(written);
        if remaining == 0 {
            truncated = true;
            continue;
        }
        let to_write = read.min(remaining);
        if let Err(err) = writer.write_all(&buffer[..to_write]).await {
            if err.kind() == ErrorKind::BrokenPipe {
                truncated = true;
                break;
            }
            return Err(err);
        }
        written = written.saturating_add(to_write);
        if read > to_write {
            truncated = true;
        }
    }
    let _ = writer.shutdown().await;
    Ok(BoundedBytes {
        bytes: Vec::new(),
        total_bytes: total,
        truncated,
    })
}

async fn read_bounded<R>(mut reader: R, cap: usize) -> std::io::Result<BoundedBytes>
where
    R: AsyncRead + Unpin,
{
    let mut bytes = Vec::new();
    let mut total = 0usize;
    let mut truncated = false;
    let mut buffer = vec![0_u8; 8192];
    loop {
        let read = reader.read(&mut buffer).await?;
        if read == 0 {
            break;
        }
        total = total.saturating_add(read);
        let remaining = cap.saturating_sub(bytes.len());
        if remaining == 0 {
            truncated = true;
            continue;
        }
        let to_store = read.min(remaining);
        bytes.extend_from_slice(&buffer[..to_store]);
        if read > to_store {
            truncated = true;
        }
    }
    Ok(BoundedBytes {
        bytes,
        total_bytes: total,
        truncated,
    })
}

fn render_lossy_output(bytes: &[u8], truncated: bool) -> (String, bool) {
    let lossy = std::str::from_utf8(bytes).is_err();
    let mut rendered = String::from_utf8_lossy(bytes).to_string();
    if truncated {
        rendered.push_str("\n[unix_pipe warning: output truncated]");
    }
    if lossy {
        rendered.push_str("\n[unix_pipe warning: invalid utf-8 rendered lossily]");
    }
    (rendered, lossy)
}

fn catalog_entry(id: &str) -> Result<&'static LocalUtilityCatalogEntry, KernelError> {
    utility_catalog()
        .iter()
        .find(|entry| entry.id == id)
        .ok_or_else(|| KernelError::Request(format!("unknown utility id `{id}`")))
}

fn resolve_utility_path(
    catalog: &LocalUtilityCatalogEntry,
    requested_path: Option<&Path>,
) -> Result<PathBuf, KernelError> {
    if let Some(path) = requested_path {
        if !path.is_absolute() {
            return Err(KernelError::Request(
                "utilities enable --path must be absolute".into(),
            ));
        }
        validate_candidate_name(catalog, path)?;
        if !is_executable_file(path) {
            return Err(KernelError::Request(format!(
                "utility path is not an executable file: {}",
                path.display()
            )));
        }
        return Ok(path.to_path_buf());
    }
    find_candidate(catalog).ok_or_else(|| {
        KernelError::Request(format!(
            "no executable candidate found for {}; pass --path",
            catalog.id
        ))
    })
}

fn validate_candidate_name(
    catalog: &LocalUtilityCatalogEntry,
    path: &Path,
) -> Result<(), KernelError> {
    let Some(name) = path.file_name().and_then(|value| value.to_str()) else {
        return Err(KernelError::Request(format!(
            "utility path has no filename: {}",
            path.display()
        )));
    };
    if catalog
        .executable_candidates
        .iter()
        .any(|candidate| candidate == &name)
    {
        Ok(())
    } else {
        Err(KernelError::Request(format!(
            "{} does not match utility {} candidates: {}",
            path.display(),
            catalog.id,
            catalog.executable_candidates.join(", ")
        )))
    }
}

fn find_candidate(catalog: &LocalUtilityCatalogEntry) -> Option<PathBuf> {
    let path = std::env::var_os("PATH")?;
    for dir in std::env::split_paths(&path) {
        for candidate in catalog.executable_candidates {
            let path = dir.join(candidate);
            if is_executable_file(&path) {
                return Some(path);
            }
        }
    }
    None
}

fn is_executable_file(path: &Path) -> bool {
    if !path.is_file() {
        return false;
    }
    #[cfg(unix)]
    {
        use std::os::unix::fs::PermissionsExt;
        std::fs::metadata(path)
            .map(|metadata| metadata.permissions().mode() & 0o111 != 0)
            .unwrap_or(false)
    }
    #[cfg(not(unix))]
    {
        true
    }
}

fn utility_exec_policy(
    security: &SecurityConfig,
    catalog: &LocalUtilityCatalogEntry,
    canonical: &Path,
) -> UtilityExecPolicy {
    let file_name = canonical
        .file_name()
        .and_then(|value| value.to_str())
        .unwrap_or(catalog.id);
    let canonical_text = canonical.display().to_string();
    if security
        .exec_deny
        .iter()
        .any(|value| value == catalog.id || value == file_name || value == &canonical_text)
    {
        return UtilityExecPolicy {
            hard_denied: true,
            auto_allowed: false,
            requires_approval: false,
            note: format!("utility {} is denied by security.exec_deny", catalog.id),
        };
    }
    let auto_allowed = security.auto_confirm
        || security
            .exec_allow
            .iter()
            .any(|value| value == catalog.id || value == file_name || value == &canonical_text);
    UtilityExecPolicy {
        hard_denied: false,
        auto_allowed,
        requires_approval: !auto_allowed,
        note: if auto_allowed {
            "exec policy auto-allows this utility".into()
        } else {
            "exec policy will still require approval; utilities enable did not edit security.exec_allow".into()
        },
    }
}

fn refresh_entry_status(
    security: &SecurityConfig,
    entry: &mut EnabledUtilityEntry,
) -> Result<(), KernelError> {
    let path = PathBuf::from(&entry.path_canonical);
    let catalog = catalog_entry(&entry.id)?;
    if !path.exists() {
        entry.status = UtilityStatus::Missing;
        entry.verified_at = chrono::Utc::now().to_rfc3339();
        return Ok(());
    }
    let canonical = path
        .canonicalize()
        .map_err(|err| KernelError::Request(format!("canonicalize {}: {err}", path.display())))?;
    let policy = utility_exec_policy(security, catalog, &canonical);
    entry.pipe_allowed = catalog.pipe_allowed;
    if policy.hard_denied {
        entry.status = UtilityStatus::Denied;
        entry.verified_at = chrono::Utc::now().to_rfc3339();
        return Ok(());
    }
    let metadata = std::fs::metadata(&canonical)
        .map_err(|err| KernelError::Request(format!("metadata {}: {err}", canonical.display())))?;
    let modified = modified_at(&metadata);
    let changed = canonical.display().to_string() != entry.path_canonical
        || metadata.len() != entry.size_bytes
        || modified != entry.modified_at;
    entry.status = if changed || policy.requires_approval {
        UtilityStatus::NeedsReview
    } else {
        UtilityStatus::Ok
    };
    entry.verified_at = chrono::Utc::now().to_rfc3339();
    Ok(())
}

fn probe_version(path: &Path) -> String {
    let output = std::process::Command::new(path).arg("--version").output();
    match output {
        Ok(output) if output.status.success() => String::from_utf8_lossy(&output.stdout)
            .lines()
            .next()
            .unwrap_or("")
            .chars()
            .take(160)
            .collect(),
        _ => String::new(),
    }
}

fn modified_at(metadata: &std::fs::Metadata) -> String {
    metadata
        .modified()
        .ok()
        .and_then(|value| value.duration_since(SystemTime::UNIX_EPOCH).ok())
        .map(|duration| duration.as_secs().to_string())
        .unwrap_or_default()
}

#[cfg(test)]
mod tests {
    use super::*;
    #[cfg(unix)]
    use std::os::unix::fs::PermissionsExt;

    fn make_executable(path: &Path) {
        #[cfg(unix)]
        {
            let mut permissions = std::fs::metadata(path).expect("metadata").permissions();
            permissions.set_mode(0o755);
            std::fs::set_permissions(path, permissions).expect("permissions");
        }
    }

    #[test]
    fn enable_disable_and_doctor_round_trip_manifest() {
        let temp = tempfile::tempdir().expect("tempdir");
        let paths = AllbertPaths::under(temp.path().join(".allbert"));
        paths.ensure().expect("paths");
        let bin = temp.path().join("rg");
        std::fs::write(&bin, "#!/bin/sh\necho rg 1.0\n").expect("binary");
        make_executable(&bin);
        let security = SecurityConfig {
            exec_allow: vec![bin.canonicalize().unwrap().display().to_string()],
            ..SecurityConfig::default()
        };
        let result = enable_utility(&paths, &security, "rg", Some(&bin)).expect("enable");
        assert_eq!(result.entry.status, UtilityStatus::Ok);
        assert!(paths.utilities_enabled.exists());
        let report = utility_doctor(&paths, &security).expect("doctor");
        assert_eq!(report.entries.len(), 1);
        assert_eq!(report.entries[0].status, UtilityStatus::Ok);
        assert!(disable_utility(&paths, "rg").expect("disable"));
        assert!(list_enabled_utilities(&paths).expect("list").is_empty());
    }

    #[test]
    fn enable_reports_approval_required_without_editing_exec_policy() {
        let temp = tempfile::tempdir().expect("tempdir");
        let paths = AllbertPaths::under(temp.path().join(".allbert"));
        paths.ensure().expect("paths");
        let bin = temp.path().join("jq");
        std::fs::write(&bin, "not actually executed").expect("binary");
        make_executable(&bin);
        let security = SecurityConfig::default();
        let result = enable_utility(&paths, &security, "jq", Some(&bin)).expect("enable");
        assert!(result.exec_policy.requires_approval);
        assert_eq!(result.entry.status, UtilityStatus::NeedsReview);
    }

    #[test]
    fn denied_utility_refuses_enablement() {
        let temp = tempfile::tempdir().expect("tempdir");
        let paths = AllbertPaths::under(temp.path().join(".allbert"));
        paths.ensure().expect("paths");
        let bin = temp.path().join("sed");
        std::fs::write(&bin, "not actually executed").expect("binary");
        make_executable(&bin);
        let security = SecurityConfig {
            exec_deny: vec!["sed".into()],
            ..SecurityConfig::default()
        };
        let err = enable_utility(&paths, &security, "sed", Some(&bin)).unwrap_err();
        assert!(err.to_string().contains("exec_deny"));
    }

    #[tokio::test]
    async fn unix_pipe_runs_enabled_direct_spawn_stage() {
        let temp = tempfile::tempdir().expect("tempdir");
        let paths = AllbertPaths::under(temp.path().join(".allbert"));
        paths.ensure().expect("paths");
        let bin = temp.path().join("sed");
        std::fs::write(
            &bin,
            "#!/bin/sh\nif [ \"$1\" = \"--version\" ]; then echo sed-test 1.0; exit 0; fi\ncat\n",
        )
        .expect("binary");
        make_executable(&bin);
        let canonical = bin.canonicalize().expect("canonical");
        let mut config = Config::default_template();
        config.security.exec_allow = vec![canonical.display().to_string()];
        config.security.fs_roots = vec![temp.path().to_path_buf()];
        enable_utility(&paths, &config.security, "sed", Some(&bin)).expect("enable");

        let result = run_unix_pipe(
            &paths,
            &config,
            UnixPipeInput {
                stages: vec![UnixPipeStageInput {
                    utility_id: "sed".into(),
                    args: Vec::new(),
                }],
                stdin: Some("hello\n".into()),
                cwd: Some(temp.path().display().to_string()),
                timeout_s: Some(2),
            },
        )
        .await
        .expect("run");

        assert!(result.ok);
        assert_eq!(result.stdout, "hello\n");
        assert_eq!(result.stages[0].exit_code, Some(0));
        assert_eq!(result.stages[0].stdout_bytes, 6);
    }

    #[tokio::test]
    async fn unix_pipe_refuses_needs_review_utility() {
        let temp = tempfile::tempdir().expect("tempdir");
        let paths = AllbertPaths::under(temp.path().join(".allbert"));
        paths.ensure().expect("paths");
        let bin = temp.path().join("jq");
        std::fs::write(&bin, "#!/bin/sh\ncat\n").expect("binary");
        make_executable(&bin);
        let mut config = Config::default_template();
        config.security.fs_roots = vec![temp.path().to_path_buf()];
        enable_utility(&paths, &config.security, "jq", Some(&bin)).expect("enable");

        let err = run_unix_pipe(
            &paths,
            &config,
            UnixPipeInput {
                stages: vec![UnixPipeStageInput {
                    utility_id: "jq".into(),
                    args: Vec::new(),
                }],
                stdin: Some("{}".into()),
                cwd: Some(temp.path().display().to_string()),
                timeout_s: Some(2),
            },
        )
        .await
        .unwrap_err();

        assert!(err.to_string().contains("needs-review"));
    }
}
