pub mod corpus;
pub mod eval;
pub mod job;
pub mod manifest;
pub mod store;
pub mod trainer;
pub mod trainer_fake;

pub use corpus::{
    build_adapter_corpus, AdapterCorpusConfig, AdapterCorpusItem, AdapterCorpusSnapshot,
};
pub use eval::{
    golden_pass_rate, load_golden_cases, render_ascii_loss_curve, render_behavioral_diff,
    run_fixed_evals, AdapterEvalArtifacts, GoldenCase,
};
pub use job::{
    preview_personality_adapter_training, run_personality_adapter_training,
    run_personality_adapter_training_with_session, PersonalityAdapterJob,
    DEFAULT_ADAPTER_COMPUTE_CAP_WALL_SECONDS, DEFAULT_MIN_GOLDEN_PASS_RATE,
    PERSONALITY_ADAPTER_JOB_NAME, PERSONALITY_ADAPTER_SESSION_ID,
};
pub use manifest::{read_adapter_manifest, write_adapter_manifest};
pub use store::AdapterStore;
pub use trainer::{
    terminate_child_with_grace, AdapterTrainer, CancellationToken, TrainerError, TrainerHooks,
    TrainerProgress, TrainingOutcome, TrainingPlan,
};
pub use trainer_fake::FakeAdapterTrainer;

#[cfg(test)]
mod tests {
    use super::AdapterStore;

    #[test]
    fn frontend_adapter_and_adapter_storage_modules_do_not_collide() {
        fn accepts_store(_store: Option<AdapterStore>) {}

        let frontend_type = std::any::type_name::<crate::adapter::FrontendAdapter>();
        assert!(frontend_type.contains("FrontendAdapter"));
        accepts_store(None);
    }
}
