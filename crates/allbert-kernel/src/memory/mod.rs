mod curated;

pub use curated::{
    bootstrap_curated_memory, forget_memory, get_staged_memory, list_staged_memory, memory_status,
    preview_forget_memory, preview_promote_staged_memory, promote_staged_memory,
    rebuild_memory_index, reject_staged_memory, search_memory, stage_memory, ForgetTarget,
    MemoryBootstrapReport, MemoryForgetPreview, MemoryIndexMeta, MemoryManifest,
    MemoryManifestEntry, MemoryPromotionPreview, MemoryStatusSnapshot, MemoryTier,
    RebuildIndexReport, SearchMemoryHit, SearchMemoryInput, StageMemoryInput, StageMemoryRequest,
    StagedMemoryKind, StagedMemoryRecord,
};

use std::path::{Component, Path, PathBuf};

use serde::Deserialize;

use crate::error::ToolError;
use crate::paths::AllbertPaths;

#[derive(Debug, Clone, Deserialize)]
pub struct ReadMemoryInput {
    pub path: String,
}

#[derive(Debug, Clone, Deserialize)]
pub struct WriteMemoryInput {
    #[serde(default)]
    pub path: Option<String>,
    pub content: String,
    pub mode: WriteMemoryMode,
    #[serde(default)]
    pub summary: Option<String>,
}

#[derive(Debug, Clone, Deserialize, PartialEq, Eq)]
#[serde(rename_all = "lowercase")]
pub enum WriteMemoryMode {
    Write,
    Append,
    Daily,
}

pub fn ensure_memory_files(paths: &AllbertPaths) -> Result<(), ToolError> {
    if !paths.memory_index.exists() {
        std::fs::write(&paths.memory_index, "# MEMORY\n\n").map_err(|err| {
            ToolError::Dispatch(format!("write {}: {err}", paths.memory_index.display()))
        })?;
    }
    Ok(())
}

pub fn read_memory(paths: &AllbertPaths, input: ReadMemoryInput) -> Result<String, ToolError> {
    let path = resolve_memory_path(paths, &input.path)?;
    std::fs::read_to_string(&path)
        .map_err(|err| ToolError::Dispatch(format!("read {}: {err}", path.display())))
}

pub fn write_memory(paths: &AllbertPaths, input: WriteMemoryInput) -> Result<String, ToolError> {
    ensure_memory_files(paths)?;
    match input.mode {
        WriteMemoryMode::Daily => write_daily(paths, &input.content),
        WriteMemoryMode::Write | WriteMemoryMode::Append => {
            let rel = input.path.ok_or_else(|| {
                ToolError::Dispatch("write_memory.path is required for write/append".into())
            })?;
            let target = resolve_memory_path(paths, &rel)?;
            if let Some(parent) = target.parent() {
                std::fs::create_dir_all(parent).map_err(|err| {
                    ToolError::Dispatch(format!("create {}: {err}", parent.display()))
                })?;
            }

            let existed = target.exists();
            match input.mode {
                WriteMemoryMode::Write => std::fs::write(&target, input.content.as_bytes()),
                WriteMemoryMode::Append => {
                    let mut current = if existed {
                        std::fs::read_to_string(&target).unwrap_or_default()
                    } else {
                        String::new()
                    };
                    if !current.is_empty() && !current.ends_with('\n') {
                        current.push('\n');
                    }
                    current.push_str(&input.content);
                    std::fs::write(&target, current.as_bytes())
                }
                WriteMemoryMode::Daily => unreachable!(),
            }
            .map_err(|err| ToolError::Dispatch(format!("write {}: {err}", target.display())))?;

            update_memory_index(paths, &rel, &target, input.summary, existed)?;
            Ok(format!("wrote memory note {}", rel))
        }
    }
}

pub fn load_prompt_memory(
    paths: &AllbertPaths,
    max_bytes: usize,
) -> Result<Vec<String>, ToolError> {
    ensure_memory_files(paths)?;
    let mut remaining = max_bytes;
    let mut sections = Vec::new();

    let index = std::fs::read_to_string(&paths.memory_index).map_err(|err| {
        ToolError::Dispatch(format!("read {}: {err}", paths.memory_index.display()))
    })?;
    let head = first_n_lines(&index, 40);
    if !head.trim().is_empty() {
        let label = "## MEMORY.md\n";
        if remaining > label.len() {
            let content = truncate_to_bytes(head.trim(), remaining - label.len());
            if !content.trim().is_empty() {
                remaining -= label.len() + content.as_bytes().len();
                sections.push(format!("{label}{content}"));
            }
        }
    }

    let daily_path = today_daily_path(paths)?;
    if daily_path.exists() && remaining > "## Today's daily note\n".len() {
        let daily = std::fs::read_to_string(&daily_path)
            .map_err(|err| ToolError::Dispatch(format!("read {}: {err}", daily_path.display())))?;
        let label = "## Today's daily note\n";
        let content = truncate_to_bytes(daily.trim(), remaining - label.len());
        if !content.trim().is_empty() {
            sections.push(format!("{label}{content}"));
        }
    }

    Ok(sections)
}

fn write_daily(paths: &AllbertPaths, content: &str) -> Result<String, ToolError> {
    let path = today_daily_path(paths)?;
    if let Some(parent) = path.parent() {
        std::fs::create_dir_all(parent)
            .map_err(|err| ToolError::Dispatch(format!("create {}: {err}", parent.display())))?;
    }

    let mut current = if path.exists() {
        std::fs::read_to_string(&path).unwrap_or_default()
    } else {
        format!("# {}\n\n", today_date_string()?)
    };
    if !current.ends_with('\n') {
        current.push('\n');
    }
    current.push_str(content);
    current.push('\n');
    std::fs::write(&path, current)
        .map_err(|err| ToolError::Dispatch(format!("write {}: {err}", path.display())))?;
    Ok(format!(
        "appended daily memory {}",
        path.strip_prefix(&paths.memory)
            .unwrap_or(path.as_path())
            .display()
    ))
}

fn update_memory_index(
    paths: &AllbertPaths,
    rel_path: &str,
    target: &Path,
    summary: Option<String>,
    existed: bool,
) -> Result<(), ToolError> {
    let mut index = std::fs::read_to_string(&paths.memory_index).map_err(|err| {
        ToolError::Dispatch(format!("read {}: {err}", paths.memory_index.display()))
    })?;
    let marker = format!("- [[{}]]", rel_path.replace('\\', "/"));
    let resolved_summary = summary
        .filter(|value| !value.trim().is_empty())
        .map(|value| value.trim().to_string())
        .or_else(|| {
            if existed {
                None
            } else {
                Some(derive_summary(target))
            }
        });

    let mut lines = if index.is_empty() {
        vec!["# MEMORY".to_string(), String::new()]
    } else {
        index
            .lines()
            .map(|line| line.to_string())
            .collect::<Vec<_>>()
    };

    if let Some(position) = lines.iter().position(|line| line.starts_with(&marker)) {
        if let Some(summary) = resolved_summary {
            lines[position] = format!("{marker} — {summary}");
        }
    } else {
        let summary = resolved_summary.unwrap_or_else(|| derive_summary(target));
        if !lines.last().is_some_and(|line| line.is_empty()) {
            lines.push(String::new());
        }
        lines.push(format!("{marker} — {summary}"));
    }

    index = lines.join("\n");
    if !index.ends_with('\n') {
        index.push('\n');
    }
    std::fs::write(&paths.memory_index, index).map_err(|err| {
        ToolError::Dispatch(format!("write {}: {err}", paths.memory_index.display()))
    })?;
    Ok(())
}

fn derive_summary(path: &Path) -> String {
    let content = std::fs::read_to_string(path).unwrap_or_default();
    for line in content.lines() {
        let trimmed = line.trim();
        if trimmed.is_empty() {
            continue;
        }
        if let Some(rest) = trimmed.strip_prefix('#') {
            return truncate_to_bytes(rest.trim(), 80);
        }
        return truncate_to_bytes(trimmed, 80);
    }
    "Untitled note".into()
}

fn resolve_memory_path(paths: &AllbertPaths, rel: &str) -> Result<PathBuf, ToolError> {
    let rel_path = Path::new(rel);
    if rel_path.is_absolute() {
        return Err(ToolError::Dispatch(
            "memory paths must be relative to ~/.allbert/memory".into(),
        ));
    }
    if rel_path.components().any(|component| {
        matches!(
            component,
            Component::ParentDir | Component::RootDir | Component::Prefix(_)
        )
    }) {
        return Err(ToolError::Dispatch(
            "memory path escapes memory root".into(),
        ));
    }
    Ok(paths.memory.join(rel_path))
}

fn today_daily_path(paths: &AllbertPaths) -> Result<PathBuf, ToolError> {
    Ok(paths
        .memory_daily
        .join(format!("{}.md", today_date_string()?)))
}

fn today_date_string() -> Result<String, ToolError> {
    let now = time::OffsetDateTime::now_local()
        .or_else(|_| Ok(time::OffsetDateTime::now_utc()))
        .map_err(|err: time::error::IndeterminateOffset| ToolError::Dispatch(err.to_string()))?;
    let format = time::macros::format_description!("[year]-[month]-[day]");
    now.format(&format)
        .map_err(|err| ToolError::Dispatch(err.to_string()))
}

fn first_n_lines(input: &str, n: usize) -> String {
    input.lines().take(n).collect::<Vec<_>>().join("\n")
}

fn truncate_to_bytes(input: &str, max_bytes: usize) -> String {
    if input.as_bytes().len() <= max_bytes {
        return input.to_string();
    }
    let mut end = max_bytes;
    while end > 0 && !input.is_char_boundary(end) {
        end -= 1;
    }
    input[..end].to_string()
}
