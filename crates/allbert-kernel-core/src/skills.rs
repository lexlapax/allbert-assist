use std::path::PathBuf;

use serde::{Deserialize, Serialize};

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq, Eq)]
pub struct ContributedAgent {
    pub name: String,
    #[serde(default)]
    pub description: String,
    #[serde(default)]
    pub prompt: String,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct ActiveSkill {
    pub id: String,
    pub title: String,
    pub path: PathBuf,
}

#[derive(Debug, Clone, Deserialize)]
pub struct InvokeSkillInput {
    pub skill: String,
    #[serde(default)]
    pub args: serde_json::Value,
}

#[derive(Debug, Clone, Deserialize)]
pub struct CreateSkillInput {
    pub name: String,
    pub description: String,
    pub body: String,
}
