use allbert_proto::{
    JobDefinitionPayload, JobReportPolicyPayload, JobRunRecordPayload, JobStatusPayload,
    ModelConfigPayload,
};
use async_trait::async_trait;
use serde::Deserialize;

#[async_trait]
pub trait JobManager: Send + Sync {
    async fn list_jobs(&self) -> Result<Vec<JobStatusPayload>, String>;
    async fn get_job(&self, name: &str) -> Result<JobStatusPayload, String>;
    async fn upsert_job(
        &self,
        definition: JobDefinitionPayload,
    ) -> Result<JobStatusPayload, String>;
    async fn pause_job(&self, name: &str) -> Result<JobStatusPayload, String>;
    async fn resume_job(&self, name: &str) -> Result<JobStatusPayload, String>;
    async fn run_job(&self, name: &str) -> Result<JobRunRecordPayload, String>;
    async fn remove_job(&self, name: &str) -> Result<(), String>;
    async fn list_job_runs(
        &self,
        name: Option<&str>,
        only_failures: bool,
        limit: usize,
    ) -> Result<Vec<JobRunRecordPayload>, String>;
}

#[derive(Debug, Deserialize)]
pub struct NamedJobInput {
    pub name: String,
}

#[derive(Debug, Deserialize)]
pub struct ListJobRunsInput {
    #[serde(default)]
    pub name: Option<String>,
    #[serde(default)]
    pub only_failures: bool,
    #[serde(default = "default_runs_limit")]
    pub limit: usize,
}

#[derive(Debug, Deserialize)]
pub struct UpsertJobInput {
    pub name: String,
    pub description: String,
    #[serde(default = "default_enabled")]
    pub enabled: bool,
    pub schedule: String,
    #[serde(default)]
    pub skills: Vec<String>,
    #[serde(default)]
    pub timezone: Option<String>,
    #[serde(default)]
    pub model: Option<ModelConfigPayload>,
    #[serde(default)]
    pub allowed_tools: Vec<String>,
    #[serde(default)]
    pub timeout_s: Option<u64>,
    #[serde(default)]
    pub report: Option<JobReportPolicyPayload>,
    #[serde(default)]
    pub max_turns: Option<u32>,
    #[serde(default)]
    pub session_name: Option<String>,
    #[serde(default)]
    pub memory_prefetch: Option<bool>,
    pub prompt: String,
}

impl UpsertJobInput {
    pub fn into_payload(self) -> JobDefinitionPayload {
        JobDefinitionPayload {
            name: self.name,
            description: self.description,
            enabled: self.enabled,
            schedule: self.schedule,
            skills: self.skills,
            timezone: self.timezone,
            model: self.model,
            allowed_tools: self.allowed_tools,
            timeout_s: self.timeout_s,
            report: self.report,
            max_turns: self.max_turns,
            session_name: self.session_name,
            memory_prefetch: self.memory_prefetch,
            prompt: self.prompt,
        }
    }
}

fn default_enabled() -> bool {
    true
}

fn default_runs_limit() -> usize {
    20
}
