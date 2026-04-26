use allbert_kernel_services::adapters::{AdapterStore, PersonalityAdapterJob};
use allbert_kernel_services::llm::DefaultProviderFactory;
use allbert_kernel_services::memory::{list_staged_memory, MemoryTier};
use allbert_kernel_services::self_diagnosis::{
    DiagnosisRemediationKind, DiagnosisRemediationRequest, DiagnosisReportArtifact,
};
use allbert_kernel_services::skills::{validate_skill_path, SkillProvenance};
use allbert_kernel_services::{AllbertPaths, Config, Kernel};
use std::path::Path;

#[test]
fn representative_services_imports_compile() {
    let paths = AllbertPaths::under(std::env::temp_dir().join("allbert-services-imports"));
    let config = Config::default_template();
    let _kernel: Option<Kernel> = None;
    let _factory = DefaultProviderFactory::default();
    let _store = AdapterStore::new(paths.clone());
    let _job: Option<PersonalityAdapterJob> = None;
    let _memory_tier = MemoryTier::Durable;
    let _ = list_staged_memory(&paths, &config.memory, None, None, Some(1));
    let _ = validate_skill_path(Path::new("demo-skill"));
    let _provenance = SkillProvenance::External;
    let _artifact: Option<DiagnosisReportArtifact> = None;
    let _request = DiagnosisRemediationRequest {
        kind: DiagnosisRemediationKind::Code,
        reason: "import fixture".into(),
    };
}
