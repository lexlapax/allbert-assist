use std::collections::BTreeSet;
use std::path::{Path, PathBuf};

use allbert_proto::{ActiveAdapter, AdapterManifest, AdapterOverallStatus};
use serde::{Deserialize, Serialize};

use crate::adapters::manifest::{read_adapter_manifest, MANIFEST_FILE};
use crate::adapters::store::AdapterStore;
use crate::error::LlmError;
use crate::{atomic_write, AllbertPaths, KernelError, ModelConfig, Provider};

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct AdapterActivation {
    pub active: ActiveAdapter,
    pub warnings: Vec<String>,
}

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq, Eq)]
pub struct DerivedOllamaAdapter {
    pub adapter_id: String,
    pub model_name: String,
    pub modelfile_path: PathBuf,
}

#[derive(Debug, Default)]
pub struct HostedAdapterNotice {
    emitted: BTreeSet<String>,
}

impl HostedAdapterNotice {
    pub fn notice_once(
        &mut self,
        session_id: &str,
        provider: Provider,
        active: Option<&ActiveAdapter>,
    ) -> Option<String> {
        let active = active?;
        if provider == Provider::Ollama {
            return None;
        }
        let key = format!("{session_id}:{}", active.adapter_id);
        if !self.emitted.insert(key) {
            return None;
        }
        Some(format!(
            "Active adapter `{}` is local-only and is ignored by hosted provider `{}` for this session.",
            active.adapter_id,
            provider.label()
        ))
    }
}

pub fn activate_adapter(
    store: &AdapterStore,
    model: &ModelConfig,
    adapter_id: &str,
    override_reason: Option<&str>,
) -> Result<AdapterActivation, KernelError> {
    let manifest = store
        .show(adapter_id)?
        .ok_or_else(|| KernelError::Request(format!("adapter not installed: {adapter_id}")))?;
    validate_activation(&manifest, model, override_reason)?;
    let mut warnings = Vec::new();
    if manifest.base_model.model_digest != "unknown" {
        warnings.push(format!(
            "adapter `{}` was trained against digest `{}`; current model digest is not known",
            manifest.adapter_id, manifest.base_model.model_digest
        ));
    }
    let active = store.set_active(&manifest, override_reason)?;
    Ok(AdapterActivation { active, warnings })
}

pub fn deactivate_adapter(store: &AdapterStore, reason: Option<&str>) -> Result<(), KernelError> {
    store.clear_active(reason)?;
    cleanup_runtime_files(store.paths(), None)?;
    Ok(())
}

pub fn active_adapter_for_model(
    store: &AdapterStore,
    model: &ModelConfig,
) -> Result<Option<ActiveAdapter>, KernelError> {
    let Some(active) = store.active()? else {
        return Ok(None);
    };
    if active.base_model.model_id != model.model_id {
        store.clear_active(Some("active model changed"))?;
        cleanup_runtime_files(store.paths(), Some(&active.adapter_id))?;
        return Ok(None);
    }
    Ok(Some(active))
}

pub async fn register_ollama_adapter(
    paths: &AllbertPaths,
    active: &ActiveAdapter,
    base_url: Option<&str>,
) -> Result<DerivedOllamaAdapter, KernelError> {
    let manifest = read_adapter_manifest(
        &paths
            .adapters_installed
            .join(&active.adapter_id)
            .join(MANIFEST_FILE),
    )?;
    let cache_path = paths
        .adapters_runtime
        .join(format!("{}.derived.json", active.adapter_id));
    if cache_path.exists() {
        let raw = std::fs::read(&cache_path).map_err(|source| {
            KernelError::InitFailed(format!("read {}: {source}", cache_path.display()))
        })?;
        let cached = serde_json::from_slice::<DerivedOllamaAdapter>(&raw).map_err(|source| {
            KernelError::InitFailed(format!("parse {}: {source}", cache_path.display()))
        })?;
        return Ok(cached);
    }

    std::fs::create_dir_all(&paths.adapters_runtime).map_err(|source| {
        KernelError::InitFailed(format!(
            "create {}: {source}",
            paths.adapters_runtime.display()
        ))
    })?;
    let model_name = format!(
        "allbert-adapter-{}",
        sanitize_model_name(&active.adapter_id)
    );
    let weights_path = adapter_weights_path(paths, &manifest)?;
    let modelfile = format!(
        "FROM {}\nADAPTER {}\n",
        manifest.base_model.model_id,
        weights_path.display()
    );
    let modelfile_path = paths
        .adapters_runtime
        .join(format!("{}.Modelfile", active.adapter_id));
    atomic_write(&modelfile_path, modelfile.as_bytes()).map_err(|source| {
        KernelError::InitFailed(format!("write {}: {source}", modelfile_path.display()))
    })?;

    let url = format!(
        "{}/api/create",
        base_url
            .unwrap_or("http://127.0.0.1:11434")
            .trim_end_matches('/')
    );
    let body = serde_json::json!({
        "model": model_name,
        "modelfile": modelfile,
        "stream": false,
    });
    let response = reqwest::Client::new()
        .post(url)
        .json(&body)
        .send()
        .await
        .map_err(|source| KernelError::Llm(LlmError::Http(source.to_string())))?;
    if !response.status().is_success() {
        let status = response.status();
        let body = response.text().await.unwrap_or_default();
        return Err(KernelError::Llm(LlmError::Response(format!(
            "ollama adapter create status {status}: {body}"
        ))));
    }

    let derived = DerivedOllamaAdapter {
        adapter_id: active.adapter_id.clone(),
        model_name,
        modelfile_path,
    };
    atomic_write(
        &cache_path,
        &serde_json::to_vec_pretty(&derived).map_err(|source| {
            KernelError::InitFailed(format!("serialize runtime cache: {source}"))
        })?,
    )
    .map_err(|source| {
        KernelError::InitFailed(format!("write {}: {source}", cache_path.display()))
    })?;
    Ok(derived)
}

pub fn cleanup_runtime_files(
    paths: &AllbertPaths,
    adapter_id: Option<&str>,
) -> Result<(), KernelError> {
    if !paths.adapters_runtime.exists() {
        return Ok(());
    }
    for entry in std::fs::read_dir(&paths.adapters_runtime).map_err(|source| {
        KernelError::InitFailed(format!(
            "read {}: {source}",
            paths.adapters_runtime.display()
        ))
    })? {
        let entry = entry.map_err(|source| {
            KernelError::InitFailed(format!(
                "read {}: {source}",
                paths.adapters_runtime.display()
            ))
        })?;
        let path = entry.path();
        let Some(name) = path.file_name().and_then(|value| value.to_str()) else {
            continue;
        };
        let matches = adapter_id.map(|id| name.starts_with(id)).unwrap_or(true);
        if matches && path.is_file() {
            std::fs::remove_file(&path).map_err(|source| {
                KernelError::InitFailed(format!("remove {}: {source}", path.display()))
            })?;
        }
    }
    Ok(())
}

fn validate_activation(
    manifest: &AdapterManifest,
    model: &ModelConfig,
    override_reason: Option<&str>,
) -> Result<(), KernelError> {
    if manifest.overall == AdapterOverallStatus::NeedsAttention && override_reason.is_none() {
        return Err(KernelError::Request(format!(
            "adapter `{}` needs attention; pass an override reason to activate",
            manifest.adapter_id
        )));
    }
    if manifest.base_model.model_id != model.model_id {
        return Err(KernelError::Request(format!(
            "adapter `{}` was trained for model `{}` but active model is `{}`",
            manifest.adapter_id, manifest.base_model.model_id, model.model_id
        )));
    }
    Ok(())
}

fn adapter_weights_path(
    paths: &AllbertPaths,
    manifest: &AdapterManifest,
) -> Result<PathBuf, KernelError> {
    let installed_dir = paths.adapters_installed.join(&manifest.adapter_id);
    for candidate in ["adapter.safetensors", "adapter.gguf"] {
        let path = installed_dir.join(candidate);
        if path.exists() {
            return Ok(path);
        }
    }
    Err(KernelError::Request(format!(
        "adapter `{}` has no installed weights file",
        manifest.adapter_id
    )))
}

fn sanitize_model_name(adapter_id: &str) -> String {
    adapter_id
        .chars()
        .map(|ch| {
            if ch.is_ascii_alphanumeric() || ch == '-' {
                ch
            } else {
                '-'
            }
        })
        .collect()
}

#[allow(dead_code)]
fn _assert_path(_: &Path) {}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::adapters::store::tests_support::{install_manifest, manifest};
    use allbert_proto::{AdapterOverallStatus, ProviderKind};

    #[test]
    fn activation_refuses_needs_attention_without_override_and_model_mismatch() {
        let temp = tempfile::tempdir().expect("tempdir");
        let paths = AllbertPaths::under(temp.path().join(".allbert"));
        paths.ensure().expect("paths");
        let store = AdapterStore::new(paths.clone());
        let mut needs_attention = manifest("needs-attention", 0);
        needs_attention.overall = AdapterOverallStatus::NeedsAttention;
        install_manifest(&paths, &needs_attention, b"weights");
        let model = ModelConfig {
            provider: Provider::Ollama,
            model_id: "llama3.2".into(),
            api_key_env: None,
            base_url: None,
            max_tokens: 1,
            context_window_tokens: 0,
        };
        assert!(activate_adapter(&store, &model, &needs_attention.adapter_id, None).is_err());

        let mut mismatch = manifest("mismatch", 0);
        mismatch.base_model.model_id = "other".into();
        mismatch.base_model.provider = ProviderKind::Ollama;
        install_manifest(&paths, &mismatch, b"weights");
        assert!(activate_adapter(&store, &model, &mismatch.adapter_id, Some("reviewed")).is_err());
    }

    #[test]
    fn activation_and_auto_deactivation_update_active_pointer() {
        let temp = tempfile::tempdir().expect("tempdir");
        let paths = AllbertPaths::under(temp.path().join(".allbert"));
        paths.ensure().expect("paths");
        let store = AdapterStore::new(paths.clone());
        let manifest = manifest("ready", 0);
        install_manifest(&paths, &manifest, b"weights");
        let model = ModelConfig {
            provider: Provider::Ollama,
            model_id: manifest.base_model.model_id.clone(),
            api_key_env: None,
            base_url: None,
            max_tokens: 1,
            context_window_tokens: 0,
        };
        activate_adapter(&store, &model, &manifest.adapter_id, None).expect("activate");
        assert!(active_adapter_for_model(&store, &model)
            .expect("active")
            .is_some());

        let mut switched = model.clone();
        switched.model_id = "different".into();
        assert!(active_adapter_for_model(&store, &switched)
            .expect("auto deactivated")
            .is_none());
        assert!(store.active().expect("active").is_none());
    }

    #[test]
    fn hosted_notice_is_one_shot_per_session() {
        let mut notices = HostedAdapterNotice::default();
        let active = ActiveAdapter {
            adapter_id: "ready".into(),
            base_model: manifest("ready", 0).base_model,
            activated_at: chrono::Utc::now(),
        };
        assert!(notices
            .notice_once("s1", Provider::Openai, Some(&active))
            .is_some());
        assert!(notices
            .notice_once("s1", Provider::Openai, Some(&active))
            .is_none());
        assert!(notices
            .notice_once("s2", Provider::Openai, Some(&active))
            .is_some());
    }
}
