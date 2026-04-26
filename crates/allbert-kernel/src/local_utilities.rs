use std::collections::BTreeMap;
use std::path::{Path, PathBuf};
use std::time::SystemTime;

use serde::{Deserialize, Serialize};

use crate::atomic_write;
use crate::config::SecurityConfig;
use crate::error::KernelError;
use crate::paths::AllbertPaths;

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
}
