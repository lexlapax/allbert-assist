use std::path::Path;

use allbert_proto::AdapterManifest;

use crate::{atomic_write, KernelError};

pub const MANIFEST_FILE: &str = "manifest.json";

pub fn read_adapter_manifest(path: &Path) -> Result<AdapterManifest, KernelError> {
    let bytes = std::fs::read(path).map_err(|source| {
        KernelError::InitFailed(format!(
            "read adapter manifest {}: {source}",
            path.display()
        ))
    })?;
    let manifest: AdapterManifest = serde_json::from_slice(&bytes).map_err(|source| {
        KernelError::InitFailed(format!(
            "parse adapter manifest {}: {source}",
            path.display()
        ))
    })?;
    manifest.validate_schema_version().map_err(|source| {
        KernelError::InitFailed(format!(
            "validate adapter manifest {}: {source}",
            path.display()
        ))
    })?;
    Ok(manifest)
}

pub fn write_adapter_manifest(path: &Path, manifest: &AdapterManifest) -> Result<(), KernelError> {
    manifest.validate_schema_version().map_err(|source| {
        KernelError::InitFailed(format!(
            "validate adapter manifest {}: {source}",
            path.display()
        ))
    })?;
    let bytes = serde_json::to_vec_pretty(manifest).map_err(|source| {
        KernelError::InitFailed(format!("serialize adapter manifest: {source}"))
    })?;
    atomic_write(path, &bytes).map_err(|source| {
        KernelError::InitFailed(format!(
            "write adapter manifest {}: {source}",
            path.display()
        ))
    })
}
