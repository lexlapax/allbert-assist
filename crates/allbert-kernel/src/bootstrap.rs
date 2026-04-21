use crate::config::LimitsConfig;
use crate::error::KernelError;
use crate::paths::AllbertPaths;

pub(crate) fn snapshot_prompt_sections(
    paths: &AllbertPaths,
    limits: &LimitsConfig,
) -> Result<Vec<String>, KernelError> {
    let mut remaining = limits.max_prompt_bootstrap_bytes;
    let mut sections = Vec::new();

    for (label, path) in paths.bootstrap_files() {
        if !path.exists() {
            continue;
        }

        let raw = std::fs::read_to_string(path).map_err(|e| {
            KernelError::InitFailed(format!("read bootstrap file {}: {e}", path.display()))
        })?;
        let trimmed = raw.trim();
        if trimmed.is_empty() {
            continue;
        }

        let prefix = format!("## {label}\n");
        let prefix_bytes = prefix.len();
        if remaining <= prefix_bytes {
            break;
        }

        let per_file = truncate_to_bytes(trimmed, limits.max_bootstrap_file_bytes);
        let available_content = remaining - prefix_bytes;
        let content = truncate_to_bytes(&per_file, available_content);
        if content.trim().is_empty() {
            break;
        }

        remaining -= prefix_bytes + content.len();
        sections.push(format!("{prefix}{content}"));
    }

    Ok(sections)
}

fn truncate_to_bytes(input: &str, max_bytes: usize) -> String {
    if input.len() <= max_bytes {
        return input.to_owned();
    }

    let mut end = max_bytes;
    while end > 0 && !input.is_char_boundary(end) {
        end -= 1;
    }
    input[..end].to_owned()
}
