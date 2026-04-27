use serde::{Deserialize, Serialize};

#[derive(Debug, Clone, Copy, Serialize, Deserialize, PartialEq, Eq, PartialOrd, Ord, Hash)]
#[serde(rename_all = "snake_case")]
pub enum RagSourceKind {
    OperatorDocs,
    #[serde(alias = "commands")]
    CommandCatalog,
    #[serde(alias = "settings")]
    SettingsCatalog,
    SkillsMetadata,
    #[serde(alias = "memory")]
    DurableMemory,
    #[serde(alias = "facts")]
    FactMemory,
    #[serde(alias = "episodes")]
    EpisodeRecall,
    #[serde(alias = "sessions")]
    SessionSummary,
    StagedMemoryReview,
}

impl RagSourceKind {
    pub const PROMPT_ELIGIBLE_DEFAULTS: [Self; 8] = [
        Self::OperatorDocs,
        Self::CommandCatalog,
        Self::SettingsCatalog,
        Self::SkillsMetadata,
        Self::DurableMemory,
        Self::FactMemory,
        Self::EpisodeRecall,
        Self::SessionSummary,
    ];

    pub fn label(self) -> &'static str {
        match self {
            Self::OperatorDocs => "operator_docs",
            Self::CommandCatalog => "command_catalog",
            Self::SettingsCatalog => "settings_catalog",
            Self::SkillsMetadata => "skills_metadata",
            Self::DurableMemory => "durable_memory",
            Self::FactMemory => "fact_memory",
            Self::EpisodeRecall => "episode_recall",
            Self::SessionSummary => "session_summary",
            Self::StagedMemoryReview => "staged_memory_review",
        }
    }

    pub fn parse(value: &str) -> Option<Self> {
        match normalize_source_kind(value).as_str() {
            "operator_docs" | "docs" => Some(Self::OperatorDocs),
            "command_catalog" | "commands" | "command" => Some(Self::CommandCatalog),
            "settings_catalog" | "settings" | "setting" => Some(Self::SettingsCatalog),
            "skills_metadata" | "skills" | "skill_metadata" => Some(Self::SkillsMetadata),
            "durable_memory" | "memory" => Some(Self::DurableMemory),
            "fact_memory" | "facts" | "fact" => Some(Self::FactMemory),
            "episode_recall" | "episodes" | "episode" => Some(Self::EpisodeRecall),
            "session_summary" | "sessions" | "session" => Some(Self::SessionSummary),
            "staged_memory_review" | "staged" | "review_only" => Some(Self::StagedMemoryReview),
            _ => None,
        }
    }

    pub fn default_prompt_sources() -> Vec<Self> {
        Self::PROMPT_ELIGIBLE_DEFAULTS.to_vec()
    }
}

#[derive(Debug, Clone, Copy, Serialize, Deserialize, PartialEq, Eq)]
#[serde(rename_all = "snake_case")]
pub enum RagRetrievalMode {
    Hybrid,
    Vector,
    Lexical,
}

impl RagRetrievalMode {
    pub fn label(self) -> &'static str {
        match self {
            Self::Hybrid => "hybrid",
            Self::Vector => "vector",
            Self::Lexical => "lexical",
        }
    }
}

#[derive(Debug, Clone, Copy, Serialize, Deserialize, PartialEq, Eq)]
#[serde(rename_all = "snake_case")]
pub enum RagEmbeddingProvider {
    Ollama,
    Fake,
}

impl RagEmbeddingProvider {
    pub fn label(self) -> &'static str {
        match self {
            Self::Ollama => "ollama",
            Self::Fake => "fake",
        }
    }
}

#[derive(Debug, Clone, Copy, Serialize, Deserialize, PartialEq, Eq)]
#[serde(rename_all = "snake_case")]
pub enum RagVectorDistance {
    Cosine,
}

impl RagVectorDistance {
    pub fn label(self) -> &'static str {
        match self {
            Self::Cosine => "cosine",
        }
    }
}

#[derive(Debug, Clone, Copy, Serialize, Deserialize, PartialEq, Eq)]
#[serde(rename_all = "snake_case")]
pub enum RagVectorPosture {
    Healthy,
    Disabled,
    MissingModel,
    Stale,
    Degraded,
    Unavailable,
}

#[derive(Debug, Clone, Copy, Serialize, Deserialize, PartialEq, Eq)]
#[serde(rename_all = "snake_case")]
pub enum RagIndexRunStatus {
    Pending,
    Running,
    Succeeded,
    Skipped,
    Cancelled,
    Failed,
}

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq, Eq)]
pub struct RagSearchRequest {
    pub query: String,
    #[serde(default)]
    pub sources: Vec<RagSourceKind>,
    #[serde(default)]
    pub mode: Option<RagRetrievalMode>,
    #[serde(default)]
    pub limit: Option<usize>,
    #[serde(default)]
    pub include_review_only: bool,
}

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq)]
pub struct RagSearchResult {
    pub source_kind: RagSourceKind,
    pub source_id: String,
    pub chunk_id: String,
    pub title: String,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub path: Option<String>,
    pub snippet: String,
    pub mode: RagRetrievalMode,
    pub score: f64,
    pub vector_posture: RagVectorPosture,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub score_explanation: Option<String>,
}

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq)]
pub struct RagSearchResponse {
    pub query: String,
    pub mode: RagRetrievalMode,
    pub vector_posture: RagVectorPosture,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub degraded_reason: Option<String>,
    pub results: Vec<RagSearchResult>,
}

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq, Eq)]
pub struct RagStatusSnapshot {
    pub enabled: bool,
    pub mode: RagRetrievalMode,
    pub source_count: usize,
    pub chunk_count: usize,
    pub vector_count: usize,
    pub vector_posture: RagVectorPosture,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub active_provider: Option<RagEmbeddingProvider>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub active_model: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub active_dimension: Option<usize>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub last_run_id: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub degraded_reason: Option<String>,
}

fn normalize_source_kind(value: &str) -> String {
    value.trim().replace('-', "_").to_ascii_lowercase()
}
