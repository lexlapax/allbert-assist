use serde::{Deserialize, Serialize};

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize, Default)]
#[serde(rename_all = "lowercase")]
pub enum MemoryTier {
    #[default]
    Durable,
    Session,
}

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq)]
pub struct MemoryFact {
    pub path: String,
    pub summary: String,
    #[serde(default)]
    pub tags: Vec<String>,
}

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq)]
pub struct SearchMemoryInput {
    pub query: String,
    #[serde(default)]
    pub tier: Option<MemoryTier>,
    #[serde(default)]
    pub limit: Option<usize>,
}

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq)]
pub struct SearchMemoryHit {
    pub tier: MemoryTier,
    pub path: String,
    pub summary: String,
    pub score: f32,
    #[serde(default)]
    pub tags: Vec<String>,
}

#[derive(Debug, Clone, Deserialize)]
pub struct ReadMemoryInput {
    pub path: String,
}

#[derive(Debug, Clone, Deserialize)]
pub struct WriteMemoryInput {
    #[serde(default)]
    pub path: Option<String>,
    pub content: String,
    pub mode: WriteMemoryMode,
    #[serde(default)]
    pub summary: Option<String>,
}

#[derive(Debug, Clone, Deserialize, PartialEq, Eq)]
#[serde(rename_all = "lowercase")]
pub enum WriteMemoryMode {
    Write,
    Append,
    Daily,
}

#[derive(Debug, Clone, Deserialize)]
pub struct StageMemoryInput {
    pub content: String,
    pub kind: StagedMemoryKind,
    pub summary: String,
    #[serde(default)]
    pub tags: Vec<String>,
    #[serde(default)]
    pub target_path: Option<String>,
}

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq, Eq)]
#[serde(rename_all = "snake_case")]
pub enum StagedMemoryKind {
    LearnedFact,
    Preference,
    ProjectNote,
    Correction,
}

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq, Eq)]
pub struct StageMemoryRequest {
    pub content: String,
    pub kind: StagedMemoryKind,
    pub summary: String,
    #[serde(default)]
    pub tags: Vec<String>,
    #[serde(default)]
    pub target_path: Option<String>,
}
