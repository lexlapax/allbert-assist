use std::fs::{self, File, OpenOptions};
use std::io::{BufRead, BufReader, Write};
use std::path::{Path, PathBuf};

use allbert_proto::{ActiveAdapter, AdapterManifest, AdaptersHistoryEntry};
use chrono::Utc;
use fs2::FileExt;

use crate::adapters::manifest::{read_adapter_manifest, write_adapter_manifest, MANIFEST_FILE};
use crate::{atomic_write, AllbertPaths, KernelError};

#[derive(Debug, Clone)]
pub struct AdapterStore {
    paths: AllbertPaths,
}

impl AdapterStore {
    pub fn new(paths: AllbertPaths) -> Self {
        Self { paths }
    }

    pub fn paths(&self) -> &AllbertPaths {
        &self.paths
    }

    pub fn install_from_run(&self, run_dir: &Path) -> Result<AdapterManifest, KernelError> {
        self.paths.ensure()?;
        let manifest_path = run_dir.join(MANIFEST_FILE);
        let manifest = read_adapter_manifest(&manifest_path)?;
        validate_adapter_id(&manifest.adapter_id)?;
        let destination = self.installed_dir(&manifest.adapter_id)?;
        if destination.exists() {
            return Err(adapter_error(format!(
                "adapter already installed: {}",
                manifest.adapter_id
            )));
        }

        fs::create_dir_all(&destination).map_err(|source| {
            adapter_error(format!(
                "create adapter dir {}: {source}",
                destination.display()
            ))
        })?;
        copy_dir_contents(run_dir, &destination)?;
        write_adapter_manifest(&destination.join(MANIFEST_FILE), &manifest)?;
        self.append_history(AdaptersHistoryEntry {
            adapter_id: manifest.adapter_id.clone(),
            action: "installed".into(),
            at: Utc::now(),
            actor: None,
            reason: None,
        })?;
        Ok(manifest)
    }

    pub fn list(&self) -> Result<Vec<AdapterManifest>, KernelError> {
        self.paths.ensure()?;
        let mut manifests = Vec::new();
        if !self.paths.adapters_installed.exists() {
            return Ok(manifests);
        }
        for entry in sorted_entries(&self.paths.adapters_installed)? {
            let file_type = entry.file_type().map_err(|source| {
                adapter_error(format!(
                    "read adapter entry {}: {source}",
                    entry.path().display()
                ))
            })?;
            if !file_type.is_dir() {
                continue;
            }
            let manifest_path = entry.path().join(MANIFEST_FILE);
            if manifest_path.exists() {
                manifests.push(read_adapter_manifest(&manifest_path)?);
            }
        }
        manifests.sort_by(|left, right| {
            right
                .created_at
                .cmp(&left.created_at)
                .then_with(|| left.adapter_id.cmp(&right.adapter_id))
        });
        Ok(manifests)
    }

    pub fn show(&self, adapter_id: &str) -> Result<Option<AdapterManifest>, KernelError> {
        let path = self.installed_dir(adapter_id)?.join(MANIFEST_FILE);
        if !path.exists() {
            return Ok(None);
        }
        Ok(Some(read_adapter_manifest(&path)?))
    }

    pub fn remove(&self, adapter_id: &str, force: bool) -> Result<(), KernelError> {
        let installed_dir = self.installed_dir(adapter_id)?;
        if !installed_dir.exists() {
            return Err(adapter_error(format!(
                "adapter not installed: {adapter_id}"
            )));
        }
        if let Some(active) = self.active()? {
            if active.adapter_id == adapter_id {
                if !force {
                    return Err(adapter_error(format!(
                        "adapter {adapter_id} is active; deactivate it or remove with force"
                    )));
                }
                self.clear_active(Some("remove active adapter"))?;
            }
        }
        fs::remove_dir_all(&installed_dir).map_err(|source| {
            adapter_error(format!(
                "remove adapter dir {}: {source}",
                installed_dir.display()
            ))
        })?;
        self.append_history(AdaptersHistoryEntry {
            adapter_id: adapter_id.to_string(),
            action: "removed".into(),
            at: Utc::now(),
            actor: None,
            reason: None,
        })
    }

    pub fn active(&self) -> Result<Option<ActiveAdapter>, KernelError> {
        let active_path = &self.paths.adapters_active;
        if !active_path.exists() {
            return Ok(None);
        }
        let bytes = fs::read(active_path).map_err(|source| {
            adapter_error(format!(
                "read active adapter {}: {source}",
                active_path.display()
            ))
        })?;
        let active: ActiveAdapter = serde_json::from_slice(&bytes).map_err(|source| {
            adapter_error(format!(
                "parse active adapter {}: {source}",
                active_path.display()
            ))
        })?;
        validate_adapter_id(&active.adapter_id)?;
        Ok(Some(active))
    }

    pub fn set_active(
        &self,
        manifest: &AdapterManifest,
        reason: Option<&str>,
    ) -> Result<ActiveAdapter, KernelError> {
        validate_adapter_id(&manifest.adapter_id)?;
        if self.show(&manifest.adapter_id)?.is_none() {
            return Err(adapter_error(format!(
                "adapter not installed: {}",
                manifest.adapter_id
            )));
        }
        let _lock = self.lock_active()?;
        let active = ActiveAdapter {
            adapter_id: manifest.adapter_id.clone(),
            base_model: manifest.base_model.clone(),
            activated_at: Utc::now(),
        };
        let bytes = serde_json::to_vec_pretty(&active)
            .map_err(|source| adapter_error(format!("serialize active adapter: {source}")))?;
        atomic_write(&self.paths.adapters_active, &bytes).map_err(|source| {
            adapter_error(format!(
                "write active adapter {}: {source}",
                self.paths.adapters_active.display()
            ))
        })?;
        self.append_history(AdaptersHistoryEntry {
            adapter_id: manifest.adapter_id.clone(),
            action: "activated".into(),
            at: active.activated_at,
            actor: None,
            reason: reason.map(ToOwned::to_owned),
        })?;
        Ok(active)
    }

    pub fn clear_active(&self, reason: Option<&str>) -> Result<Option<ActiveAdapter>, KernelError> {
        let _lock = self.lock_active()?;
        let previous = self.active()?;
        if let Some(active) = &previous {
            fs::remove_file(&self.paths.adapters_active).map_err(|source| {
                adapter_error(format!(
                    "remove active adapter {}: {source}",
                    self.paths.adapters_active.display()
                ))
            })?;
            self.append_history(AdaptersHistoryEntry {
                adapter_id: active.adapter_id.clone(),
                action: "deactivated".into(),
                at: Utc::now(),
                actor: None,
                reason: reason.map(ToOwned::to_owned),
            })?;
        }
        Ok(previous)
    }

    pub fn append_history(&self, entry: AdaptersHistoryEntry) -> Result<(), KernelError> {
        validate_adapter_id(&entry.adapter_id)?;
        if let Some(parent) = self.paths.adapters_history.parent() {
            fs::create_dir_all(parent).map_err(|source| {
                adapter_error(format!(
                    "create adapter history dir {}: {source}",
                    parent.display()
                ))
            })?;
        }
        let mut file = OpenOptions::new()
            .create(true)
            .append(true)
            .open(&self.paths.adapters_history)
            .map_err(|source| {
                adapter_error(format!(
                    "open adapter history {}: {source}",
                    self.paths.adapters_history.display()
                ))
            })?;
        file.lock_exclusive().map_err(|source| {
            adapter_error(format!(
                "lock adapter history {}: {source}",
                self.paths.adapters_history.display()
            ))
        })?;
        let line = serde_json::to_string(&entry).map_err(|source| {
            adapter_error(format!("serialize adapter history entry: {source}"))
        })?;
        file.write_all(line.as_bytes()).map_err(|source| {
            adapter_error(format!(
                "write adapter history {}: {source}",
                self.paths.adapters_history.display()
            ))
        })?;
        file.write_all(b"\n").map_err(|source| {
            adapter_error(format!(
                "write adapter history {}: {source}",
                self.paths.adapters_history.display()
            ))
        })?;
        file.sync_all().map_err(|source| {
            adapter_error(format!(
                "sync adapter history {}: {source}",
                self.paths.adapters_history.display()
            ))
        })?;
        Ok(())
    }

    pub fn history(&self, limit: Option<usize>) -> Result<Vec<AdaptersHistoryEntry>, KernelError> {
        if !self.paths.adapters_history.exists() {
            return Ok(Vec::new());
        }
        let file = File::open(&self.paths.adapters_history).map_err(|source| {
            adapter_error(format!(
                "open adapter history {}: {source}",
                self.paths.adapters_history.display()
            ))
        })?;
        let mut entries = Vec::new();
        for (line_number, line) in BufReader::new(file).lines().enumerate() {
            let line = line.map_err(|source| {
                adapter_error(format!(
                    "read adapter history {}:{}: {source}",
                    self.paths.adapters_history.display(),
                    line_number + 1
                ))
            })?;
            if line.trim().is_empty() {
                continue;
            }
            let entry: AdaptersHistoryEntry = serde_json::from_str(&line).map_err(|source| {
                adapter_error(format!(
                    "parse adapter history {}:{}: {source}",
                    self.paths.adapters_history.display(),
                    line_number + 1
                ))
            })?;
            entries.push(entry);
        }
        entries.reverse();
        if let Some(limit) = limit {
            entries.truncate(limit);
        }
        Ok(entries)
    }

    fn installed_dir(&self, adapter_id: &str) -> Result<PathBuf, KernelError> {
        validate_adapter_id(adapter_id)?;
        Ok(self.paths.adapters_installed.join(adapter_id))
    }

    fn lock_active(&self) -> Result<File, KernelError> {
        fs::create_dir_all(&self.paths.adapters_root).map_err(|source| {
            adapter_error(format!(
                "create adapter root {}: {source}",
                self.paths.adapters_root.display()
            ))
        })?;
        let lock_path = self.paths.adapters_root.join("active.json.lock");
        let lock = OpenOptions::new()
            .create(true)
            .truncate(false)
            .read(true)
            .write(true)
            .open(&lock_path)
            .map_err(|source| {
                adapter_error(format!(
                    "open active adapter lock {}: {source}",
                    lock_path.display()
                ))
            })?;
        lock.lock_exclusive().map_err(|source| {
            adapter_error(format!(
                "lock active adapter {}: {source}",
                lock_path.display()
            ))
        })?;
        Ok(lock)
    }
}

fn copy_dir_contents(source: &Path, destination: &Path) -> Result<(), KernelError> {
    for entry in sorted_entries(source)? {
        let from = entry.path();
        let to = destination.join(entry.file_name());
        let file_type = entry.file_type().map_err(|source| {
            adapter_error(format!(
                "read adapter artifact {}: {source}",
                from.display()
            ))
        })?;
        if file_type.is_dir() {
            fs::create_dir_all(&to).map_err(|source| {
                adapter_error(format!(
                    "create adapter artifact dir {}: {source}",
                    to.display()
                ))
            })?;
            copy_dir_contents(&from, &to)?;
        } else if file_type.is_file() {
            fs::copy(&from, &to).map_err(|source| {
                adapter_error(format!(
                    "copy adapter artifact {} -> {}: {source}",
                    from.display(),
                    to.display()
                ))
            })?;
        }
    }
    Ok(())
}

fn sorted_entries(path: &Path) -> Result<Vec<fs::DirEntry>, KernelError> {
    let mut entries = fs::read_dir(path)
        .map_err(|source| adapter_error(format!("read dir {}: {source}", path.display())))?
        .collect::<Result<Vec<_>, _>>()
        .map_err(|source| adapter_error(format!("read dir {}: {source}", path.display())))?;
    entries.sort_by_key(|entry| entry.path());
    Ok(entries)
}

fn validate_adapter_id(adapter_id: &str) -> Result<(), KernelError> {
    let valid = !adapter_id.is_empty()
        && !adapter_id.contains("..")
        && adapter_id
            .chars()
            .all(|ch| ch.is_ascii_alphanumeric() || ch == '-' || ch == '_' || ch == '.');
    if valid {
        Ok(())
    } else {
        Err(adapter_error(format!("invalid adapter id: {adapter_id}")))
    }
}

fn adapter_error(message: impl Into<String>) -> KernelError {
    KernelError::Request(message.into())
}

#[cfg(test)]
pub mod tests_support {
    use super::*;
    use allbert_proto::{
        AdapterEvalSummary, AdapterHyperparameters, AdapterOverallStatus, AdapterProvenance,
        AdapterResourceCost, AdapterWeightsFormat, BaseModelRef, ProviderKind,
    };

    pub fn manifest(adapter_id: &str, created_offset_seconds: i64) -> AdapterManifest {
        AdapterManifest {
            schema_version: allbert_proto::ADAPTER_MANIFEST_SCHEMA_VERSION,
            adapter_id: adapter_id.into(),
            provenance: AdapterProvenance::SelfTrained,
            trainer_backend: "fake".into(),
            base_model: BaseModelRef {
                provider: ProviderKind::Ollama,
                model_id: "llama3.2".into(),
                model_digest: "sha256:base".into(),
            },
            training_run_id: format!("run-{adapter_id}"),
            corpus_digest: "sha256:corpus".into(),
            weights_format: AdapterWeightsFormat::SafetensorsLora,
            weights_size_bytes: 12,
            hyperparameters: AdapterHyperparameters {
                rank: 8,
                alpha: 16,
                learning_rate: 0.0002,
                max_steps: 32,
                batch_size: 2,
                seed: 7,
            },
            resource_cost: AdapterResourceCost {
                compute_wall_seconds: 9,
                peak_resident_mb: 128,
                usd: 0.0,
            },
            eval_summary: AdapterEvalSummary {
                golden_pass_rate: 1.0,
                loss_final: 0.1,
                loss_curve_path: "loss.txt".into(),
                behavioral_diff_path: "behavioral-diff.md".into(),
                behavioral_samples: 2,
            },
            overall: AdapterOverallStatus::ReadyForReview,
            created_at: Utc::now() + chrono::Duration::seconds(created_offset_seconds),
            accepted_at: None,
        }
    }

    pub fn install_manifest(paths: &AllbertPaths, manifest: &AdapterManifest, weights: &[u8]) {
        let dir = paths.adapters_installed.join(&manifest.adapter_id);
        fs::create_dir_all(&dir).expect("installed dir");
        write_adapter_manifest(&dir.join(MANIFEST_FILE), manifest).expect("manifest");
        fs::write(dir.join("adapter.safetensors"), weights).expect("weights");
    }

    pub fn write_run(paths: &AllbertPaths, id: &str, offset: i64) -> PathBuf {
        let run_dir = paths.adapters_runs.join(format!("run-{id}"));
        fs::create_dir_all(&run_dir).expect("run dir");
        write_adapter_manifest(&run_dir.join(MANIFEST_FILE), &manifest(id, offset))
            .expect("manifest");
        fs::write(run_dir.join("adapter.safetensors"), b"stub").expect("weights");
        run_dir
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use tests_support::write_run;

    #[test]
    fn install_list_show_remove_state_machine() {
        let temp = tempfile::tempdir().expect("tempdir");
        let paths = AllbertPaths::under(temp.path().join(".allbert"));
        paths.ensure().expect("paths");
        let store = AdapterStore::new(paths.clone());

        let run_a = write_run(&paths, "personality-a", 0);
        let run_b = write_run(&paths, "personality-b", 10);
        let installed_a = store.install_from_run(&run_a).expect("install a");
        store.install_from_run(&run_b).expect("install b");

        let list = store.list().expect("list");
        assert_eq!(list[0].adapter_id, "personality-b");
        assert_eq!(list[1].adapter_id, "personality-a");
        assert_eq!(
            store
                .show("personality-a")
                .expect("show")
                .unwrap()
                .adapter_id,
            "personality-a"
        );

        store
            .set_active(&installed_a, Some("test activation"))
            .expect("activate");
        assert!(store.remove("personality-a", false).is_err());
        store.remove("personality-a", true).expect("forced remove");
        assert!(store.show("personality-a").expect("show missing").is_none());
        assert!(store.active().expect("active").is_none());
    }

    #[test]
    fn active_pointer_survives_concurrent_atomic_writes() {
        let temp = tempfile::tempdir().expect("tempdir");
        let paths = AllbertPaths::under(temp.path().join(".allbert"));
        paths.ensure().expect("paths");
        let store = AdapterStore::new(paths.clone());
        let first = store
            .install_from_run(&write_run(&paths, "personality-a", 0))
            .expect("install a");
        let second = store
            .install_from_run(&write_run(&paths, "personality-b", 1))
            .expect("install b");

        std::thread::scope(|scope| {
            let left_store = store.clone();
            let right_store = store.clone();
            let left = first.clone();
            let right = second.clone();
            scope.spawn(move || {
                left_store.set_active(&left, Some("left")).expect("left");
            });
            scope.spawn(move || {
                right_store
                    .set_active(&right, Some("right"))
                    .expect("right");
            });
        });

        let active = store.active().expect("active").expect("active pointer");
        assert!(["personality-a", "personality-b"].contains(&active.adapter_id.as_str()));
        let raw = fs::read_to_string(paths.adapters_active).expect("active raw");
        serde_json::from_str::<ActiveAdapter>(&raw).expect("valid json");
    }

    #[test]
    fn history_reads_newest_first_with_limit() {
        let temp = tempfile::tempdir().expect("tempdir");
        let paths = AllbertPaths::under(temp.path().join(".allbert"));
        paths.ensure().expect("paths");
        let store = AdapterStore::new(paths);
        for idx in 0..3 {
            store
                .append_history(AdaptersHistoryEntry {
                    adapter_id: format!("adapter-{idx}"),
                    action: "tested".into(),
                    at: Utc::now() + chrono::Duration::seconds(idx),
                    actor: None,
                    reason: None,
                })
                .expect("history");
        }

        let entries = store.history(Some(2)).expect("read history");
        assert_eq!(
            entries
                .iter()
                .map(|entry| entry.adapter_id.as_str())
                .collect::<Vec<_>>(),
            vec!["adapter-2", "adapter-1"]
        );
    }
}
