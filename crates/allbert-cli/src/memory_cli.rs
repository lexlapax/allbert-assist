use allbert_kernel::{memory, AllbertPaths, Config};
use anyhow::Result;

pub fn status(paths: &AllbertPaths, config: &Config) -> Result<String> {
    let snapshot = memory::memory_status(paths, &config.memory, config.setup.version)?;
    let staged = if snapshot.staged_counts.is_empty() {
        "none".to_string()
    } else {
        snapshot
            .staged_counts
            .iter()
            .map(|(kind, count)| format!("{kind}={count}"))
            .collect::<Vec<_>>()
            .join(", ")
    };
    let age = snapshot
        .index_age_seconds
        .map(|seconds| format!("{seconds}s"))
        .unwrap_or_else(|| "unknown".into());
    Ok(format!(
        "setup version:        {}\nretriever schema:     {}\nindexed docs:         {}\nstaged entries:       {}\nrejected entries:     {}\nexpired pending:      {}\nindex age:            {}\nlast rebuild reason:  {}\nlast rebuild elapsed: {} ms",
        snapshot.setup_version,
        snapshot.schema_version,
        snapshot.manifest_docs,
        staged,
        snapshot.rejected_count,
        snapshot.expired_pending_count,
        age,
        snapshot
            .last_rebuild_reason
            .unwrap_or_else(|| "unknown".into()),
        snapshot.last_rebuild_elapsed_ms.unwrap_or_default()
    ))
}

pub fn rebuild_index(paths: &AllbertPaths, config: &Config, force: bool) -> Result<String> {
    let report = memory::rebuild_memory_index(paths, &config.memory, force)?;
    Ok(format!(
        "rebuilt memory index\nreason: {}\ndocs indexed: {}\nelapsed: {} ms",
        report.reason, report.docs_indexed, report.elapsed_ms
    ))
}
