use std::collections::HashSet;
use std::sync::Arc;

use crate::adapters::trainer::AdapterTrainer;
use crate::adapters::trainer_fake::FakeAdapterTrainer;
use crate::adapters::trainer_llamacpp::LlamaCppLoraTrainer;
use crate::adapters::trainer_mlx::MlxLoraTrainer;
use crate::security::{exec_policy, NormalizedExec, PolicyDecision};
use crate::{AllbertPaths, Config, KernelError};

pub fn build_trainer(
    paths: &AllbertPaths,
    config: &Config,
    requested_backend: Option<&str>,
) -> Result<Arc<dyn AdapterTrainer>, KernelError> {
    let backend = effective_backend(config, requested_backend)?;
    ensure_backend_allowed(config, &backend, requested_backend)?;
    match backend.as_str() {
        "fake" => Ok(Arc::new(FakeAdapterTrainer::new())),
        "mlx-lm-lora" => {
            ensure_trainer_program_auto_allowed(config, &backend, "python3")?;
            Ok(Arc::new(MlxLoraTrainer::new(paths.clone(), config.clone())))
        }
        "llama-cpp-finetune" => {
            ensure_trainer_program_auto_allowed(config, &backend, "llama-cpp-finetune")?;
            Ok(Arc::new(LlamaCppLoraTrainer::new(
                paths.clone(),
                config.clone(),
            )))
        }
        unknown => Err(KernelError::Request(format!(
            "unknown adapter trainer backend `{unknown}`; configure learning.adapter_training.default_backend, learning.adapter_training.allowed_backends, request backend, and security.exec_allow"
        ))),
    }
}

fn effective_backend(
    config: &Config,
    requested_backend: Option<&str>,
) -> Result<String, KernelError> {
    let training = &config.learning.adapter_training;
    if !training.enabled {
        return Err(KernelError::Request(
            "adapter training is disabled; set learning.adapter_training.enabled = true and configure learning.adapter_training.default_backend".into(),
        ));
    }
    requested_backend
        .map(str::trim)
        .filter(|backend| !backend.is_empty())
        .map(ToOwned::to_owned)
        .or_else(|| training.default_backend.clone())
        .filter(|backend| !backend.trim().is_empty())
        .ok_or_else(|| {
            KernelError::Request(
                "adapter training requires learning.adapter_training.default_backend or a request backend"
                    .into(),
            )
        })
}

fn ensure_backend_allowed(
    config: &Config,
    backend: &str,
    requested_backend: Option<&str>,
) -> Result<(), KernelError> {
    if config
        .learning
        .adapter_training
        .allowed_backends
        .iter()
        .any(|allowed| allowed == backend)
    {
        return Ok(());
    }
    let request_hint = if requested_backend.is_some() {
        " request backend overrides must be listed there too."
    } else {
        ""
    };
    Err(KernelError::Request(format!(
        "adapter trainer backend `{backend}` is not in learning.adapter_training.allowed_backends.{request_hint} Configure learning.adapter_training.default_backend, learning.adapter_training.allowed_backends, and security.exec_allow."
    )))
}

fn ensure_trainer_program_auto_allowed(
    config: &Config,
    backend: &str,
    program: &str,
) -> Result<(), KernelError> {
    let exec = NormalizedExec {
        program: program.into(),
        args: Vec::new(),
        cwd: None,
    };
    match exec_policy(&exec, &config.security, &HashSet::new()) {
        PolicyDecision::AutoAllow => Ok(()),
        PolicyDecision::NeedsConfirm(_) => Err(KernelError::Request(format!(
            "adapter trainer command `{program}` for backend `{backend}` is not auto-allowed; add `{program}` to security.exec_allow"
        ))),
        PolicyDecision::Deny(reason) => Err(KernelError::Request(format!(
            "adapter trainer command `{program}` for backend `{backend}` is denied ({reason}); update security.exec_allow/security.exec_deny"
        ))),
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn config_for_backend(backend: &str) -> Config {
        let mut config = Config::default_template();
        config.learning.adapter_training.enabled = true;
        config.learning.adapter_training.default_backend = Some(backend.into());
        config.learning.adapter_training.allowed_backends = vec![backend.into()];
        config.security.exec_allow = vec![trainer_program_for_backend(backend).into()];
        config
    }

    fn trainer_program_for_backend(backend: &str) -> &'static str {
        match backend {
            "mlx-lm-lora" => "python3",
            "llama-cpp-finetune" => "llama-cpp-finetune",
            _ => "unused",
        }
    }

    #[test]
    fn factory_refuses_disabled_training_instead_of_fake_fallback() {
        let paths = AllbertPaths::under(std::env::temp_dir().join("allbert-factory-disabled"));
        let config = Config::default_template();
        let error = build_trainer(&paths, &config, None)
            .err()
            .expect("disabled should refuse");
        assert!(error
            .to_string()
            .contains("learning.adapter_training.enabled"));
    }

    #[test]
    fn factory_honors_explicit_fake_backend() {
        let paths = AllbertPaths::under(std::env::temp_dir().join("allbert-factory-fake"));
        let mut config = config_for_backend("fake");
        config.security.exec_allow.clear();
        let trainer = build_trainer(&paths, &config, None).expect("fake is explicit");
        assert_eq!(trainer.backend_id(), "fake");
    }

    #[test]
    fn request_backend_override_must_be_allowed() {
        let paths = AllbertPaths::under(std::env::temp_dir().join("allbert-factory-override"));
        let config = config_for_backend("fake");
        let error = build_trainer(&paths, &config, Some("mlx-lm-lora"))
            .err()
            .expect("override must be allowed");
        assert!(error
            .to_string()
            .contains("learning.adapter_training.allowed_backends"));
    }

    #[test]
    fn real_backend_requires_exec_allow() {
        let paths = AllbertPaths::under(std::env::temp_dir().join("allbert-factory-exec"));
        let mut config = config_for_backend("mlx-lm-lora");
        config.security.exec_allow.clear();
        let error = build_trainer(&paths, &config, None)
            .err()
            .expect("exec allow required");
        assert!(error.to_string().contains("security.exec_allow"));
    }
}
